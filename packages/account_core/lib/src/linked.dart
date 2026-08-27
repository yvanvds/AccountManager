import 'enums.dart';
import 'group.dart';
import 'ids.dart';
import 'source_records.dart';

/// How confident the linker is that a [LinkedAccount] is correct.
///
/// Spec `docs/domain-model.md` §3.9. Replaces the implicit "alumni" /
/// "placeholder" states that legacy encodes by which fields happen to be
/// null.
enum LinkConfidence {
  /// All linking keys agreed (e.g. `upn == mail` AND `employeeId == wisaId`).
  high,

  /// Some signal is missing or weak — typically an Azure-only record for a
  /// person who has left the school (the action engine raises a remove
  /// action for these) or a WISA-only placeholder for a student who hasn't
  /// been provisioned in Smartschool yet.
  medium,
  ;

  String toJson() => name;
  static LinkConfidence fromJson(String s) => values.byName(s);
}

/// Where a linked student sits in the *aggregated* WISA snapshot relative to
/// the schools we actually manage (#113/#134).
///
/// The shared credentials pull **every** WISA school the group can see, so a
/// student's [LinkedAccount.wisa] being non-null only means they are somewhere
/// in the group — not necessarily in one of our schools. This enum makes the
/// distinction the departure actions turn on:
///
/// - [ours]: present in WISA in at least one school we manage — the normal
///   "still here" case. Also the backward-compatible default when no school is
///   flagged as ours (ownership unconfigured ⇒ every WISA-present student is
///   treated as ours), so a group that hasn't adopted the aggregated pull keeps
///   its pre-#134 behaviour.
/// - [groupOnly]: present in the aggregated snapshot but only in sibling group
///   schools we do **not** manage. The student left *our* school yet is still in
///   the group — remove them from *our* Smartschool but **keep** Azure.
/// - [absent]: no WISA record at all — gone from the whole group. Remove from
///   Smartschool *and* Azure (the "incomplete Azure-only record flagged for
///   deletion", per the no-alumni rule).
enum WisaPresence {
  ours,
  groupOnly,
  absent,
  ;

  String toJson() => name;
  static WisaPresence fromJson(String s) => values.byName(s);
}

/// Output of the linker: one record per identified person.
///
/// Any of [wisa], [smartschool], [azure] may be null; when all three are
/// present the linker has unified the systems' views of this person. When
/// one is missing, the action engine raises the matching add/remove action.
class LinkedAccount {
  final LinkedAccountId id;
  final PersonRole role;
  final WisaStudent? wisa;
  final SmartschoolAccount? smartschool;
  final AzureUser? azure;
  final LinkConfidence confidence;

  /// Every WISA school this person was found in, mapped to the class group that
  /// school's row holds them in — the raw per-school membership the linker joins
  /// against the managed-school set (#133). Empty when [wisa] is null; a single
  /// entry in the common case, more only for a person enrolled across group
  /// schools. Retained on the record so the ours-vs-group distinction is
  /// auditable, not just its derived [wisaPresence].
  ///
  /// **A sibling school's entry is presence and nothing else** (INV-25). It
  /// answers "is this person still somewhere in the group?", which gates
  /// deletion (#134), and it is context a view may *state* — "ook ingeschreven
  /// in …" (#334). Every value we write into our own systems comes from [wisa],
  /// the row of a school we manage: reading a class out of here instead is
  /// exactly the bug of #318 and #332.
  final Map<int, String> wisaClassGroups;

  /// The WISA school ids this student's record was found in — the keys of
  /// [wisaClassGroups], which is the one place the membership is stored so the
  /// ids and the classes behind them can never disagree.
  Set<int> get wisaSchoolIds => wisaClassGroups.keys.toSet();

  /// Where this student sits relative to the schools we manage — the signal the
  /// departure actions turn on (#134). Defaults to [WisaPresence.ours]; the
  /// convenience getters below always fold in [wisa] nullness, so a hand-built
  /// record left on the default but carrying no WISA record still reads as
  /// having left.
  final WisaPresence wisaPresence;

