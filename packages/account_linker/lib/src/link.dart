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
/// `companyName == schoolPrefix` keeps a former *student*, `department`
/// containing the prefix keeps a former *staff* member.
///
/// Fixes carried over from the legacy linker:
/// - **INV-12:** every `mail`/`upn`/id comparison is trimmed and
///   case-insensitive (legacy `.Equals()` was case-sensitive).
/// - **INV-23:** two Smartschool accounts sharing a `mail` are *both* kept and
///   a [ResolveDuplicateMail] warning is raised (legacy silently dropped one).
///
/// [schoolPrefix] is the Azure `companyName` value the school stamps on its
/// own users; an Azure-only user carrying it is a former student kept as an
/// incomplete record so the action engine can flag it for deletion (INV-22).
LinkedSnapshot link(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot,
  PersonIdResolver resolver, {
  required String schoolPrefix,
}) {
  // Records in creation order; the output preserves this order so the result
  // is a deterministic function of the input lists' order (INV-20).
  final records = <_Record>[];
  // Normalized mail -> the records that claim it (usually one; >1 ⇒ INV-23).
  final byMail = <String, List<_Record>>{};
  // Normalized wisaId/accountId -> the first record indexed under it.
  final byWisaId = <String, _Record>{};
  final warnings = <LinkWarning>[];

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
  //    placeholders. INV-21: every WISA student lands in exactly one record.
  for (final student in wisaSnapshot.students) {
    final key = _norm(student.wisaId.value);
    final match = key == null ? null : byWisaId[key];
    if (match != null && match.wisa == null) {
      match.wisa = student;
    } else {
      final placeholder = _Record(wisa: student);
      records.add(placeholder);
      if (key != null) byWisaId.putIfAbsent(key, () => placeholder);
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
    } else if (_matchesPrefix(user.companyName, schoolPrefix)) {
      records.add(_Record(azure: user));
    }
    // else: a user belonging to another school — not our concern, dropped.
  }

  // 4. Resolve a stable identity and confidence for each record.
  final accounts = <LinkedAccount>[
    for (final rec in records)
      LinkedAccount(
        id: LinkedAccountId(resolver.resolve(_naturalKey(rec)).value),
        role: PersonRole.student,
        wisa: rec.wisa,
        smartschool: rec.smartschool,
        azure: rec.azure,
        confidence: _confidence(rec),
      ),
  ];

  final staff = _linkStaff(
    wisaSnapshot,
    smartschoolSnapshot,
    azureSnapshot,
    resolver,
    schoolPrefix: schoolPrefix,
    warnings: warnings,
  );

  final groups = _linkGroups(wisaSnapshot, smartschoolSnapshot, azureSnapshot);

  return LinkedSnapshot.fromRecords(
    accounts: accounts,
    staff: staff,
    groups: groups,
    warnings: warnings,
  );
}

