import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

/// Reconciles the three connector snapshots into one [LinkedAccount] per
/// student, ported from legacy `LinkedAccounts.DoRelink` but extracted from
/// WPF state and fixed for the known matching bugs.
///
/// Pure and deterministic (INV-20): the same snapshots and the same
/// [resolver] state always yield the same [LinkedSnapshot]. All impurity —
/// minting and persisting the stable [PersonId] — is delegated to [resolver],
/// so `link` itself does no I/O.
///
/// This function links **students** (#43), **staff** (#44), and **groups**
/// (#45).
///
/// The **student** bridges (spec `docs/domain-model.md` §4, §6.2):
/// - `AzureUser.upn` ≡ `SmartschoolAccount.mail` (case-insensitive, trimmed)
/// - `SmartschoolAccount.accountId` ≡ `WisaStudent.wisaId` ≡
///   `AzureUser.employeeId`
///
/// The **staff** bridges differ on the Smartschool side. Staff carry two WISA
/// identifiers — `WisaStaff.code` (an alphabetic surname-mnemonic) and
/// `WisaStaff.wisaId` (a numeric id) — that are *genuinely distinct* (OQ-1,
/// resolved from real data; see the package README). Each bridges a different
/// system:
/// - `AzureUser.upn` ≡ `SmartschoolAccount.mail` (as for students)
/// - `SmartschoolAccount.accountId` ≡ `WisaStaff.code` — the staff
///   "AddToSmartschool" action stores the *code*, not the wisaId, as the
///   Smartschool internal number (legacy `FindAccountByWisaID(account.CODE)`).
/// - `AzureUser.employeeId` ≡ `WisaStaff.wisaId`
///
/// Students and staff are partitioned out of the single flat Smartschool
/// account list by [SmartschoolAccount] `role`: teacher/director ⇒ staff,
/// everything else ⇒ student. Azure orphans split per INV-22:
/// [studentBelongsToSchool] (`companyName == schoolPrefix`) keeps a former
/// *student*, [staffBelongsToSchool] (`department` *contains* the prefix, the
/// comma-separated list other software maintains, #237) keeps a former *staff*
/// member. Both predicates live in `account_core` rather than here (#279): the
/// Azure connector's client-side reads must apply the identical rule, because a
/// read narrower than the linker throws rows away before the linker can ask
/// about them.
///
/// Fixes carried over from the legacy linker:
/// - **INV-12:** every `mail`/`upn`/id comparison is trimmed and
///   case-insensitive (legacy `.Equals()` was case-sensitive).
/// - **INV-23:** two Smartschool accounts sharing a `mail` are *both* kept and
///   a [ResolveDuplicateMail] warning is raised (legacy silently dropped one).
///   Keeping both means keeping two *records* for one person, so the pair also
///   has to end up on two distinct [LinkedAccountId]s — see [_firstUnclaimed]
///   (#323).
/// - **INV-24:** two records that resolve to the same [LinkedAccountId] raise a
///   [DuplicateLinkedId] warning (#319). The check is not written here: it lives
///   in [LinkedSnapshot.fromRecords], which this function returns through, so it
///   holds for every snapshot built that way rather than only for this pass. It
///   is defence in depth — every *known* cause is fixed at its source (see
///   INV-21, [_buildStudentRecords] and [_firstUnclaimed]) — but the layers
///   below the linker are all keyed by that id and every one of them unions or
///   drops without a word, so a cause nobody has found yet must not be able to
///   reach them quietly.
///
/// [schoolPrefix] is the Azure `companyName` value the school stamps on its
/// own users; an Azure-only user carrying it is a former student kept as an
/// incomplete record so the action engine can flag it for deletion (INV-22).
/// [ourSchoolIds] is the set of WISA school ids we actually **manage** (#133).
/// The shared credentials pull every group school, so this set is what tells a
/// student who left *our* school (but is still in a sibling group school) from
/// one who is genuinely present here. It comes from Settings and nowhere else
/// (#286): null and empty both mean ownership is unconfigured, in which case
/// every WISA-present student is treated as ours, preserving the pre-#134
/// behaviour. For students and staff, membership never changes which records
/// exist or their identity keys, only how each is classified
/// ([WisaPresence]) — and, for a student the shared pull returns *twice*
/// because they are enrolled in two group schools, which of those two rows
/// supplies the class placement (#318, see [_prefersWisaRow]). For **groups**
/// it is a filter (#205), because a class of a school we do not manage has no
/// business reaching the action engine at all (see [_linkGroups]).
///
/// A second group-only filter composes with it: the class groups of a school
/// flagged [wapi.WisaSchool.isVirtual] are skipped too (#209). A virtual school
/// is typically *also* marked managed, so ownership alone never excluded it. The
/// virtual set is always derived from the snapshot's own schools —
/// `markVirtualSchools` stamps the flag before the pull, so the snapshot is
/// authoritative here — and it never touches students or staff, who keep flowing
/// from virtual schools exactly as before.
LinkedSnapshot link(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot,
  PersonIdResolver resolver, {
  required String schoolPrefix,
  Set<int>? ourSchoolIds,
}) {
  final effectiveOurSchoolIds = ourSchoolIds ?? const <int>{};

  // The virtual schools (#209). Unlike ownership there is no caller override:
  // the flag is stamped onto the school list before the pull, and `sync()`
  // stores that list on the snapshot, so the snapshot is the single source.
  final virtualSchoolIds = <int>{
    for (final school in wisaSnapshot.schools)
      if (school.isVirtual) school.id,
  };

  // Build the student and staff records first, in that order, so the two
  // populations' duplicate-mail warnings accumulate student-then-staff exactly
  // as before. Group linking carries no identity, so it stays separate.
  final warnings = <LinkWarning>[];
  final studentRecords = _buildStudentRecords(
    wisaSnapshot,
    smartschoolSnapshot,
    azureSnapshot,
    schoolPrefix: schoolPrefix,
    ourSchoolIds: effectiveOurSchoolIds,
    warnings: warnings,
  );
  final staffRecords = _buildStaffRecords(
    wisaSnapshot,
    smartschoolSnapshot,
    azureSnapshot,
    schoolPrefix: schoolPrefix,
    warnings: warnings,
  );

  // Resolve a stable identity and confidence for each record — students first,
  // then staff, so [resolver.resolve] is called in the same order as before
  // (a sequential/minting resolver assigns ids in that order).
  //
  // The natural keys are claimed as they are handed out, so two records can
  // never be given the same one (#323): see [_firstUnclaimed]. Students and
  // staff share the claim set even though their key namespaces cannot overlap
  // (`staff:` prefixes every staff key) — one set is simpler than two and costs
  // nothing.
  final claimedKeys = <String>{};
  final accounts = <LinkedAccount>[
    for (final rec in studentRecords)
      LinkedAccount(
        id: LinkedAccountId(
            resolver.resolve(_naturalKey(rec, claimedKeys)).value),
        role: PersonRole.student,
        wisa: rec.wisa,
        smartschool: rec.smartschool,
        azure: rec.azure,
        confidence: _confidence(rec),
        wisaClassGroups: rec.wisaClassGroups,
        wisaPresence: _presence(rec.wisaSchoolIds, effectiveOurSchoolIds),
      ),
  ];
  final staff = <LinkedStaff>[
    for (final rec in staffRecords)
      LinkedStaff(
        id: LinkedAccountId(
            resolver.resolve(_naturalStaffKey(rec, claimedKeys)).value),
        role: rec.smartschool?.role ?? PersonRole.teacher,
        wisa: rec.wisa,
        smartschool: rec.smartschool,
        azure: rec.azure,
        confidence: _staffConfidence(rec),
      ),
  ];

  final groups = _linkGroups(
    wisaSnapshot,
    smartschoolSnapshot,
    azureSnapshot,
    effectiveOurSchoolIds,
    virtualSchoolIds,
    schoolPrefix,
    warnings,
  );

  return LinkedSnapshot.fromRecords(
    accounts: accounts,
    staff: staff,
    groups: groups,
    warnings: warnings,
  );
}