  /// The **other** Azure accounts carrying this person's `employeeId` — the ones
  /// the link could not adopt because [azure] holds one already (INV-26, #360).
  ///
  /// Empty for every ordinary record. Non-empty means this person's Office 365
  /// identity is *ambiguous*, which is a third thing beside "linked" and
  /// "missing": [azure] is not wrong, it is merely the one the join happened to
  /// reach first, and the operator has to decide which account is the live one.
  ///
  /// See [DuplicateAzureEmployeeId] for why the extras are kept here rather than
  /// dropped or turned into orphan records.
  final List<AzureUser> azureDuplicates;

  const LinkedAccount({
    required this.id,
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
    this.wisaClassGroups = const <int, String>{},
    this.wisaPresence = WisaPresence.ours,
    this.azureDuplicates = const <AzureUser>[],
  });

  /// Whether more than one Azure account claims this person (INV-26, #360) — the
  /// condition that makes [azure] a *pick* rather than a link, and the one thing
  /// no automatic repair may act on.
  bool get hasAmbiguousAzureIdentity => azureDuplicates.isNotEmpty;

  /// Every Azure account claiming this person, the adopted one first — what a
  /// view lists when it asks the operator to choose. A single entry (or none) in
  /// the ordinary case.
  List<AzureUser> get azureCandidates => <AzureUser>[
        if (azure != null) azure!,
        ...azureDuplicates,
      ];

  /// Whether this student is present in WISA in a school we manage. False when
  /// absent from WISA entirely or present only in sibling group schools.
  bool get isInOurWisa => wisa != null && wisaPresence == WisaPresence.ours;

  /// Whether this student has left the schools we manage — moved to a sibling
  /// group school, or gone from the group entirely. Drives the Smartschool
  /// departure actions (unregister / delete).
  bool get hasLeftOurSchool => !isInOurWisa;

  /// Whether this student is gone from the **entire** group — absent from the
  /// aggregated WISA snapshot. Drives the delete-both vs keep-Azure split: only
  /// a group-departure removes the Azure account. A student still present in a
  /// sibling group school ([WisaPresence.groupOnly]) keeps a non-null [wisa],
  /// so this is false and their Azure removal is suppressed.
  bool get hasLeftGroup => wisa == null;
}

/// Output of the linker: one record per identified staff member.
///
/// Distinguished from [LinkedAccount] because staff use [WisaStaff] (with
/// its [WisaStaffCode]) instead of [WisaStudent].
class LinkedStaff {
  final LinkedAccountId id;
  final PersonRole role;
  final WisaStaff? wisa;
  final SmartschoolAccount? smartschool;
  final AzureUser? azure;
  final LinkConfidence confidence;

  /// Every WISA school this staff member's rows were found in (#340) — the staff
  /// analogue of [LinkedAccount.wisaSchoolIds], kept on the record so the
  /// ours-vs-group classification below is auditable rather than only derived.
  ///
  /// Empty when [wisa] is null, and also for a WISA row that carries no school —
  /// a snapshot written before #340, or a hand-built record. "No school" is read
  /// as *unknown*, never as *not ours*: see [wisaPresence].
  final Set<int> wisaSchoolIds;

  /// Where this staff member sits relative to the schools we manage — the staff
  /// analogue of [LinkedAccount.wisaPresence] (#340).
  ///
  /// The shared WISA credentials walk **every** school of the group, so
  /// [wisa] being non-null only means the person is employed somewhere in the
  /// group. That is exactly the fact the removal actions turn on and must keep
  /// turning on — a teacher who left us for a sibling school still has
  /// `wisa != null`, which is the only reason `RemoveStaffFromAzure` and
  /// `RemoveStaffFromSmartschool` never fire on them. This says the *other*
  /// thing: whether any of those schools is one of ours, which is what the
  /// Personeel view lists by.
  ///
  /// Defaults to [WisaPresence.ours] so a record built without it — and one
  /// whose WISA row predates [WisaStaff.schoolIds] — reads exactly as it did
  /// before #340.
  final WisaPresence wisaPresence;