/// Links the staff population, mirroring the student passes above but using
/// the staff-specific bridges (see the `link` doc-comment): WISA staff match
/// Smartschool by `code` (≡ `accountId`) and Azure by `wisaId` (≡
/// `employeeId`). Appends any duplicate-mail warnings to [warnings].
List<LinkedStaff> _linkStaff(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot,
  PersonIdResolver resolver, {
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
    } else if (_departmentMatchesPrefix(user.department, schoolPrefix)) {
      records.add(_StaffRecord(azure: user));
    }
    // else: a user belonging to another school/population — dropped.
  }

  // 4. Resolve a stable identity, role, and confidence for each record.
  return <LinkedStaff>[
    for (final rec in records)
      LinkedStaff(
        id: LinkedAccountId(resolver.resolve(_naturalStaffKey(rec)).value),
        role: rec.smartschool?.role ?? PersonRole.teacher,
        wisa: rec.wisa,
        smartschool: rec.smartschool,
        azure: rec.azure,
        confidence: _staffConfidence(rec),
      ),
  ];
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
/// Only `official` Smartschool groups are considered (legacy
/// `AddSmartschoolChildGroups` walked the "Leerlingen" subtree and linked only
/// official classes); organisational sub-groups never match or seed orphans.
///
/// Azure carries no `official`-style signal — [az.AzureGroup] is just
/// `{id, displayName, securityEnabled}` — so an unmatched Azure group is kept
/// as an orphan *unless* its name looks administrative (see
/// [_looksLikeClassGroup]); staff/directorate/secretariat groups are excluded
/// by name rather than included by one, since there is no positive
/// class-group signal to include by.
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
) {
  final records = <_GroupRecord>[];
  // Normalized fullName/name/displayName -> the record indexed under it.
  final byName = <String, _GroupRecord>{};

  // 1. Seed one record per distinct WISA class group, in snapshot order, keyed
  //    by its `fullName`. Duplicate fullNames collapse to the first record so
  //    the output is a deterministic function of the input order (INV-20).
  for (final group in wisaSnapshot.classGroups) {
    final key = _norm(group.fullName);
    if (key == null || byName.containsKey(key)) continue;
    final rec = _GroupRecord(wisa: group);
    records.add(rec);
    byName[key] = rec;
  }

  // 2. Attach official Smartschool class groups by name; non-official
  //    organisational groups never link or seed orphans. An official group
  //    matching no WISA class becomes an orphan record (#52) instead of being
  //    dropped.
  for (final group in smartschoolSnapshot.groups) {
    if (!group.official) continue;
    final key = _norm(group.name);
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

  // 3. Attach Azure groups by displayName. An Azure group matching no
  //    existing record becomes an orphan too (#52), but only when it looks
  //    like a stale class rather than a staff/administrative group.
  for (final group in azureSnapshot.groups) {
    final key = _norm(group.displayName);
    if (key == null) continue;
    final existing = byName[key];
    if (existing != null) {
      existing.azure ??= group;
    } else if (_looksLikeClassGroup(group.displayName)) {
      final rec = _GroupRecord(azure: group);
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
        azure: rec.azure,
        confidence:
            rec.wisa != null && rec.smartschool != null && rec.azure != null
                ? LinkConfidence.high
                : LinkConfidence.medium,
      ),
  ];
}

/// Azure AD group-name suffixes that mark a *staff*/administrative group
/// rather than a class — ported from the literal names legacy
/// `AddToAzureStaffGroup`/`AddToStaffGroup` look up via `FindGroupByName`
/// (`{prefix}-Personeel`, `-Directie`, `-Secretariaat`, `-Leraren`). Checked
/// as a case-insensitive suffix so it applies regardless of the school's
/// actual prefix.
///
/// This is a denylist, not an allowlist, because [az.AzureGroup] carries no
/// positive class-group signal: `securityEnabled` doesn't split the
/// populations either — legacy creates both a security-group and a plain
/// variant of `{prefix}-Personeel` for the same staff population.
const List<String> _nonClassGroupSuffixes = [
  '-personeel',
  '-directie',
  '-secretariaat',
  '-leraren',
];

/// Whether an unmatched Azure group is plausible as a stale class rather than
/// a known staff/administrative group. See [_nonClassGroupSuffixes].
bool _looksLikeClassGroup(String? displayName) {
  final name = _norm(displayName);
  if (name == null) return false;
  return !_nonClassGroupSuffixes.any(name.endsWith);
}

/// Projects a [wapi.WisaClassGroup] to the canonical [Group] that
/// [LinkedGroup.wisa] expects. The group is identified and named by its
/// `fullName` (the cross-system match key); WISA class groups are always real
/// classes, hence `official: true` and [GroupType.classGroup]. `schoolCode`
/// becomes the institute number; WISA exposes no tree edge or numeric admin
/// number for a class group, so [Group.parentId] and [Group.adminNumber] stay
/// null.
Group _wisaToCoreGroup(wapi.WisaClassGroup g) => Group(
      id: GroupId(g.fullName),
      name: g.fullName,
      description: g.description,
      type: GroupType.classGroup,
      official: true,
      instituteNumber: g.schoolCode.isEmpty ? null : g.schoolCode,
      origin: Origin.wisa,
    );

/// Mutable accumulator for one linked person while the passes run; frozen into
/// an immutable [LinkedAccount] at the end.
class _Record {
  ss.SmartschoolAccount? smartschool;
  wapi.WisaStudent? wisa;
  az.AzureUser? azure;

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

  _GroupRecord({this.wisa, this.smartschool, this.azure});
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
String? _norm(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed.toLowerCase();
}

/// Whether an Azure user's [companyName] marks it as one of the school's own
/// (a current or former student). Trimmed + case-insensitive.
bool _matchesPrefix(String? companyName, String schoolPrefix) {
  final company = _norm(companyName);
  final prefix = _norm(schoolPrefix);
  return company != null && prefix != null && company == prefix;
}

/// Whether an Azure user's [department] marks it as one of the school's own
/// staff (a current or former staff member). Per INV-22 the staff signal is a
/// *substring* match (`department` contains the prefix), unlike the student
/// signal which is an exact `companyName` equality. Trimmed + case-insensitive.
bool _departmentMatchesPrefix(String? department, String schoolPrefix) {
  final dept = _norm(department);
  final prefix = _norm(schoolPrefix);
  return dept != null && prefix != null && dept.contains(prefix);
}

/// The natural key handed to the [PersonIdResolver]: `wisaId → mail → upn →
/// azureId`, normalized and namespaced so the resolver mints a stable, derived
/// [PersonId]. The wisaId is taken from whichever system carries it.
String _naturalKey(_Record rec) {
  final wisaId = _norm(
    rec.wisa?.wisaId.value ??
        rec.smartschool?.accountId ??
        rec.azure?.employeeId,
  );
  if (wisaId != null) return 'wisa:$wisaId';

  final mail = _norm(rec.smartschool?.mail);
  if (mail != null) return 'mail:$mail';

  final upn = _norm(rec.azure?.upn);
  if (upn != null) return 'upn:$upn';

  final azureId = _norm(rec.azure?.id);
  if (azureId != null) return 'azure:$azureId';

  // Unreachable: every record carries at least one identifying field.
  throw StateError('LinkedAccount record has no identifying key: $rec');
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

/// The natural key for a staff member: `wisaId → code → mail → upn → azureId`,
/// normalized and namespaced under `staff:` so a staff member never collides
/// with a student who happens to share a numeric id. `wisaId` (the Azure
/// bridge) is preferred, then the Smartschool-side `code`.
String _naturalStaffKey(_StaffRecord rec) {
  final wisaId = _norm(rec.wisa?.wisaId?.value ?? rec.azure?.employeeId);
  if (wisaId != null) return 'staff:wisa:$wisaId';

  final code = _norm(rec.wisa?.code.value ?? rec.smartschool?.accountId);
  if (code != null) return 'staff:code:$code';

  final mail = _norm(rec.smartschool?.mail);
  if (mail != null) return 'staff:mail:$mail';

  final upn = _norm(rec.azure?.upn);
  if (upn != null) return 'staff:upn:$upn';

  final azureId = _norm(rec.azure?.id);
  if (azureId != null) return 'staff:azure:$azureId';

  // Unreachable: every record carries at least one identifying field.
  throw StateError('LinkedStaff record has no identifying key: $rec');
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