/// The set of natural keys [link] will hand to the [PersonIdResolver] for the
/// same three snapshots — every student and staff key, deduplicated — derived
/// by running the identical record-building passes but minting nothing.
///
/// Since #323 a key is *claimed* as it is handed out, and this returns the claim
/// set itself: [_firstUnclaimed] only ever adds the key it returns, so "the keys
/// [link] resolves" and "the set returned here" are the same object built the
/// same way, rather than two computations that have to be kept in step.
///
/// A network-backed resolver cannot do I/O inside the synchronous
/// `PersonIdResolver.resolve`, so it uses this to mint-or-fetch every id in one
/// transaction *before* the pure [link] pass (see
/// `PreparablePersonIdResolver`). Sharing the record-building with [link] keeps
/// the key set and the resolve calls from ever drifting: any key returned here
/// is exactly one [link] will resolve, and vice versa. Group records carry no
/// [PersonId] (a group is keyed by name), so groups contribute nothing.
///
/// [ourSchoolIds] is passed through to the student pass for the same reason
/// [schoolPrefix] is — so the two entry points run the *identical* build. It
/// cannot move a key on its own (ownership only picks which of one person's
/// WISA rows supplies the class placement, #318, and every row of a person
/// carries the same `wisaId`), but leaving it out would make "identical passes"
/// a claim rather than a fact.
Set<String> naturalKeysFor(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot, {
  required String schoolPrefix,
  Set<int>? ourSchoolIds,
}) {
  // The duplicate-mail warnings are a byproduct of building; discarded here.
  final warnings = <LinkWarning>[];
  final studentRecords = _buildStudentRecords(
    wisaSnapshot,
    smartschoolSnapshot,
    azureSnapshot,
    schoolPrefix: schoolPrefix,
    ourSchoolIds: ourSchoolIds ?? const <int>{},
    warnings: warnings,
  );
  final staffRecords = _buildStaffRecords(
    wisaSnapshot,
    smartschoolSnapshot,
    azureSnapshot,
    schoolPrefix: schoolPrefix,
    warnings: warnings,
  );
  // Students first, then staff — the order [link] resolves in, which is the
  // order the claims have to be made in for the two to agree.
  final claimedKeys = <String>{};
  for (final rec in studentRecords) {
    _naturalKey(rec, claimedKeys);
  }
  for (final rec in staffRecords) {
    _naturalStaffKey(rec, claimedKeys);
  }
  return claimedKeys;
}