  /// Whether Azure's `department` names our school for this record — INV-22's
  /// staff half, evaluated by the linker because [azure] here is the narrow
  /// [AzureUser] interface, which carries no `department` (#340).
  ///
  /// The **weaker** of the two ownership signals and the fallback for the case
  /// WISA cannot answer: `department` is a comma-separated list of school
  /// prefixes that *other* software maintains (#237), so it is neither ours to
  /// write nor guaranteed current. It is read only to keep a record — never to
  /// drop one.
  ///
  /// Defaults to `false`; on its own it never hides anybody, because
  /// [belongsToOurSchool] treats an unknown school as ours.
  final bool azureNamesOurSchool;

  /// The other Azure accounts carrying this person's `employeeId` — the staff
  /// twin of [LinkedAccount.azureDuplicates] (INV-26, #360).
  final List<AzureUser> azureDuplicates;

  const LinkedStaff({
    required this.id,
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
    this.wisaSchoolIds = const <int>{},
    this.wisaPresence = WisaPresence.ours,
    this.azureNamesOurSchool = false,
    this.azureDuplicates = const <AzureUser>[],
  });

  /// Whether more than one Azure account claims this staff member (INV-26,
  /// #360). See [LinkedAccount.hasAmbiguousAzureIdentity].
  bool get hasAmbiguousAzureIdentity => azureDuplicates.isNotEmpty;

  /// Every Azure account claiming this staff member, the adopted one first.
  List<AzureUser> get azureCandidates => <AzureUser>[
        if (azure != null) azure!,
        ...azureDuplicates,
      ];

  /// Whether this staff member is present in WISA in a school we manage. False
  /// when absent from WISA entirely or listed only by sibling group schools.
  bool get isInOurWisa => wisa != null && wisaPresence == WisaPresence.ours;

  /// Whether this staff member has left the schools we manage — moved to a
  /// sibling group school, or gone from the group entirely.
  bool get hasLeftOurSchool => !isInOurWisa;

  /// Whether this staff member is gone from the **entire** group. The staff twin
  /// of [LinkedAccount.hasLeftGroup], and the condition the Azure removal turns
  /// on: someone still employed elsewhere in the group keeps a non-null [wisa],
  /// so this is false and their Office 365 account is left alone.
  bool get hasLeftGroup => wisa == null;

  /// Whether this record is one of **our own school's** people — the question
  /// the Personeel view filters on (#340), answered from the strongest signal
  /// available.
  ///
  /// Three ways to be ours, and the order is the order of trust:
  /// - WISA lists them in a school we manage ([isInOurWisa]) — including the
  ///   "school unknown" fallback, so nothing written before #340 is hidden;
  /// - they hold an account on **our** Smartschool platform, which serves this
  ///   school alone, so its say-so is as good as WISA's;
  /// - Azure's `department` names us ([azureNamesOurSchool]) — third-party
  ///   maintained and consulted last, and never able to *override* the two
  ///   above, only to answer where they say nothing in our favour. It has to be
  ///   asked at all because the Azure pull's `employeeId` back-fill (#231) is
  ///   fed from the group-wide WISA staff list, so an Azure row on a staff
  ///   record proves nothing about whose account it is — unlike the student
  ///   side, whose back-fill is already scoped to the schools we manage. And it
  ///   is the *only* thing left to ask about a former staff member WISA no
  ///   longer lists at all, whose Office 365 account is precisely what
  ///   `RemoveStaffFromAzure` exists to clean up.
  ///
  /// False only for a record WISA places exclusively in sibling group schools
  /// with no tie of ours anywhere — a colleague at another school of the group,
  /// who is none of our business to list and none of our business to delete.
  /// Note which way the doubt falls: every unknown reads as ours, so the filter
  /// can only ever hide someone no system of ours claims at all.
  bool get belongsToOurSchool =>
      isInOurWisa || smartschool != null || azureNamesOurSchool;
}

/// Output of the linker: one record per identified group.
///
/// [wisa] is nullable (#52): a group that vanished from WISA but still exists
/// in Smartschool and/or Azure is kept as an orphan record — symmetric with
/// how an Azure-only [LinkedAccount] is kept for a former student — so the
/// action engine can raise a delete action for it instead of it silently
/// disappearing. At least one of [wisa], [smartschool], [azure] is always
/// present.
class LinkedGroup {
  final Group? wisa;
  final Group? smartschool;
  final AzureGroup? azure;
  final LinkConfidence confidence;