/// Builds one student [_Record] per linked person from the three snapshots,
/// running the student bridges (spec `docs/domain-model.md` §6.2) but leaving
/// identity resolution to the caller. Records are returned in creation order so
/// the output is a deterministic function of the input order (INV-20).
/// Duplicate-mail warnings (INV-23) are appended to [warnings].
///
/// [ourSchoolIds] is read for one decision only (#318): when the WISA pull
/// returns the same person from two group schools, which of those rows sits on
/// [_Record.wisa]. It never changes which records exist or what they are keyed
/// by — see [_prefersWisaRow].
List<_Record> _buildStudentRecords(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot, {
  required String schoolPrefix,
  required Set<int> ourSchoolIds,
  required List<LinkWarning> warnings,
}) {
  // Records in creation order; the output preserves this order so the result
  // is a deterministic function of the input lists' order (INV-20).
  final records = <_Record>[];
  // Normalized mail -> the records that claim it (usually one; >1 ⇒ INV-23).
  final byMail = <String, List<_Record>>{};
  // Normalized wisaId/accountId -> the first record indexed under it.
  final byWisaId = <String, _Record>{};

  // 1. Seed one record per Smartschool student account, in snapshot order.
  //    Staff (teacher/director role) are linked separately below, so they are
  //    skipped here — otherwise a staff account would be linked twice.
  for (final account in smartschoolSnapshot.accounts) {
    if (account.accountType != AccountType.student) continue;
    if (_isStaffRole(account.role)) continue;
    final rec = _Record(smartschool: account);
    records.add(rec);

    final mail = _norm(account.mail);
    if (mail != null) byMail.putIfAbsent(mail, () => []).add(rec);

    final wisaId = _norm(account.accountId);
    if (wisaId != null) byWisaId.putIfAbsent(wisaId, () => rec);
  }

  // INV-23: surface every mail shared by two or more accounts.
  for (final entry in byMail.entries) {
    if (entry.value.length < 2) continue;
    warnings.add(
      ResolveDuplicateMail(
        mail: entry.key,
        accounts: <SmartschoolAccount>[
          for (final rec in entry.value) rec.smartschool!,
        ],
      ),
    );
  }

  // 2. Attach WISA students by wisaId; unmatched ones become WISA-only
  //    placeholders. INV-21: every WISA student lands in exactly one record —
  //    one record per **person**, not per row (#318). The two are not the same
  //    thing: the WISA pull runs once per group school and concatenates the
  //    results, and `WisaStudent.schoolId` is a single int, so a student
  //    enrolled in two group schools arrives as *two rows sharing one wisaId*.
  //    Both rows are the same person, so the second merges its school id into
  //    the record the first made. Spawning a second record instead (what this
  //    did before) put two records on one `LinkedAccountId` — `_naturalKey`
  //    returns `wisa:<wisaId>` for either of them — and the action engine then
  //    offered one card the actions of both: create the Office 365 account of
  //    the ours-school record next to the Smartschool departure of the
  //    sibling-school one. The placeholder branch stays for the genuinely
  //    unmatched student, who is the first row of their own record.
  for (final student in wisaSnapshot.students) {
    final key = _norm(student.wisaId.value);
    final match = key == null ? null : byWisaId[key];
    if (match == null) {
      final placeholder = _Record(wisa: student)
        ..wisaClassGroups[student.schoolId] = student.classGroup.trim();
      records.add(placeholder);
      if (key != null) byWisaId.putIfAbsent(key, () => placeholder);
      continue;
    }
    // Every school this person was found in, so `_presence` can see that one
    // of them is ours even when another is not — and so a view can say which
    // class the other school holds them in (#334). The bare `classGroup` is
    // what lands here, the same fact the materialized `classroom` carries for
    // our own school, so the two class facts on one card are the same kind of
    // fact.
    match.wisaClassGroups[student.schoolId] = student.classGroup.trim();
    if (_prefersWisaRow(match.wisa, student, ourSchoolIds)) {
      match.wisa = student;
    }
  }

  // 3. Attach Azure users: by upn → mail, else by employeeId → wisaId, else
  //    keep school-prefix orphans (INV-22), else discard (another school).
  for (final user in azureSnapshot.users) {
    final upn = _norm(user.upn);
    final employeeId = _norm(user.employeeId);

    _Record? target;
    if (upn != null) {
      final candidates = byMail[upn];
      if (candidates != null) {
        for (final rec in candidates) {
          if (rec.azure == null) {
            target = rec;
            break;
          }
        }
      }
    }
    if (target == null && employeeId != null) {
      final rec = byWisaId[employeeId];
      if (rec != null && rec.azure == null) target = rec;
    }

    if (target != null) {
      target.azure = user;
    } else if (studentBelongsToSchool(user.companyName, schoolPrefix)) {
      records.add(_Record(azure: user));
    }
    // else: a user belonging to another school — not our concern, dropped.
  }

  return records;
}

/// Builds one staff [_StaffRecord] per linked staff member, mirroring
/// [_buildStudentRecords] but using the staff-specific bridges (see the [link]
/// doc-comment): WISA staff match Smartschool by `code` (≡ `accountId`) and
/// Azure by `wisaId` (≡ `employeeId`). Appends any duplicate-mail warnings to
/// [warnings].
List<_StaffRecord> _buildStaffRecords(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot, {
  required String schoolPrefix,
  required List<LinkWarning> warnings,
}) {
  final records = <_StaffRecord>[];
  // Normalized mail -> the staff records that claim it (>1 ⇒ INV-23).
  final byMail = <String, List<_StaffRecord>>{};
  // Normalized Smartschool accountId (≡ WISA staff `code`) -> first record.
  final byCode = <String, _StaffRecord>{};
  // Normalized WISA staff `wisaId` -> the record holding that staff member,
  // for the Azure `employeeId` bridge.
  final byWisaId = <String, _StaffRecord>{};

  // 1. Seed one record per Smartschool staff account, in snapshot order.
  for (final account in smartschoolSnapshot.accounts) {
    if (!_isStaffRole(account.role)) continue;
    final rec = _StaffRecord(smartschool: account);
    records.add(rec);

    final mail = _norm(account.mail);
    if (mail != null) byMail.putIfAbsent(mail, () => []).add(rec);

    final code = _norm(account.accountId);
    if (code != null) byCode.putIfAbsent(code, () => rec);
  }

  // INV-23: surface every mail shared by two or more staff accounts.
  for (final entry in byMail.entries) {
    if (entry.value.length < 2) continue;
    warnings.add(
      ResolveDuplicateMail(
        mail: entry.key,
        accounts: <SmartschoolAccount>[
          for (final rec in entry.value) rec.smartschool!,
        ],
      ),
    );
  }

  // 2. Attach WISA staff by `code`; unmatched ones become WISA-only
  //    placeholders. Every WISA staff member lands in exactly one record, and
  //    that record is indexed by `wisaId` for the Azure bridge in pass 3.
  for (final member in wisaSnapshot.staff) {
    final codeKey = _norm(member.code.value);
    final match = codeKey == null ? null : byCode[codeKey];
    final _StaffRecord target;
    if (match != null && match.wisa == null) {
      match.wisa = member;
      target = match;
    } else {
      target = _StaffRecord(wisa: member);
      records.add(target);
      if (codeKey != null) byCode.putIfAbsent(codeKey, () => target);
    }
    final wisaIdKey = _norm(member.wisaId?.value);
    if (wisaIdKey != null) byWisaId.putIfAbsent(wisaIdKey, () => target);
  }

  // 3. Attach Azure users: by upn → mail, else by employeeId → wisaId, else
  //    keep school-prefix orphans (INV-22 staff variant: `department` contains
  //    the prefix), else discard (belongs to another school / population).
  for (final user in azureSnapshot.users) {
    final upn = _norm(user.upn);
    final employeeId = _norm(user.employeeId);

    _StaffRecord? target;
    if (upn != null) {
      final candidates = byMail[upn];
      if (candidates != null) {
        for (final rec in candidates) {
          if (rec.azure == null) {
            target = rec;
            break;
          }
        }
      }
    }
    if (target == null && employeeId != null) {
      final rec = byWisaId[employeeId];
      if (rec != null && rec.azure == null) target = rec;
    }

    if (target != null) {
      target.azure = user;
    } else if (staffBelongsToSchool(user.department, schoolPrefix)) {
      records.add(_StaffRecord(azure: user));
    }
    // else: a user belonging to another school/population — dropped.
  }

  return records;
}