  /// A Smartschool group that already carries this class's name but which the
  /// group link could **not** adopt as [smartschool] (#225) — set only when
  /// [smartschool] is null and [wisa] is not.
  ///
  /// Two shapes reach here, and the difference is visible on the record itself
  /// ([Group.official], [Group.name]):
  /// - the namesake is not flagged as an official class, so the link skipped
  ///   it (a class Smartschool holds as an organisational group);
  /// - the namesake *is* an official class but its name differs from the WISA
  ///   one by more than the match key tolerates (`2 G` vs `2G`).
  ///
  /// Either way the class exists downstream in some form, so proposing to
  /// create it would ask Smartschool for a duplicate name — it either rejects
  /// the write or ends up with two classes. The action engine raises an
  /// explicit notice on this field instead of a create.
  final Group? smartschoolNamesake;

  /// The **bare** class name behind this record — `2F` for the sub-grouped
  /// class `2F ECO`, and simply the class name for a class without sub-groups
  /// (#228).
  ///
  /// [wisa] is keyed and named by the WISA `fullName` (the cross-system match
  /// key), which is what Smartschool spells a class by. The Office 365 group is
  /// named after the *parent* class instead — sub-groups get no group of their
  /// own — so without this the bare name is gone by the time an action sees the
  /// record. Carrying it here keeps the linker the single place that knows how a
  /// WISA class projects, rather than teaching every consumer to re-derive it.
  ///
  /// For an Azure-only orphan it is the name recovered from the group's
  /// `<PREFIX>-` display name ([azureClassNameOf]); `null` for a record with
  /// neither — a Smartschool-only orphan carries no WISA class to name.
  final String? className;

  const LinkedGroup({
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
    this.smartschoolNamesake,
    this.className,
  });
}

/// A non-fatal anomaly the linker surfaces for operator attention.
///
/// Collected into [LinkedSnapshot.warnings]. Sealed so the action engine
/// can dispatch exhaustively over the concrete variants.
sealed class LinkWarning {
  const LinkWarning();
}

/// INV-23: two or more Smartschool accounts claim the same [mail].
///
/// The legacy linker silently kept the first and dropped the rest (PAIN-7).
/// We retain every colliding account in the [LinkedSnapshot] and raise this
/// warning so the operator can resolve the collision (typically a stray
/// co-account; see INV-13).
class ResolveDuplicateMail extends LinkWarning {
  /// The address the colliding accounts share. Compared case-insensitively
  /// and trimmed per INV-12.
  final String mail;

  /// Every Smartschool account that claims [mail]; at least two.
  final List<SmartschoolAccount> accounts;

  const ResolveDuplicateMail({required this.mail, required this.accounts});
}

/// INV-26: two or more Azure accounts carry the same non-empty `employeeId`.
///
/// **`employeeId` is not unique in this tenant.** It holds the WISA id, so the
/// linker treats it as the strong bridge to a person — but the tenant contains
/// pairs of accounts that answer to one id, audited live in Aug 2026 (#360):
/// nine enrolled students of one school held two accounts each, the two UPNs
/// differing only in how the given name was normalised, created months apart by
/// two different runs of this app. They are the fingerprint of a
/// UPN-normalisation change, not of manual error, so more of them can appear.
///
/// A join keyed one-account-per-id therefore *picks* rather than links, and
/// before this warning existed the account it did not pick had two silent fates:
/// dropped outright, or — when it carried our `companyName` — kept as an
/// Azure-only orphan, which reads as a departed student and draws a proposal to
/// **delete** it. Both are wrong in the same way: the abandoned twin and the
/// twin holding the student's mail and OneDrive are indistinguishable to the
/// join, so acting on either is a coin flip.
///
/// So the collision is reported as what it is. Every colliding account is kept
/// and reachable — the adopted one on [LinkedAccount.azure], the rest on
/// [LinkedAccount.azureDuplicates] — and none of them becomes an orphan record,
/// which is what stops the delete proposal. **Resolution is the operator's**
/// (#360): merging is destructive, and the wrong choice deletes the mailbox.
class DuplicateAzureEmployeeId extends LinkWarning {
  /// The `employeeId` the colliding accounts share, normalized per INV-12
  /// (trimmed, lower-cased) — the same form the linker joins on.
  final String employeeId;

  /// Every Azure account carrying [employeeId], in snapshot order; at least two.
  ///
  /// Typed as the narrow [AzureUser], so a view that wants the facts an operator
  /// needs to choose between them — is it enabled, does it carry the
  /// `companyName`/`jobTitle` pair the licence group's rule requires — narrows to
  /// the connector's own record, exactly as the materializer does for a staff
  /// `department`.
  final List<AzureUser> accounts;

  const DuplicateAzureEmployeeId({
    required this.employeeId,
    required this.accounts,
  });
}

/// What the linker did about an [AzureAccountClaimedTwice] collision (#386).
///
/// The rule is claim *strength*, not population: a record with a WISA row or a
/// Smartschool account behind it outranks one that exists only because an Azure
/// user carried a school stamp. Between two records that both exist only for
/// that reason, staff wins — deleting a teacher's Office 365 account is
/// unrecoverable, leaving a departed pupil's account standing one more pass is
/// not.
enum AzureClaimResolution {
  /// The Azure-only **student** record was dropped; the staff record keeps the
  /// account. The reported case of #386: a teacher stamped with the student
  /// `companyName`.
  keptAsStaff,

  /// The Azure-only **staff** record was dropped; the student record keeps the
  /// account — the mirror case, a pupil whose `department` names the school.
  keptAsStudent,

  /// Nothing was dropped: both claimants carry a WISA/Smartschool anchor of
  /// their own, so neither is a record the linker manufactured and dropping
  /// either would lose something real. Reported and left to the operator.
  unresolved,
}

/// INV-27: one Azure object id reached **two** linked records — a
/// [LinkedAccount] and a [LinkedStaff] (#386).
///
/// The linker runs its student and its staff pass over the same Azure user
/// list, and INV-22's two halves ask different questions of one account:
/// `companyName` names the school for a *student*, `department` for a *staff*
/// member. Nothing in the tenant makes the two mutually exclusive —
/// `companyName` says which school an account belongs to, never what its holder
/// is (#358) — so a teacher whose account carries both stamps used to become a
/// [LinkedStaff] *and* an Azure-only [LinkedAccount], and the second reading
/// drew `RemoveStudentFromAzure`: a proposal to delete the Office 365 account of
/// somebody the same snapshot lists as staff.
///
/// So the collision is resolved (see [AzureClaimResolution]) and reported rather
/// than left to whichever consumer looks first. It stays a warning even when the
/// linker could resolve it: an account both populations claim is a stamp somebody
/// has to fix in Entra, and the app's own reading of it is a guess either way.
class AzureAccountClaimedTwice extends LinkWarning {
  /// The Office 365 account both populations claimed.
  final AzureUser account;

  /// Which record was left holding [account].
  final AzureClaimResolution resolution;

  const AzureAccountClaimedTwice({
    required this.account,
    required this.resolution,
  });
}

/// #225: a WISA class whose name already exists in Smartschool as a group the
/// class link did not adopt — because the group is not flagged as an official
/// class, or because its name differs from the WISA one by more than the match
/// key tolerates.
///
/// The skip itself is legitimate (only official classes link), but it used to
/// be **silent**: the WISA class then looked unmatched, and the action engine
/// offered to create a class Smartschool already had. Every skipped namesake is
/// surfaced so the operator can see which class was passed over and why.
class SmartschoolNamesakeSkipped extends LinkWarning {
  /// The WISA class name as written (its `fullName`, the match key's source).
  final String wisaName;

  /// The Smartschool group carrying that name. [Group.official] says which of
  /// the two skip reasons applies; [Group.name] shows the name as Smartschool
  /// spells it.
  final Group smartschool;

  const SmartschoolNamesakeSkipped({
    required this.wisaName,
    required this.smartschool,
  });
}