/// Links the class-group population, ported from legacy
/// `LinkedGroups.DoRelink`. Groups are matched purely **by name**: a WISA class
/// group's `fullName` against a Smartschool official class's `name` and an
/// Azure group's `displayName`. There is no stable cross-system id for a group,
/// so the name *is* the bridge.
///
/// WISA class groups seed records first, but a Smartschool or Azure group
/// matching no WISA class is no longer dropped (#52): it becomes an orphan
/// [LinkedGroup] with `wisa: null`, mirroring how an Azure-only [LinkedAccount]
/// is kept for a former student. This lets the action engine raise a delete
/// action for a class that vanished from WISA but still exists downstream.
///
/// Only class groups of the schools we manage ([ourSchoolIds]) seed records
/// (#205). The shared WISA credentials pull every group-visible school, so
/// without this every sibling school's class was linked and offered as
/// `AddToSmartschool` — a proposal to create another school's class in *our*
/// Smartschool. Skipping them at the seed also fixes the quieter half of the
/// bug: records are keyed by normalized name and collapse to the first seen, so
/// a foreign `1A` arriving first used to shadow our own `1A`. As with students,
/// an empty [ourSchoolIds] means ownership is unconfigured and every school is
/// treated as ours (see [_isOurWisaSchool]).
///
/// The class groups of a **virtual** school ([virtualSchoolIds], #209) are
/// skipped on top of that: a class group seeds a record only when its school is
/// *ours **and** not virtual* (see [_seedsClassGroups]). Ownership alone never
/// excluded them — the operator's virtual school is normally marked managed as
/// well — so their (always empty) classes reached the engine as
/// [CreateInSmartschool] notices, cluttering the Klasgroepen list and inviting
/// the creation of defunct classes in Smartschool. The exclusion is deliberately
/// *only* about class groups: the students and staff of a virtual school are
/// untouched here and keep linking exactly as before.
///
/// A consequence, decided deliberately: an official Smartschool class whose
/// only WISA counterpart is a class of a school we do not manage — or of a
/// virtual school — now becomes a Smartschool orphan record (#52) rather than
/// linking to a class we have no business managing. The action engine then
/// treats it as the orphan it is instead of silently considering it in sync;
/// the orphan action is `DeleteSmartschoolClass` (or, where that cannot fire,
/// the informational `DoNotImportFromSmartschool`), and it is a proposal on one
/// row behind a confirmation — never a bulk pass and never automatic.
///
/// Only `official` Smartschool groups are considered (legacy
/// `AddSmartschoolChildGroups` walked the "Leerlingen" subtree and linked only
/// official classes); organisational sub-groups never match or seed orphans.
///
/// That skip used to be *silent*, which is how #225 happened: a class that
/// exists in Smartschool but is not flagged official reads exactly like a class
/// that is not there at all, and the action engine then offered to create it —
/// a duplicate name Smartschool either rejects or ends up holding twice. So
/// **every** Smartschool group is indexed by name, official or not: a WISA class
/// left unlinked but whose name a Smartschool group already carries keeps that
/// group on [LinkedGroup.smartschoolNamesake] (never as [LinkedGroup.smartschool]
/// — an unofficial group is still not a class) and raises a
/// [SmartschoolNamesakeSkipped] warning. The namesake lookup falls back to the
/// whitespace-insensitive [groupNameFingerprint], so a hand-typed `2 G` is
/// recognised as the existing `2G` even though it is too loose a key to link on.
///
/// The Azure side of the match is **prefix-aware** (#228). The Office 365 group
/// of a class is named `<PREFIX>-<KLAS>` after the **bare** class name — `2F`,
/// never the sub-grouped `2F ECO` — so `displayName` is stripped of the school
/// prefix ([azureClassNameOf]) and matched against [LinkedGroup.className]
/// rather than against the WISA `fullName`. Without that, `GBS-2A` would match
/// no class at all and seed a spurious orphan *while* leaving `2A` reading as
/// having no group; with it, one `GBS-2F` attaches to every one of that class's
/// sub-group records, which is exactly what "sub-groups get no group of their
/// own" means. The pre-#228 exact-`displayName` match is kept as a fallback so a
/// hand-made, unprefixed group still links the way it used to.
///
/// Azure carries no `official`-style signal — [az.AzureGroup] is just
/// `{id, displayName, securityEnabled, mail, mailNickname}` — so an unmatched
/// Azure group is kept as an orphan only when the name it carries is shaped
/// like a class (see [_looksLikeClassGroup] and [looksLikeClassName], #271).
/// The naming convention `<PREFIX>-<KLAS>` this app writes (#228) *is* the
/// positive signal, so this is an allowlist; before #271 it was a denylist of
/// four staff-group suffixes, which kept every other prefixed group — subject,
/// project and council groups included — as a class orphan.
///
/// Confidence mirrors accounts/staff: `high` only when all three systems carry
/// the group — and because the match key *is* the (normalized) name, presence
/// in all three implies the keys agree — otherwise `medium` (including every
/// orphan record, per #52). All comparisons are trimmed + case-insensitive
/// (INV-12).
List<LinkedGroup> _linkGroups(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot,
  Set<int> ourSchoolIds,
  Set<int> virtualSchoolIds,
  String schoolPrefix,
  List<LinkWarning> warnings,
) {
  final records = <_GroupRecord>[];
  // Normalized fullName/name/displayName -> the record indexed under it.
  final byName = <String, _GroupRecord>{};
  // Normalized **bare** class name -> every record of that class, in seed
  // order (#228). A class split into sub-groups seeds one record per sub-group
  // and they all share one Office 365 group, so this is a one-to-many index
  // where [byName] is one-to-one.
  final byClassName = <String, List<_GroupRecord>>{};

  // Every Smartschool group by name, official or not (#225) — the index the
  // "does this class already exist downstream?" guard consults after the link
  // passes have run. Two keys per group: the exact match key, and the looser
  // whitespace-insensitive fingerprint. First wins on both, so the answer is a
  // deterministic function of snapshot order (INV-20).
  final ssByName = <String, Group>{};
  final ssByFingerprint = <String, Group>{};
  for (final group in smartschoolSnapshot.groups) {
    final key = normalizeGroupName(group.name);
    if (key == null) continue;
    ssByName.putIfAbsent(key, () => group);
    ssByFingerprint.putIfAbsent(groupNameFingerprint(group.name)!, () => group);
  }

  // 1. Seed one record per distinct WISA class group, in snapshot order, keyed
  //    by its `fullName`. Class groups of schools we do not manage are skipped
  //    outright (#205) — the shared WISA credentials pull every group school,
  //    and a sibling school's class must never reach the action engine — and so
  //    are those of a virtual school (#209), whose classes are a dead concept.
  //    The filter runs *before* the dedupe so an excluded class can no longer
  //    occupy the name key of one of ours. Duplicate fullNames among our own
  //    classes still collapse to the first record so the output is a
  //    deterministic function of the input order (INV-20).
  for (final group in wisaSnapshot.classGroups) {
    if (!_seedsClassGroups(group.schoolId, ourSchoolIds, virtualSchoolIds)) {
      continue;
    }
    final key = normalizeGroupName(group.fullName);
    if (key == null || byName.containsKey(key)) continue;
    final rec = _GroupRecord(wisa: group);
    records.add(rec);
    byName[key] = rec;
    // Index the same record under its bare class name for the prefix-aware
    // Azure match (#228). `fullName == name` for a class without sub-groups, so
    // the two indexes coincide there; a sub-grouped class contributes several
    // records to the one bare name.
    final bare = normalizeGroupName(group.name);
    if (bare != null) (byClassName[bare] ??= <_GroupRecord>[]).add(rec);
  }

  // 2. Attach official Smartschool class groups by name; non-official
  //    organisational groups never link or seed orphans. An official group
  //    matching no WISA class becomes an orphan record (#52) instead of being
  //    dropped.
  for (final group in smartschoolSnapshot.groups) {
    if (!group.official) continue;
    final key = normalizeGroupName(group.name);
    if (key == null) continue;
    final existing = byName[key];
    if (existing != null) {
      existing.smartschool ??= group;
    } else {
      final rec = _GroupRecord(smartschool: group);
      records.add(rec);
      byName[key] = rec;
    }
  }

  // 2b. A WISA class the official pass left unmatched, whose name Smartschool
  //     already carries in *some* form, keeps that namesake (#225) instead of
  //     reading as "not there" — the state that made the engine propose
  //     creating a duplicate class. Runs after pass 2 so a class that did link
  //     is never second-guessed, and skips a group another WISA class already
  //     linked to: that name belongs to *that* class, not this one. A
  //     Smartschool-only orphan (#52) is deliberately not "taken" — no WISA
  //     class owns it, and its name is exactly the one a create would collide
  //     with.
  final claimed = <String>{
    for (final rec in records)
      if (rec.wisa != null && rec.smartschool != null)
        rec.smartschool!.id.value,
  };
  for (final rec in records) {
    final wisa = rec.wisa;
    if (wisa == null || rec.smartschool != null) continue;
    final key = normalizeGroupName(wisa.fullName);
    if (key == null) continue;
    final namesake =
        ssByName[key] ?? ssByFingerprint[groupNameFingerprint(wisa.fullName)!];
    if (namesake == null || claimed.contains(namesake.id.value)) continue;
    rec.smartschoolNamesake = namesake;
    warnings.add(
      SmartschoolNamesakeSkipped(
          wisaName: wisa.fullName, smartschool: namesake),
    );
  }

  // 3. Attach Azure groups, prefix-aware (#228): `GBS-2F` is the Office 365
  //    group of class `2F`, so the prefix is stripped and the remainder matched
  //    against the **bare** class name — attaching to every sub-group record of
  //    that class, since they share the one group. A group whose name is not in
  //    our `<PREFIX>-` namespace falls back to the pre-#228 exact-`displayName`
  //    match, so an unprefixed group somebody made by hand still links.
  //
  //    …and when the display name says nothing, the **mailNickname** does
  //    (#280). The address is what makes a class group ours — it is the key the
  //    create collides on and the key the pull's back-fill adopts by — so a
  //    group answering on `<PREFIX>-<KLAS>` whose display name somebody renamed
  //    by hand is the class's group all the same. Without this leg the adopted
  //    row reaches the linker and is dropped again, and the create it was
  //    supposed to retire keeps being proposed.
  //
  //    An Azure group matching no existing record becomes an orphan too (#52),
  //    but only when the name it carries is shaped like a class (#271) — a
  //    prefixed group whose remainder is `GOK`, `OKAN` or `Leerlingenraad` is
  //    not a class group and belongs in no class inventory.
  for (final group in azureSnapshot.groups) {
    final key = normalizeGroupName(group.displayName);
    if (key == null) continue;
    final bare = azureClassNameOf(group.displayName, schoolPrefix) ??
        azureClassNameOf(group.mailNickname, schoolPrefix);
    final ofClass = bare == null ? null : byClassName[normalizeGroupName(bare)];
    if (ofClass != null && ofClass.isNotEmpty) {
      for (final rec in ofClass) {
        rec.azure ??= group;
      }
      continue;
    }
    final existing = byName[key];
    if (existing != null) {
      existing.azure ??= group;
    } else if (_looksLikeClassGroup(group.displayName, bare)) {
      final rec = _GroupRecord(azure: group, className: bare);
      records.add(rec);
      byName[key] = rec;
    }
  }

  // 4. Freeze each record into an immutable [LinkedGroup].
  return <LinkedGroup>[
    for (final rec in records)
      LinkedGroup(
        wisa: rec.wisa == null ? null : _wisaToCoreGroup(rec.wisa!),
        smartschool: rec.smartschool,
        smartschoolNamesake: rec.smartschoolNamesake,
        azure: rec.azure,
        className: rec.wisa?.name ?? rec.className,
        confidence:
            rec.wisa != null && rec.smartschool != null && rec.azure != null
                ? LinkConfidence.high
                : LinkConfidence.medium,
      ),
  ];
}

/// Whether an unmatched Azure group is kept as a stale-class orphan (#52) —
/// an **allowlist** on the class-name shape since #271, where it used to be a
/// four-suffix denylist (`-personeel`, `-directie`, `-secretariaat`,
/// `-leraren`).
///
/// The denylist was written because [az.AzureGroup] carried no positive
/// class-group signal — `securityEnabled` does not split the populations
/// either, since legacy creates both a security and a plain variant of
/// `{prefix}-Personeel` for the same staff population. That stopped being true
/// with #228: the app now *creates* class groups as `<PREFIX>-<KLAS>` through
/// [azureClassGroupName], so the naming convention itself is the signal, and
/// [looksLikeClassName] can test the remainder [azureClassNameOf] recovered.
///
/// The consequence is the whole of #271. The Azure snapshot is prefix-scoped by
/// the connector, so a denylist kept **every** prefixed group that was not one
/// of those four — `SSM - GOK`, `SSM - Leerlingenraad`, `SSM - Frans - 3D` —
/// each of them an orphan record, a Klasgroepen row, and no action to take on
/// it. The allowlist keeps only what is shaped like a class, and
/// `SSM-Personeel` now fails it on its own (`Personeel` is not a class name),
/// which is why the four suffixes are gone rather than kept alongside.
///
/// [bare] is the remainder inside our `<PREFIX>-` namespace, or null for a
/// group outside it. A group *outside* the namespace is judged on its full
/// [displayName], which preserves the pre-#228 behaviour for the hand-made,
/// unprefixed `5A` somebody created without the school's prefix: the exact-name
/// match above adopts it when a class owns it, and this keeps it as an orphan
/// when none does. It carries no recoverable class name, so it raises no
/// stale-group action either way — neither `DeleteAzureClassGroup` nor the
/// `AzureClassGroupWithoutClass` notice that stands in where the delete cannot
/// act.
bool _looksLikeClassGroup(String? displayName, String? bare) =>
    looksLikeClassName(bare ?? displayName);