/// What one of the records behind a [DuplicateLinkedId] holds — enough of each
/// colliding record for an operator (or a log line) to tell them apart.
///
/// Deliberately flattened to the per-system keys rather than carrying the
/// records themselves: a collision can be between two [LinkedAccount]s, two
/// [LinkedStaff], or one of each, and a single shape lets every consumer render
/// all three the same way.
class LinkedIdHolding {
  /// The role the colliding record was minted with.
  final PersonRole role;

  /// The WISA key — a student's `wisaId` or a staff member's `code`. Null when
  /// the record has no WISA side.
  final String? wisa;

  /// The Smartschool `uid`, or null when the record has no Smartschool side.
  final String? smartschool;

  /// The Azure object id, or null when the record has no Azure side.
  final String? azure;

  const LinkedIdHolding({
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
  });

  /// The holding of a colliding student record.
  factory LinkedIdHolding.ofAccount(LinkedAccount a) => LinkedIdHolding(
        role: a.role,
        wisa: a.wisa?.wisaId.value,
        smartschool: a.smartschool?.uid,
        azure: a.azure?.id,
      );

  /// The holding of a colliding staff record.
  factory LinkedIdHolding.ofStaff(LinkedStaff s) => LinkedIdHolding(
        role: s.role,
        wisa: s.wisa?.code.value,
        smartschool: s.smartschool?.uid,
        azure: s.azure?.id,
      );
}

/// INV-24: two or more linker records resolved to the same [LinkedAccountId].
///
/// Every layer below the linker is keyed by that id and each one degrades
/// differently and silently — the materializer hands both records the *union*
/// of their candidate actions, the Acties list keeps whichever pending entry
/// arrived last, and the shared store holds one document per id, so one record
/// is what every other operator inherits. The first sign of trouble used to be
/// an operator reading a card whose presence chips come from one record and
/// whose actions come from another (#319).
///
/// So a collision is reported as what it is — a linker invariant violation —
/// rather than merged away by each consumer's own assumption. Both records are
/// kept in the [LinkedSnapshot]: dropping one silently is the very failure
/// INV-23 exists to prevent. The tally counts the id once ([LinkCounts]), so
/// the dashboard's linked/total ratio does not drift while the collision lasts.
class DuplicateLinkedId extends LinkWarning {
  /// The id the colliding records share.
  final LinkedAccountId id;

  /// What each record claiming [id] holds; at least two, in snapshot order
  /// (students before staff).
  final List<LinkedIdHolding> holdings;

  const DuplicateLinkedId({required this.id, required this.holdings});
}

/// Per-system tally for one [LinkedSnapshot], mirroring the counters legacy
/// `LinkedAccounts.DoRelink` exposed.
///
/// A record counts toward [linked] when it is present in *every* system, and
/// toward [unlinked] when it is present in this system but missing from at
/// least one other. [total] == [linked] + [unlinked].
///
/// The unit is a **person**, not a record: [LinkedSnapshot.fromRecords] counts
/// each [LinkedAccountId] once, so a colliding id (INV-24, #319) cannot inflate
/// a system's total or skew the dashboard's linked/total ratio for as long as
/// the collision lasts.
class LinkCounts {
  final int total;
  final int linked;
  final int unlinked;

  const LinkCounts({
    required this.total,
    required this.linked,
    required this.unlinked,
  });

  static const empty = LinkCounts(total: 0, linked: 0, unlinked: 0);
}

/// The complete output of one `link(wisa, smartschool, azure)` run.
///
/// Spec §6.2. Holds the reconciled [accounts], [staff], and [groups], the
/// per-system [LinkCounts], and any [warnings] raised while linking
/// (e.g. [ResolveDuplicateMail]). Pure data — produced by the linker (#43)
/// and consumed by the action engine (#46).
class LinkedSnapshot {
  final List<LinkedAccount> accounts;
  final List<LinkedStaff> staff;
  final List<LinkedGroup> groups;

  /// Account/staff tallies for WISA, Smartschool, and Azure respectively.
  final LinkCounts wisa;
  final LinkCounts smartschool;
  final LinkCounts azure;

  final List<LinkWarning> warnings;

  const LinkedSnapshot({
    required this.accounts,
    required this.staff,
    required this.groups,
    required this.wisa,
    required this.smartschool,
    required this.azure,
    this.warnings = const [],
  });