/// Projects a [wapi.WisaClassGroup] to the canonical [Group] that
/// [LinkedGroup.wisa] expects. The group is identified and named by its
/// `fullName` (the cross-system match key); WISA class groups are always real
/// classes, hence `official: true` and [GroupType.classGroup]. `schoolCode`
/// becomes the institute number and `adminCode` the numeric admin number (both
/// feed `AddToSmartschool` when it creates the Smartschool class). WISA exposes
/// no tree edge, so [Group.parentId] stays null, and no Untis code, so
/// [Group.untis] is empty — the created Smartschool class derives its Untis
/// from the class name instead.
Group _wisaToCoreGroup(wapi.WisaClassGroup g) => Group(
      id: GroupId(g.fullName),
      name: g.fullName,
      description: g.description,
      type: GroupType.classGroup,
      official: true,
      instituteNumber: g.schoolCode.isEmpty ? null : g.schoolCode,
      adminNumber: int.tryParse(g.adminCode),
      origin: Origin.wisa,
    );

/// Mutable accumulator for one linked person while the passes run; frozen into
/// an immutable [LinkedAccount] at the end.
class _Record {
  ss.SmartschoolAccount? smartschool;

  /// The WISA row this person's class placement is read from. A person enrolled
  /// in two group schools has two rows (#318); the one from a school we manage
  /// wins, see [_prefersWisaRow]. Every school they were found in is on
  /// [wisaClassGroups] regardless of which row this holds.
  wapi.WisaStudent? wisa;

  az.AzureUser? azure;

  /// Every WISA school this record's student was found in, mapped to the class
  /// that school's row holds them in — accumulated as WISA rows attach (a single
  /// entry in the common case; more only for a student enrolled across group
  /// schools). Frozen onto [LinkedAccount.wisaClassGroups].
  ///
  /// The class travels with the school id because a sibling school's enrolment
  /// is something a view *states* rather than merely counts (#334): the ids
  /// alone can say "she is also somewhere else", never where. It stays presence
  /// either way — the class we write is [wisa]'s, never one read from here
  /// (INV-25).
  final Map<int, String> wisaClassGroups = <int, String>{};

  /// The school ids of [wisaClassGroups] — what [_presence] classifies.
  Set<int> get wisaSchoolIds => wisaClassGroups.keys.toSet();

  _Record({this.smartschool, this.wisa, this.azure});
}

/// Mutable accumulator for one linked staff member; the staff analogue of
/// [_Record], carrying [wapi.WisaStaff] (with its `code`) instead of a
/// [wapi.WisaStudent]. Frozen into an immutable [LinkedStaff] at the end.
class _StaffRecord {
  ss.SmartschoolAccount? smartschool;
  wapi.WisaStaff? wisa;
  az.AzureUser? azure;

  _StaffRecord({this.smartschool, this.wisa, this.azure});
}

/// Mutable accumulator for one linked class group; the group analogue of
/// [_Record]. [wisa] is nullable (#52): a record may instead be seeded from an
/// orphan Smartschool or Azure group with no WISA anchor. Frozen into an
/// immutable [LinkedGroup] at the end.
class _GroupRecord {
  wapi.WisaClassGroup? wisa;
  Group? smartschool;
  az.AzureGroup? azure;

  /// The Smartschool group carrying this class's name that the official-class
  /// pass could not adopt (#225). See [LinkedGroup.smartschoolNamesake].
  Group? smartschoolNamesake;

  /// The bare class name for a record with **no** WISA anchor — recovered from
  /// an orphan Azure group's `<PREFIX>-` display name (#228). A WISA-seeded
  /// record reads its bare name off [wisa] instead.
  final String? className;

  _GroupRecord({this.wisa, this.smartschool, this.azure, this.className});
}

/// Whether a Smartschool [role] marks the account as staff (teacher or
/// director) rather than a student. A `null` role (unrecognised Basisrol) is
/// treated as non-staff so it stays in the student population, matching the
/// pre-staff behaviour. The staff/student split derives from `role` because
/// [SmartschoolAccount.accountType] is always `student` for a primary record.
bool _isStaffRole(PersonRole? role) =>
    role == PersonRole.teacher || role == PersonRole.director;

/// Trims and lowercases [value] for case-insensitive, whitespace-tolerant
/// comparison (INV-12). Returns `null` when [value] is null or blank so empty
/// keys never match or index anything.
///
/// For **identifiers** — mails, uids, wisaIds, staff codes — where internal
/// whitespace is not a thing an operator types by accident. Group *names* go
/// through [normalizeGroupName] instead, which additionally collapses internal
/// whitespace runs and non-breaking spaces (#225).
String? _norm(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed.toLowerCase();
}

/// Whether [candidate] should displace [held] as the WISA row a record carries
/// on [_Record.wisa], when both rows are the *same person* read from two
/// different group schools (#318).
///
/// The rows agree on identity — one `wisaId` — but not on `schoolId`, and with
/// it not on `classGroup`/`classSubGroup`. That class is what every downstream
/// placement is derived from (the Smartschool class to enrol into, the Office
/// 365 class group to join), and it must come from **our** school's row, not
/// from whichever school the concatenated pull happened to read first. So a row
/// of a managed school displaces one of a sibling school, and nothing else
/// displaces anything: ours-vs-ours and sibling-vs-sibling both keep the row
/// already held, so the result stays a deterministic function of snapshot order
/// (INV-20). With ownership unconfigured ([ourSchoolIds] empty) every school
/// counts as ours — the same fallback [_presence] applies — so the first row
/// stands, exactly as it did before #318.
bool _prefersWisaRow(
  wapi.WisaStudent? held,
  wapi.WisaStudent candidate,
  Set<int> ourSchoolIds,
) {
  if (held == null) return true;
  if (ourSchoolIds.isEmpty) return false;
  return ourSchoolIds.contains(candidate.schoolId) &&
      !ourSchoolIds.contains(held.schoolId);
}

/// Classifies a student's WISA presence (#134) from the [wisaSchoolIds] its
/// record was found in and the set of schools we manage ([ourSchoolIds]).
///
/// No WISA record ⇒ [WisaPresence.absent] (gone from the whole group). When
/// [ourSchoolIds] is empty the ownership link is unconfigured, so any WISA
/// presence counts as [WisaPresence.ours] — the pre-#134 behaviour. Otherwise a
/// record is [WisaPresence.ours] when it was found in at least one managed
/// school, and [WisaPresence.groupOnly] when found only in sibling schools.
WisaPresence _presence(Set<int> wisaSchoolIds, Set<int> ourSchoolIds) {
  if (wisaSchoolIds.isEmpty) return WisaPresence.absent;
  if (ourSchoolIds.isEmpty) return WisaPresence.ours;
  return wisaSchoolIds.any(ourSchoolIds.contains)
      ? WisaPresence.ours
      : WisaPresence.groupOnly;
}

/// Whether a WISA class group's [schoolId] belongs to a school we manage
/// ([ourSchoolIds], #205). Mirrors the fallback [_presence] applies to
/// students: an empty [ourSchoolIds] means ownership is unconfigured, so every
/// school counts as ours and group linking keeps its pre-#205 behaviour.
bool _isOurWisaSchool(int schoolId, Set<int> ourSchoolIds) =>
    ourSchoolIds.isEmpty || ourSchoolIds.contains(schoolId);

/// Whether a WISA class group of [schoolId] may seed a linked group record:
/// the school must be one we manage (#205) **and** not one marked virtual
/// (#209). The two exclusions compose rather than replace each other — a
/// virtual school is normally marked managed too, so ownership alone let its
/// classes through, and the "ownership unconfigured ⇒ everything is ours"
/// fallback in [_isOurWisaSchool] still holds with the virtual exclusion
/// layered on top. Applies to class groups only; students and staff of a
/// virtual school are unaffected.
bool _seedsClassGroups(
  int schoolId,
  Set<int> ourSchoolIds,
  Set<int> virtualSchoolIds,
) =>
    _isOurWisaSchool(schoolId, ourSchoolIds) &&
    !virtualSchoolIds.contains(schoolId);

/// The natural key handed to the [PersonIdResolver]: the first of
/// `wisaId → mail → upn → azureId → uid` that no earlier record has [claimed],
/// normalized and namespaced so the resolver mints a stable, derived
/// [PersonId]. The wisaId is taken from whichever system carries it.
String _naturalKey(_Record rec, Set<String> claimed) {
  final wisaId = _norm(
    rec.wisa?.wisaId.value ??
        rec.smartschool?.accountId ??
        rec.azure?.employeeId,
  );
  final mail = _norm(rec.smartschool?.mail);
  final upn = _norm(rec.azure?.upn);
  final azureId = _norm(rec.azure?.id);
  // A Smartschool-only account may carry neither an accountId nor a mail
  // (real data: e.g. intern accounts) — its uid is then the only identity.
  final uid = _norm(rec.smartschool?.uid);

  final candidates = <String>[
    if (wisaId != null) 'wisa:$wisaId',
    if (mail != null) 'mail:$mail',
    if (upn != null) 'upn:$upn',
    if (azureId != null) 'azure:$azureId',
    if (uid != null) 'ss:$uid',
  ];
  if (candidates.isEmpty) {
    // Unreachable: every record carries at least one identifying field.
    throw StateError('LinkedAccount record has no identifying key: $rec');
  }
  return _firstUnclaimed(candidates, claimed);
}