  /// Builds a snapshot and derives the per-system [LinkCounts] from the
  /// [accounts] and [staff] records, replicating legacy
  /// `LinkedAccounts.DoRelink`: a person counts toward a system's [total]
  /// when present there, and toward that system's [linked] only when present
  /// in all three systems. Groups are listed but not counted.
  ///
  /// This is also where [LinkedAccountId] uniqueness (INV-24) is enforced, so
  /// the invariant lives with the type rather than in each consumer's
  /// assumptions (#319). Every record — student or staff — is bucketed by its
  /// id, and any id claimed more than once yields one [DuplicateLinkedId]
  /// warning appended to [warnings], in first-seen order.
  ///
  /// The colliding records are **kept**, never deduped away: a silent drop is
  /// what INV-23 exists to prevent, and one of the two is generally the record
  /// carrying the actions an operator is about to apply. What changes is that
  /// the collision is now loud, and that the tally below counts each id once —
  /// counting per record inflated a system's [total] by one per collision and
  /// skewed the dashboard's linked/total ratio.
  factory LinkedSnapshot.fromRecords({
    required List<LinkedAccount> accounts,
    required List<LinkedStaff> staff,
    required List<LinkedGroup> groups,
    List<LinkWarning> warnings = const [],
  }) {
    var wisaTotal = 0, wisaLinked = 0;
    var ssTotal = 0, ssLinked = 0;
    var azTotal = 0, azLinked = 0;

    // INV-24 bookkeeping: what each id is claimed by, in first-seen order so
    // the warnings a given input produces are deterministic (INV-20).
    final holdingsById = <String, List<LinkedIdHolding>>{};
    final idOrder = <String>[];
    final idByValue = <String, LinkedAccountId>{};

    void tally({
      required bool inWisa,
      required bool inSmartschool,
      required bool inAzure,
    }) {
      final complete = inWisa && inSmartschool && inAzure;
      if (inWisa) {
        wisaTotal++;
        if (complete) wisaLinked++;
      }
      if (inSmartschool) {
        ssTotal++;
        if (complete) ssLinked++;
      }
      if (inAzure) {
        azTotal++;
        if (complete) azLinked++;
      }
    }

    /// Registers a record's claim on [id] and reports whether it is the first —
    /// the only claim that counts toward the tally, since the unit is a person.
    bool claim(LinkedAccountId id, LinkedIdHolding holding) {
      final key = id.value;
      final existing = holdingsById[key];
      if (existing == null) {
        idOrder.add(key);
        idByValue[key] = id;
        holdingsById[key] = <LinkedIdHolding>[holding];
        return true;
      }
      existing.add(holding);
      return false;
    }

    for (final a in accounts) {
      if (!claim(a.id, LinkedIdHolding.ofAccount(a))) continue;
      tally(
        inWisa: a.wisa != null,
        inSmartschool: a.smartschool != null,
        inAzure: a.azure != null,
      );
    }
    for (final s in staff) {
      if (!claim(s.id, LinkedIdHolding.ofStaff(s))) continue;
      tally(
        inWisa: s.wisa != null,
        inSmartschool: s.smartschool != null,
        inAzure: s.azure != null,
      );
    }

    final collisions = <DuplicateLinkedId>[
      for (final key in idOrder)
        if (holdingsById[key]!.length > 1)
          DuplicateLinkedId(
            id: idByValue[key]!,
            holdings: List<LinkedIdHolding>.unmodifiable(holdingsById[key]!),
          ),
    ];

    LinkCounts counts(int total, int linked) =>
        LinkCounts(total: total, linked: linked, unlinked: total - linked);

    return LinkedSnapshot(
      accounts: accounts,
      staff: staff,
      groups: groups,
      // A fresh list rather than an append: `warnings` is the caller's own
      // accumulator (and may be `const []`).
      warnings: collisions.isEmpty
          ? warnings
          : <LinkWarning>[...warnings, ...collisions],
      wisa: counts(wisaTotal, wisaLinked),
      smartschool: counts(ssTotal, ssLinked),
      azure: counts(azTotal, azLinked),
    );
  }
}