/// The first of [candidates] — one record's identifying keys in preference
/// order — that no earlier record has taken, added to [claimed] as it is handed
/// out.
///
/// This is what stops an **INV-23 duplicate-mail pair from landing two records
/// on one [LinkedAccountId]** (#323). INV-23 deliberately keeps both Smartschool
/// accounts of a colliding pair, so the deliberate admin+user co-account setup
/// yields two records for one person — and by the operator's convention both
/// carry the *same* `accountId` (the WISA id of that student), or neither
/// carries one and both fall back to the very mail that made them collide.
/// Either way the preferred key is identical, the resolver hands both records
/// the same id, and every layer below the linker then unions or drops without a
/// word. Falling through to the next key gives the second record an id of its
/// own, ending on `ss:<uid>` / `azure:<id>`, which are unique per record.
///
/// First claim wins, in record order — the rule every other index in this file
/// uses (`putIfAbsent`), so the outcome stays a deterministic function of
/// snapshot order (INV-20). It also leaves the preferred key on the record the
/// WISA and Azure passes attached to, because those passes are first-wins in
/// that same order: the person's fully-linked record keeps `wisa:<id>` and the
/// extra co-account is the one that moves.
///
/// Merging the pair into one record instead — the other option #323 weighs — is
/// not available here: a [LinkedAccount] holds a single Smartschool account, so
/// merging means dropping one, which is the exact silent loss INV-23 exists to
/// prevent.
///
/// If *every* candidate is spoken for, the preferred key is returned anyway and
/// the collision reaches [LinkedSnapshot.fromRecords], which reports it as
/// INV-24. Any record with a Smartschool or Azure side ends on its unique
/// `uid`/object id, so that leaves the WISA-only records: a WISA-only *student*
/// is unique by `wisaId` (INV-21 merges the rows of one person), but two WISA
/// *staff* rows sharing a `code` with no `wisaId` to tell them apart really do
/// have one candidate between them. They stay a reported collision on purpose —
/// WISA is claiming one identity for two rows, and inventing a second here would
/// hide that rather than fix it.
String _firstUnclaimed(List<String> candidates, Set<String> claimed) {
  for (final key in candidates) {
    if (claimed.add(key)) return key;
  }
  return candidates.first;
}

/// `high` only when all three systems are present *and* every bridge key
/// agrees; anything weaker (a missing system, or a forced match where a key
/// disagrees) is `medium`.
LinkConfidence _confidence(_Record rec) {
  final student = rec.wisa;
  final account = rec.smartschool;
  final user = rec.azure;
  if (student == null || account == null || user == null) {
    return LinkConfidence.medium;
  }

  final upn = _norm(user.upn);
  final mail = _norm(account.mail);
  final mailAgrees = upn != null && upn == mail;

  final wisaId = _norm(student.wisaId.value);
  final accountId = _norm(account.accountId);
  final employeeId = _norm(user.employeeId);
  final idAgrees =
      wisaId != null && wisaId == accountId && wisaId == employeeId;

  return mailAgrees && idAgrees ? LinkConfidence.high : LinkConfidence.medium;
}

/// The natural key for a staff member: the first of
/// `wisaId → code → mail → upn → azureId → uid` that no earlier record has
/// [claimed], normalized and namespaced under `staff:` so a staff member never
/// collides with a student who happens to share a numeric id. `wisaId` (the
/// Azure bridge) is preferred, then the Smartschool-side `code`.
///
/// The fall-through is the student rule applied to the staff population
/// ([_firstUnclaimed], #323): staff raise [ResolveDuplicateMail] on a shared
/// mail exactly as students do, and two staff accounts sharing an `accountId`
/// with no WISA `wisaId` to separate them collide on `staff:code:<code>` the
/// same way.
String _naturalStaffKey(_StaffRecord rec, Set<String> claimed) {
  final wisaId = _norm(rec.wisa?.wisaId?.value ?? rec.azure?.employeeId);
  final code = _norm(rec.wisa?.code.value ?? rec.smartschool?.accountId);
  final mail = _norm(rec.smartschool?.mail);
  final upn = _norm(rec.azure?.upn);
  final azureId = _norm(rec.azure?.id);
  // A Smartschool-only account may carry neither an accountId nor a mail
  // (real data: e.g. intern accounts) — its uid is then the only identity.
  final uid = _norm(rec.smartschool?.uid);

  final candidates = <String>[
    if (wisaId != null) 'staff:wisa:$wisaId',
    if (code != null) 'staff:code:$code',
    if (mail != null) 'staff:mail:$mail',
    if (upn != null) 'staff:upn:$upn',
    if (azureId != null) 'staff:azure:$azureId',
    if (uid != null) 'staff:ss:$uid',
  ];
  if (candidates.isEmpty) {
    // Unreachable: every record carries at least one identifying field.
    throw StateError('LinkedStaff record has no identifying key: $rec');
  }
  return _firstUnclaimed(candidates, claimed);
}

/// `high` only when all three systems are present *and* both staff bridges
/// agree: `upn == mail`, `accountId == code` (Smartschool ↔ WISA), and
/// `employeeId == wisaId` (Azure ↔ WISA). Anything weaker is `medium`.
LinkConfidence _staffConfidence(_StaffRecord rec) {
  final member = rec.wisa;
  final account = rec.smartschool;
  final user = rec.azure;
  if (member == null || account == null || user == null) {
    return LinkConfidence.medium;
  }

  final upn = _norm(user.upn);
  final mail = _norm(account.mail);
  final mailAgrees = upn != null && upn == mail;

  final code = _norm(member.code.value);
  final accountId = _norm(account.accountId);
  final codeAgrees = code != null && code == accountId;

  final wisaId = _norm(member.wisaId?.value);
  final employeeId = _norm(user.employeeId);
  final idAgrees = wisaId != null && wisaId == employeeId;

  return mailAgrees && codeAgrees && idAgrees
      ? LinkConfidence.high
      : LinkConfidence.medium;
}
