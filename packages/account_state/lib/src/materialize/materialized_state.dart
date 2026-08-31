/// The materialized, **persisted** form of the linked reconcile view (#115,
/// keystone of #112).
///
/// Where `LinkedState` is the transient in-RAM output of one `link()` +
/// dispatch pass, these types are the shared, versioned documents the sync
/// process writes to the store and a passive session reads back **without
/// pulling or re-linking**. `materialize()` turns a `LinkedState` into a
/// [MaterializedView]; the `LinkedStore` persists it as one document per
/// [MaterializedAccount] (partitioned by school) plus the [Rollup] aggregates
/// that drive the drill-down.
///
/// Everything here is pure JSON-round-tripping data — no I/O, no Flutter — so
/// the model is unit-testable and reused unchanged by the in-memory fake and
/// the Cosmos-backed store.
library;

import 'package:account_actions/account_actions.dart'
    show Alternatives, FieldChange, FieldChangeShape, collapseAlternatives;
import 'package:account_core/account_core.dart' as core;

/// One dispatched action, flattened for storage and display.
///
/// The persisted counterpart of a live `StudentAction` / `StaffAction` /
/// `GroupAction`: it carries only the pure description the UI renders
/// ([summary] + field [fields]) plus a stable [kind] discriminator (the action
/// class name) so a persisted decision can be re-attached to the same situation
/// on the next sync (see [AccountDecision.targetKind]).
class CandidateAction {
  const CandidateAction({
    required this.family,
    required this.kind,
    required this.system,
    required this.summary,
    this.fields = const [],
    this.canApply = true,
    this.alternativeGroup,
    this.isDefaultAlternative = false,
    this.noticeFor,
  });

  /// `student`, `staff`, or `group` — the dispatcher family.
  final String family;

  /// The action's class name (e.g. `MoveToSmartschoolClassGroup`). Stable
  /// across syncs, so it keys the "same situation" a decision resolves.
  final String kind;

  /// The system the change targets.
  final core.Origin system;

  /// Short, human-facing summary (Dutch), copied from the action's [ChangeSet].
  final String summary;

  /// The field-level diff. Empty for pure lifecycle actions.
  final List<FieldChange> fields;

  /// False for informational actions with no automated write (they inform the
  /// operator but the apply pass skips them).
  final bool canApply;

  /// The key shared by the mutually-exclusive alternatives that resolve the
  /// **same situation** (#110), copied off the live action's
  /// `alternativeGroup`; `null` when the action stands on its own.
  ///
  /// Persisted since #251, because a passive session has nothing else to tell an
  /// either/or from two independent to-dos: without it the rollup badges counted
  /// both halves of one choice, and the read-only tiles listed both as separate
  /// bullets. Absent in documents written before #251, which read back as `null`
  /// — the pre-#110 shape, and correct for every candidate that has no
  /// alternative.
  final String? alternativeGroup;

  /// Whether this candidate is the pre-selected default of its
  /// [alternativeGroup] — the resolution an apply pass runs unless the operator
  /// switches. Ignored when [alternativeGroup] is `null`.
  final bool isDefaultAlternative;

  /// The situation this **informational** candidate is context for (#329),
  /// copied off the live action's `noticeFor`; `null` for every candidate that
  /// is a decision in its own right.
  ///
  /// Persisted for the reason [alternativeGroup] is (#251): a passive session
  /// has nothing else to tell a notice from a to-do, and without it the stored
  /// view would render the namesake and empty-class instructions as decisions
  /// the operator has to resolve — and count them in the badge — while a live
  /// session states them as context beside the one write there is. Absent in
  /// documents written before #329, which read back as `null` and behave exactly
  /// as they did.
  final String? noticeFor;

  Map<String, dynamic> toJson() => {
        'family': family,
        'kind': kind,
        'system': system.toJson(),
        'summary': summary,
        if (fields.isNotEmpty)
          'fields': [
            for (final f in fields)
              {
                'field': f.field,
                if (f.before != null) 'before': f.before,
                if (f.after != null) 'after': f.after,
                // Which of the three shapes this is (#300, #305). Read back as
                // a transition, a count renders as "∅ → 21" again and a
                // statement as "GBS-9Z@… → ∅" — so a passive session would show
                // the very thing the live one no longer does. Omitted for the
                // transition, which is what every field written before #300 is.
                if (f.shape != FieldChangeShape.transition)
                  'shape': f.shape.name,
              },
          ],
        'canApply': canApply,
        if (alternativeGroup != null) 'alternativeGroup': alternativeGroup,
        if (isDefaultAlternative) 'isDefaultAlternative': true,
        if (noticeFor != null) 'noticeFor': noticeFor,
      };

  factory CandidateAction.fromJson(Map<String, dynamic> json) =>
      CandidateAction(
        family: json['family'] as String,
        kind: json['kind'] as String,
        system: core.Origin.fromJson(json['system'] as String),
        summary: json['summary'] as String,
        fields: [
          for (final f in (json['fields'] as List? ?? const []))
            FieldChange(
              (f as Map<String, dynamic>)['field'] as String,
              before: f['before'] as String?,
              after: f['after'] as String?,
              shape: _fieldShape(f['shape'] as String?),
            ),
        ],
        canApply: json['canApply'] as bool? ?? true,
        alternativeGroup: json['alternativeGroup'] as String?,
        isDefaultAlternative: json['isDefaultAlternative'] as bool? ?? false,
        noticeFor: json['noticeFor'] as String?,
      );
}

/// The persisted [FieldChangeShape] of one stored field.
///
/// Absent in documents written before #300/#305 — and in every field that is a
/// plain transition, which is exactly what those documents hold — so an unknown
/// or missing name reads back as [FieldChangeShape.transition].
FieldChangeShape _fieldShape(String? name) =>
    FieldChangeShape.values.firstWhere(
      (FieldChangeShape s) => s.name == name,
      orElse: () => FieldChangeShape.transition,
    );

/// The decision points a candidate list represents (#251) — the persisted-view
/// counterpart of the reconcile controller's `PendingChoice`, built by the one
/// shared [collapseAlternatives] both layers use.
///
/// Candidates sharing a non-null [CandidateAction.alternativeGroup] collapse
/// into a single choice pre-selected on its declared default; every other
/// candidate is a choice of one. Exposed so the read-only tiles can render an
/// either/or as the one line it is instead of two independent bullets.
///
/// A candidate carrying [CandidateAction.noticeFor] is not a decision at all
/// (#329): it is lifted onto the choice it names as [Alternatives.notices], so
/// the stored view states the namesake and empty-class instructions as context
/// exactly where a live session does — and, just as importantly, does not count
/// them as work in [pendingDecisionCount].
List<Alternatives<CandidateAction>> candidateChoices(
  Iterable<CandidateAction> candidates,
) =>
    collapseAlternatives<CandidateAction>(
      candidates,
      groupOf: (c) => c.alternativeGroup,
      isDefault: (c) => c.isDefaultAlternative,
      noticeFor: (c) => c.noticeFor,
    );

/// How many pending **decisions** [candidates] leave for the operator — the
/// number behind every "N pending here" badge (#251).
///
/// Counts one per [candidateChoices] entry whose selected option is applyable,
/// which is exactly what an apply pass would write (the controller's
/// `applyableCount` resolves the same way over the live actions). So a departed
/// student's unregister/delete pair counts **once**, a new class's
/// create/opt-out pair counts once, an informational action that stands alone
/// (the #245 one, and the leftover notices of #327/#328) counts zero, and a
/// notice attached to a decision (#329) is not a choice here at all — the
/// decision it is context for is counted, on its own merits.
///
/// That last one is a deliberate change of reading. An empty or namesake class
/// counted **zero** while the notice was its pre-selected half; it counts one
/// now, because the blacklist beside it genuinely is a write this app can make
/// and the operator can press. The same shift #327/#328 made for the two
/// leftovers, for the same reason: the badge says what there is to do here, and
/// there is something.
int pendingDecisionCount(Iterable<CandidateAction> candidates) {
  var pending = 0;
  for (final choice in candidateChoices(candidates)) {
    if (choice.selected.canApply) pending++;
  }
  return pending;
}

/// The kind of operator intent an [AccountDecision] records.
///
/// Kept as separate documents from the derived per-account docs so a re-sync
/// (which rewrites the derived docs wholesale) never clobbers in-progress work.
/// The write UIs that create these live in #109 (accepted duplicates) and #110
/// (chosen alternative / applied status); this issue only defines the schema
/// and the re-attach/drop merge.
enum DecisionKind {
  /// The operator picked one of a set of mutually exclusive candidate actions
  /// (e.g. unregister vs delete for a departed student) — #110.
  chosenAlternative,

  /// The operator accepted a duplicate-mail collision as deliberate — #109.
  acceptedDuplicate,

  /// The operator marked a candidate applied out of band.
  appliedStatus,
  ;

  String toJson() => name;
  static DecisionKind fromJson(String s) => values.byName(s);
}

/// A persisted operator decision about one account **or class group**.
///
/// [targetKind] is the "situation" the decision resolves — the [kind] of the
/// [CandidateAction] it applies to, or a warning id for [acceptedDuplicate]. On
/// the next sync the merge keeps this decision only while its target still has
/// a matching situation (see [mergeDecisions]).
///
/// [accountId] is the stable key of the target the decision belongs to: a
/// [MaterializedAccount.id] for an account/staff decision, or a
/// [MaterializedGroup.id] for a group decision (#119). Both share this one
/// decisions container, so the merge considers accounts and groups together and
/// never drops a group decision just because it is not an account.
class AccountDecision {
  const AccountDecision({
    required this.accountId,
    required this.kind,
    required this.targetKind,
    this.payload = const {},
    required this.decidedBy,
    required this.decidedAt,
  });

  /// The stable key of the target (an account/staff id, or a group id) this
  /// decision belongs to.
  final core.LinkedAccountId accountId;
  final DecisionKind kind;

  /// The [CandidateAction.kind] (or warning id) this decision resolves. Matched
  /// against the freshly-computed candidates to decide whether the situation
  /// still exists.
  final String targetKind;

  /// Decision-specific detail (the chosen alternative's kind, the accepted
  /// duplicate's uids, …). Opaque to the merge; interpreted by #109/#110.
  final Map<String, dynamic> payload;

  final String decidedBy;
  final DateTime decidedAt;

  Map<String, dynamic> toJson() => {
        'accountId': accountId.toJson(),
        'kind': kind.toJson(),
        'targetKind': targetKind,
        if (payload.isNotEmpty) 'payload': payload,
        'decidedBy': decidedBy,
        'decidedAt': decidedAt.toIso8601String(),
      };

  factory AccountDecision.fromJson(Map<String, dynamic> json) =>
      AccountDecision(
        accountId: core.LinkedAccountId(json['accountId'] as String),
        kind: DecisionKind.fromJson(json['kind'] as String),
        targetKind: json['targetKind'] as String,
        payload: (json['payload'] as Map<String, dynamic>?) ?? const {},
        decidedBy: json['decidedBy'] as String,
        decidedAt: DateTime.parse(json['decidedAt'] as String),
      );
}

/// One **other** group school a person is enrolled in, beside the school whose
/// class facts the card is already showing (#334).
///
/// The rare, recurring case: at the start of a school year a student may apply
/// to several schools of the group, and which one she actually turns up in is
/// only known once term starts. Until then her record carries two WISA rows, and
/// the card that says nothing about the second one reads as an anomaly — a class
/// name from nowhere, a departure beside a create.
///
/// Context, never a value to write. [schoolLabel] is the WISA school list's own
/// name for the school (never invented from an id, #204/#208) and [classroom]
/// the class *that* school's row holds the person in — stated so the operator
/// can read the rest of the card, and consulted for nothing else (INV-25).
class OtherEnrolment {
  const OtherEnrolment({required this.schoolLabel, required this.classroom});

  /// How the school is named — `"<naam> (<code>)"` from `wisaSchoolLabels`.
  final String schoolLabel;

  /// The class that school's WISA row holds this person in; empty when its row
  /// names no class.
  final String classroom;

  Map<String, dynamic> toJson() => {
        'schoolLabel': schoolLabel,
        'classroom': classroom,
      };

  factory OtherEnrolment.fromJson(Map<String, dynamic> json) => OtherEnrolment(
        schoolLabel: json['schoolLabel'] as String? ?? '',
        classroom: json['classroom'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OtherEnrolment &&
          schoolLabel == other.schoolLabel &&
          classroom == other.classroom;

  @override
  int get hashCode => Object.hash(schoolLabel, classroom);

  @override
  String toString() =>
      'OtherEnrolment(schoolLabel: $schoolLabel, classroom: $classroom)';
}

/// One linked account (or staff member) as a stored document.
///
/// The atomic write/notify unit of the materialized view: partitioned by
/// [school], it records where the person sits (school / grade-year / classroom
/// for the drill-down), the per-system presence and [confidence] the linker
/// derived, any account-scoped [warnings], the computed [candidates], and the
/// still-applicable [decisions] re-attached by the last sync.
class MaterializedAccount {
  const MaterializedAccount({
    required this.id,
    required this.school,
    required this.schoolLabel,
    required this.gradeYear,
    required this.classroom,
    required this.role,
    required this.isStaff,
    required this.confidence,
    required this.label,
    required this.inWisa,
    required this.inSmartschool,
    required this.inAzure,
    this.wisaPresence = core.WisaPresence.ours,
    this.otherEnrolments = const [],
    this.departmentSchools = const [],
    this.azureCompanyName,
    this.warnings = const [],
    this.candidates = const [],
    this.decisions = const [],
  });

  /// The linker's stable id — the document id.
  final core.LinkedAccountId id;

  /// The partition key: the school bucket this account belongs to (a WISA
  /// school id for a student, or a synthetic `staff` / `unassigned` bucket).
  final String school;

  /// Human label for [school] (from the WISA schools list when known).
  final String schoolLabel;

  /// Grade-year bucket (e.g. `3`) for the drill-down, or a synthetic bucket.
  final String gradeYear;

  /// Classroom bucket (e.g. `3C`) for the drill-down, or a synthetic bucket.
  final String classroom;

  final core.PersonRole role;

  /// True for a staff member ([LinkedStaff]), false for a student
  /// ([LinkedAccount]).
  final bool isStaff;

  final core.LinkConfidence confidence;

  /// Display name for the person.
  final String label;

  final bool inWisa;
  final bool inSmartschool;
  final bool inAzure;

  /// Where the aggregated WISA snapshot puts this person relative to the schools
  /// we manage (#134/#340) — copied straight off `LinkedAccount.wisaPresence` /
  /// `LinkedStaff.wisaPresence`.
  ///
  /// [inWisa] cannot answer this and never could: the shared credentials walk
  /// **every** school of the group, so a WISA row proves the person is somewhere
  /// in the group and nothing more. A student who moved to a sibling school
  /// therefore has `inWisa: true` and [core.WisaPresence.groupOnly], while one
  /// gone from the group entirely has `inWisa: false` and
  /// [core.WisaPresence.absent] — two situations whose cleanup differs (keep
  /// Office 365 vs. delete it, per the no-alumni rule) and which the WISA cell
  /// reads apart since #392.
  ///
  /// Baked into the document for the same reason [otherEnrolments] is: the
  /// linked record behind it lives in the transient linked view, so a card that
  /// could only say it in the session that synced would say it to nobody
  /// (#214/#255).
  ///
  /// Defaults to [core.WisaPresence.ours] — the same default the linked records
  /// carry — so a document written before this existed reads exactly as it did.
  final core.WisaPresence wisaPresence;

  /// The **other** group schools this person is enrolled in — empty for the
  /// ordinary account, which is every account but a handful (#334).
  ///
  /// Baked into the document rather than derived on the card, because the WISA
  /// rows behind it live in the transient linked view: a passive session reads
  /// this store and never pulls, and a card that can only say it in the session
  /// that synced is a card that says it to nobody.
  final List<OtherEnrolment> otherEnrolments;

  /// The schools an Azure **staff** account's `department` lists — every entry,
  /// ours included, in the field's own order and casing (#352).
  ///
  /// The discriminator the two Office 365 departure actions split on, made
  /// legible: `ReleaseStaffFromAzureSchool` strikes our entry and keeps the
  /// account because another school still claims the person, while
  /// `RemoveStaffFromAzure` **deletes** it because nothing but our own prefix is
  /// left ([departmentSchoolsExcept] came back empty). An operator deciding a
  /// destructive, per-record "uit dienst" should be able to read the field the
  /// app decided on, and to sanity-check it first — `department` is maintained
  /// by other software and is not ours to write (#237), so this is stated and
  /// never repaired.
  ///
  /// Baked into the document for the same reason [otherEnrolments] is: the Azure
  /// record behind it lives in the transient linked view — and `LinkedStaff
  /// .azure` is the narrow `AzureUser` interface, which carries no `department`
  /// at all — so a card that could only say it in the session that synced would
  /// say it to nobody (#214/#255).
  ///
  /// Empty for a student (their school is `companyName`, one exact value, INV-22
  /// — there is no list), for a staff record with no Azure account, and for a
  /// document written before this existed.
  final List<String> departmentSchools;

  /// The school an Azure **student** account's `companyName` names — the field's
  /// own value, verbatim (#393).
  ///
  /// INV-22's other half, and the student counterpart of [departmentSchools]:
  /// where a staff account's schools are a list in `department`, a student's is
  /// one exact `companyName`. It is usually the fact that settles the choice
  /// between "uitschrijven" and "verwijderen" for a record with no WISA row —
  /// #392's blue WISA cell says the person is *elsewhere in the group*, and this
  /// says **which school** — so the pane states it instead of sending the
  /// operator to the portal.
  ///
  /// Never normalised: `afzwaai-SSJ` and `SSM-DIR` are real values from the Aug
  /// 2026 tenant audit (#389) and mean something to an operator that a
  /// cleaned-up rendering would destroy. This is a quotation, and — unlike
  /// `department` (#237) — a field this app *does* write, so the reading is also
  /// how an operator checks what a repair is about to change.
  ///
  /// Baked into the document for the same reason [departmentSchools] is:
  /// `LinkedAccount.azure` is the narrow [core.AzureUser] interface, which
  /// carries no `companyName` at all, and the record behind it lives in the
  /// transient linked view — so a card that could only say it in the session
  /// that synced would say it to nobody (#214/#255).
  ///
  /// `null` for an account with no Office 365 user, for one whose `companyName`
  /// is blank or absent — the common case, 140 of them in that same audit — for
  /// a staff record (whose school is `department`), and for a document written
  /// before this existed. The pane tells the first apart from the rest by
  /// [inAzure] and says "geen bedrijfsnaam ingesteld" out loud for the second:
  /// blank is a finding, not an absence of information.
  final String? azureCompanyName;

  /// Account-scoped warnings (e.g. the duplicate-mail message naming this uid).
  ///
  /// Read type-blind by `decisions_merge` as evidence that an accepted
  /// duplicate-*mail* collision still exists, which is why a sibling enrolment
  /// is [otherEnrolments] and not a warning string: it is context, not a
  /// situation anybody accepted.
  final List<String> warnings;

  final List<CandidateAction> candidates;

  /// Still-applicable operator decisions re-attached by the last sync.
  final List<AccountDecision> decisions;

  /// Whether an apply pass would write anything here (drives the "pending"
  /// badge counts): at least one decision whose selected resolution is
  /// applyable — [pendingDecisionCount] read as a flag, so the work-list filter
  /// keeps exactly the accounts the badges count (#251).
  bool get hasPending => pendingDecisionCount(candidates) > 0;

  MaterializedAccount withDecisions(List<AccountDecision> decisions) =>
      MaterializedAccount(
        id: id,
        school: school,
        schoolLabel: schoolLabel,
        gradeYear: gradeYear,
        classroom: classroom,
        role: role,
        isStaff: isStaff,
        confidence: confidence,
        label: label,
        inWisa: inWisa,
        inSmartschool: inSmartschool,
        inAzure: inAzure,
        wisaPresence: wisaPresence,
        otherEnrolments: otherEnrolments,
        departmentSchools: departmentSchools,
        azureCompanyName: azureCompanyName,
        warnings: warnings,
        candidates: candidates,
        decisions: decisions,
      );

  Map<String, dynamic> toJson() => {
        'id': id.toJson(),
        'pk': school,
        'school': school,
        'schoolLabel': schoolLabel,
        'gradeYear': gradeYear,
        'classroom': classroom,
        'role': role.toJson(),
        'isStaff': isStaff,
        'confidence': confidence.toJson(),
        'label': label,
        'inWisa': inWisa,
        'inSmartschool': inSmartschool,
        'inAzure': inAzure,
        // Written only when it says something, so the ordinary document — every
        // document but a handful — keeps exactly the shape it had, and an absent
        // key reads as the `ours` default rather than as a recorded value.
        if (wisaPresence != core.WisaPresence.ours)
          'wisaPresence': wisaPresence.toJson(),
        // Written only when there is one, so the ordinary document — every
        // document but a handful — keeps exactly the shape it had.
        if (otherEnrolments.isNotEmpty)
          'otherEnrolments': [for (final e in otherEnrolments) e.toJson()],
        // Likewise written only when there is one, so a student document — and
        // a staff document whose Azure `department` says nothing — keeps exactly
        // the shape it had. An absent key therefore reads as "nothing recorded",
        // never as "recorded, and empty", which is what keeps a document written
        // before #352 from being reported as a blank list.
        if (departmentSchools.isNotEmpty)
          'departmentSchools': departmentSchools,
        // Same rule once more, and the reason it matters here: an absent key and
        // a recorded blank would otherwise be two spellings of the finding the
        // pane exists to state. Only a value worth quoting is written, so
        // "absent" is the single, unambiguous spelling of "no bedrijfsnaam" —
        // and a value that *is* written goes in exactly as the tenant holds it.
        if (azureCompanyName != null && azureCompanyName!.isNotEmpty)
          'azureCompanyName': azureCompanyName,
        if (warnings.isNotEmpty) 'warnings': warnings,
        if (candidates.isNotEmpty)
          'candidates': [for (final c in candidates) c.toJson()],
        if (decisions.isNotEmpty)
          'decisions': [for (final d in decisions) d.toJson()],
      };

  factory MaterializedAccount.fromJson(Map<String, dynamic> json) =>
      MaterializedAccount(
        id: core.LinkedAccountId(json['id'] as String),
        school: json['school'] as String,
        schoolLabel: json['schoolLabel'] as String,
        gradeYear: json['gradeYear'] as String,
        classroom: json['classroom'] as String,
        role: core.PersonRole.fromJson(json['role'] as String),
        isStaff: json['isStaff'] as bool? ?? false,
        confidence: core.LinkConfidence.fromJson(json['confidence'] as String),
        label: json['label'] as String,
        inWisa: json['inWisa'] as bool? ?? false,
        inSmartschool: json['inSmartschool'] as bool? ?? false,
        inAzure: json['inAzure'] as bool? ?? false,
        wisaPresence: json['wisaPresence'] == null
            ? core.WisaPresence.ours
            : core.WisaPresence.fromJson(json['wisaPresence'] as String),
        otherEnrolments: [
          for (final e in (json['otherEnrolments'] as List? ?? const []))
            OtherEnrolment.fromJson(e as Map<String, dynamic>),
        ],
        departmentSchools: [
          for (final s in (json['departmentSchools'] as List? ?? const []))
            s as String,
        ],
        azureCompanyName: json['azureCompanyName'] as String?,
        warnings: [
          for (final w in (json['warnings'] as List? ?? const [])) w as String,
        ],
        candidates: [
          for (final c in (json['candidates'] as List? ?? const []))
            CandidateAction.fromJson(c as Map<String, dynamic>),
        ],
        decisions: [
          for (final d in (json['decisions'] as List? ?? const []))
            AccountDecision.fromJson(d as Map<String, dynamic>),
        ],
      );
}

/// The synthetic partition (and rollup school) every [MaterializedGroup] and the
/// group [Rollup] share (#119). Class groups have no natural school partition the
/// way a student does, so they live in one logical partition of their own — the
/// mirror of the `staff` bucket accounts use.
const String groupsPartition = 'groups';

/// The synthetic partition (and rollup school) every staff [MaterializedAccount]
/// shares. Staff have no WISA class the way a student does, so they land in one
/// logical bucket of their own — the counterpart of [groupsPartition]. Exposed
/// so the reconcile overview can tell the staff school [Rollup] apart from the
/// student-school rollups when it sums the per-category totals (#163).
const String staffPartition = 'staff';

/// The synthetic partition (and rollup school) every account with no class *of
/// ours* lands in — a student who left, or one who only exists in a school we do
/// not manage but still owns one of our accounts (#178). Exposed so the Actions
/// drill-down can tell this bucket apart from a real school when it flattens the
/// student tree to grade-years (#210): "Niet toegewezen" stays a top-level node
/// of its own instead of merging into a year.
const String unassignedPartition = 'unassigned';

/// One linked **class group** as a stored document (#119).
///
/// The group-family counterpart of [MaterializedAccount]: where a per-account
/// doc drills down through school / grade-year / classroom, a group record is a
/// `LinkedGroup` (a WISA class, an orphan Smartschool class, an Azure group left
/// behind by a class that is gone), which does not fit that per-account shape.
/// So the materializer emits these as their own documents in the
/// [groupsPartition], surfaced by the Klasgroepen tab rather than inside a
/// classroom.
///
/// Since #227 there is **one document per linked class**, not one per class with
/// work: the docs used to be derived from the dispatched actions, so a class with
/// nothing wrong had no document at all and could not be verified — which is
/// exactly how a wrong proposal (#225's `2G`) passed unnoticed in a list where
/// every row was a change. A class with no [candidates] is the normal, healthy
/// case now.
///
/// Like [MaterializedAccount] it is rewritten wholesale every sync, carries the
/// per-system presence and the computed [candidates], and re-attaches the
/// still-applicable operator [decisions] the last merge kept.
class MaterializedGroup {
  const MaterializedGroup({
    required this.id,
    required this.label,
    required this.confidence,
    required this.inWisa,
    required this.inSmartschool,
    required this.inAzure,
    this.description = '',
    this.className,
    this.azureGroupName,
    this.candidates = const [],
    this.decisions = const [],
  });

  /// The stable cross-system key of the group — the document id, and the key an
  /// [AccountDecision] targets a group by.
  final core.LinkedAccountId id;

  /// Display name for the group (its WISA/Smartschool/Azure name).
  final String label;

  final core.LinkConfidence confidence;

  final bool inWisa;
  final bool inSmartschool;
  final bool inAzure;

  /// The class's description as WISA (or Smartschool) spells it — the human
  /// line beside the bare name in the inventory (#227). Empty when neither
  /// system carries one.
  final String description;

  /// The **bare** class name this record belongs to (`2F` for `2F ECO`), copied
  /// off `LinkedGroup.className` (#228); `null` for a record with no WISA class
  /// behind it (a Smartschool-only orphan).
  ///
  /// The Office 365 column is per *class*, not per linked group: the sub-groups
  /// `2F ECO` / `2F MAW` / `2F MOW` / `2F STEMW` all map to the one group
  /// `<PREFIX>-2F`. Carrying the bare name lets the inventory say so, instead of
  /// showing four rows that each look like they own a group.
  final String? className;

  /// The display name of the Office 365 group this class is served by, when one
  /// exists (`GBS-2F` for every sub-group of `2F`); `null` when the class has no
  /// group yet. Not 1:1 with the row — see [className].
  final String? azureGroupName;

  /// The computed candidate group actions (e.g. an orphan-class notice, a
  /// create/modify). Some are informational (`canApply == false`).
  final List<CandidateAction> candidates;

  /// Still-applicable operator decisions re-attached by the last sync.
  final List<AccountDecision> decisions;

  /// The partition every group document shares — [groupsPartition].
  String get school => groupsPartition;

  /// Whether an apply pass would write anything here: at least one decision
  /// whose selected resolution is applyable (#251). The informational notices do
  /// not count, and neither does the opt-out half of an either/or the operator
  /// has not switched to.
  bool get hasPending => pendingDecisionCount(candidates) > 0;

  /// Whether this class asks anything of the operator at all (#227) — the
  /// predicate the Klasgroepen filter and the row highlight use.
  ///
  /// Deliberately **wider** than [hasPending]: a class can carry an
  /// informational-only notice (`ClassExistsAsSmartschoolGroup` and friends,
  /// #225/#250), which is real manual work with no automated write, so it adds
  /// nothing to the pending count. Filtering on the pending count alone would
  /// bury exactly the notices those issues exist to surface.
  bool get needsAttention => candidates.isNotEmpty;

  MaterializedGroup withDecisions(List<AccountDecision> decisions) =>
      MaterializedGroup(
        id: id,
        label: label,
        confidence: confidence,
        inWisa: inWisa,
        inSmartschool: inSmartschool,
        inAzure: inAzure,
        description: description,
        className: className,
        azureGroupName: azureGroupName,
        candidates: candidates,
        decisions: decisions,
      );

  Map<String, dynamic> toJson() => {
        'id': id.toJson(),
        'pk': groupsPartition,
        'label': label,
        'confidence': confidence.toJson(),
        'inWisa': inWisa,
        'inSmartschool': inSmartschool,
        'inAzure': inAzure,
        if (description.isNotEmpty) 'description': description,
        if (className != null) 'className': className,
        if (azureGroupName != null) 'azureGroupName': azureGroupName,
        if (candidates.isNotEmpty)
          'candidates': [for (final c in candidates) c.toJson()],
        if (decisions.isNotEmpty)
          'decisions': [for (final d in decisions) d.toJson()],
      };

  factory MaterializedGroup.fromJson(Map<String, dynamic> json) =>
      MaterializedGroup(
        id: core.LinkedAccountId(json['id'] as String),
        label: json['label'] as String,
        confidence: core.LinkConfidence.fromJson(json['confidence'] as String),
        inWisa: json['inWisa'] as bool? ?? false,
        inSmartschool: json['inSmartschool'] as bool? ?? false,
        inAzure: json['inAzure'] as bool? ?? false,
        description: json['description'] as String? ?? '',
        className: json['className'] as String?,
        azureGroupName: json['azureGroupName'] as String?,
        candidates: [
          for (final c in (json['candidates'] as List? ?? const []))
            CandidateAction.fromJson(c as Map<String, dynamic>),
        ],
        decisions: [
          for (final d in (json['decisions'] as List? ?? const []))
            AccountDecision.fromJson(d as Map<String, dynamic>),
        ],
      );
}

/// Which level of the drill-down a [Rollup] aggregates.
enum RollupLevel {
  school,
  gradeYear,
  classroom,

  /// The single top-level "Klasgroepen" node aggregating every
  /// [MaterializedGroup] (#119). It sits outside the school → grade-year →
  /// classroom tree; its [Rollup.accountCount] counts the group docs and
  /// [Rollup.pendingCount] their applyable actions.
  groups,
  ;

  String toJson() => name;
  static RollupLevel fromJson(String s) => values.byName(s);
}

/// A small aggregate document that drives the drill-down without loading the
/// per-account docs beneath it.
///
/// One per school / grade-year / classroom node, linked by [key] → [parentKey].
/// [accountCount] is how many accounts sit under this node; [pendingCount] is
/// how many applyable candidate actions they carry (the "N pending here" badge).
class Rollup {
  const Rollup({
    required this.level,
    required this.key,
    required this.parentKey,
    required this.school,
    required this.label,
    required this.gradeYear,
    required this.classroom,
    required this.accountCount,
    required this.pendingCount,
  });

  final RollupLevel level;

  /// Stable node id, unique across the whole view (encodes the path).
  final String key;

  /// The parent node's [key], or `null` for a school node.
  final String? parentKey;

  /// The school bucket (partition) this node lives in.
  final String school;

  /// Human label for this node (school name / grade-year / classroom).
  final String label;

  /// The grade-year bucket for a grade-year or classroom node, else empty.
  final String gradeYear;

  /// The classroom bucket for a classroom node, else empty.
  final String classroom;

  final int accountCount;
  final int pendingCount;

  Map<String, dynamic> toJson() => {
        'id': key,
        'pk': school,
        'level': level.toJson(),
        'key': key,
        if (parentKey != null) 'parentKey': parentKey,
        'school': school,
        'label': label,
        'gradeYear': gradeYear,
        'classroom': classroom,
        'accountCount': accountCount,
        'pendingCount': pendingCount,
      };

  factory Rollup.fromJson(Map<String, dynamic> json) => Rollup(
        level: RollupLevel.fromJson(json['level'] as String),
        key: json['key'] as String,
        parentKey: json['parentKey'] as String?,
        school: json['school'] as String,
        label: json['label'] as String,
        gradeYear: json['gradeYear'] as String? ?? '',
        classroom: json['classroom'] as String? ?? '',
        accountCount: json['accountCount'] as int,
        pendingCount: json['pendingCount'] as int,
      );
}

/// Who last synced one system, and when (#108).
///
/// Recorded per concrete system (WISA / Smartschool / Azure) so the reconcile
/// screen can show "Last sync — WISA 09:12 by jan@…" from the *shared* store,
/// not just this session's in-process [SystemState.lastSync]. Written into the
/// [SyncState.systems] map by the operator whose sync pulled that system.
class SystemSyncMeta {
  const SystemSyncMeta({
    required this.syncedBy,
    required this.at,
    this.workDate,
  });

  /// The operator (AAD UPN) whose session pulled this system.
  final String syncedBy;

  /// When that pull's snapshot was fetched.
  final DateTime at;

  /// The **werkdatum** a WISA pull asked for — the date the roster now
  /// installed is *as of* (#247). Null for Smartschool and Azure, which have
  /// no such input, and on a WISA stamp written before this was recorded.
  ///
  /// It rides here rather than on [SyncState] itself because it is a property
  /// of the WISA *pull*, not of the materialize: a Check-for-drift re-links
  /// without re-pulling WISA, so the roster — and the date it describes — stays
  /// the one this entry already names, exactly as [at] and [syncedBy] do. That
  /// also puts it in the shared store, so a passive session (#115) reading a
  /// view somebody else synced can tell which school year it describes without
  /// having run the pass itself.
  final DateTime? workDate;

  Map<String, dynamic> toJson() => {
        'syncedBy': syncedBy,
        'at': at.toIso8601String(),
        if (workDate != null) 'workDate': workDate!.toIso8601String(),
      };

  factory SystemSyncMeta.fromJson(Map<String, dynamic> json) => SystemSyncMeta(
        syncedBy: json['syncedBy'] as String,
        at: DateTime.parse(json['at'] as String),
        workDate: json['workDate'] == null
            ? null
            : DateTime.parse(json['workDate'] as String),
      );
}

/// Freshness + version marker for the whole materialized view.
///
/// [generation] is bumped on every sync that rewrites the view, so a
/// just-connected client can detect a stale local copy (used more fully by the
/// SignalR work in #116). [updatedAt] / [updatedBy] record who last ran the
/// materialize; [systems] records who last pulled each individual system (#108).
class SyncState {
  const SyncState({
    required this.generation,
    this.updatedAt,
    this.updatedBy,
    this.systems = const {},
  });

  final int generation;
  final DateTime? updatedAt;
  final String? updatedBy;

  /// Per-system last-sync metadata, keyed by concrete [core.Origin]
  /// (wisa/smartschool/azure). Empty before the first sync of a given system.
  final Map<core.Origin, SystemSyncMeta> systems;

  /// The initial state before any sync has ever run.
  static const SyncState initial = SyncState(generation: 0);

  SyncState bumped({
    DateTime? at,
    String? by,
    Map<core.Origin, SystemSyncMeta>? systems,
  }) =>
      SyncState(
        generation: generation + 1,
        updatedAt: at ?? updatedAt,
        updatedBy: by ?? updatedBy,
        systems: systems ?? this.systems,
      );

  Map<String, dynamic> toJson() => {
        'generation': generation,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        if (updatedBy != null) 'updatedBy': updatedBy,
        if (systems.isNotEmpty)
          'systems': {
            for (final e in systems.entries) e.key.toJson(): e.value.toJson(),
          },
      };

  factory SyncState.fromJson(Map<String, dynamic> json) => SyncState(
        generation: json['generation'] as int? ?? 0,
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
        updatedBy: json['updatedBy'] as String?,
        systems: {
          for (final e
              in (json['systems'] as Map<String, dynamic>? ?? const {}).entries)
            core.Origin.fromJson(e.key):
                SystemSyncMeta.fromJson(e.value as Map<String, dynamic>),
        },
      );
}

/// The coarse, serialized **sync/drift lease** (#108).
///
/// Synchronise and Check-for-drift are rare, heavy, and global, so they run
/// under a single lease rather than concurrently: while one operator holds it,
/// every other operator's sync/drift is disabled. The lease carries its [owner]
/// (AAD UPN), the last [heartbeatAt] the holder refreshed it, and an [expiresAt]
/// so a *crashed* holder cannot keep it forever — once [expiresAt] passes the
/// lease is free for the taking (backed in Cosmos by the document's TTL, so an
/// abandoned lease is also physically swept).
///
/// Per-record apply / password changes are deliberately **not** gated by this
/// lease — they are frequent and concurrent, guarded instead by per-document
/// optimistic concurrency (#121).
class SyncLease {
  const SyncLease({
    required this.owner,
    required this.heartbeatAt,
    required this.expiresAt,
  });

  /// The operator (AAD UPN) currently holding the lease.
  final String owner;

  /// When the holder last renewed the lease.
  final DateTime heartbeatAt;

  /// When the lease lapses if not renewed — a crashed holder's lease expires
  /// here so another operator can take over.
  final DateTime expiresAt;

  /// Whether the lease has lapsed as of [now] (holder stopped heart-beating).
  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  /// Whether the lease is still live and held by [owner] as of [now].
  bool isLiveAt(DateTime now) => !isExpiredAt(now);

  Map<String, dynamic> toJson() => {
        'owner': owner,
        'heartbeatAt': heartbeatAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
      };

  factory SyncLease.fromJson(Map<String, dynamic> json) => SyncLease(
        owner: json['owner'] as String,
        heartbeatAt: DateTime.parse(json['heartbeatAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
      );
}

/// How long a freshly acquired or renewed [SyncLease] stays live before it must
/// be heart-beaten again. A holder renews well within this window; a crashed
/// holder's lease frees after it (#108).
const Duration syncLeaseTtl = Duration(seconds: 90);

/// The outcome of an [LinkedStore.acquireLease] / [LinkedStore.renewLease]
/// attempt: whether the caller [acquired] (now holds) the lease, and the
/// [lease] as it currently stands — the caller's own when [acquired], otherwise
/// the live lease held by another operator.
class LeaseOutcome {
  const LeaseOutcome({required this.acquired, required this.lease});

  /// True when the caller now holds the lease (freshly taken or already theirs).
  final bool acquired;

  /// The current lease: the caller's when [acquired], else the blocking holder.
  final SyncLease lease;

  /// True when another operator holds a live lease, blocking the caller.
  bool get heldByOther => !acquired;
}

/// The complete materialized output of one sync: the per-account docs, the
/// per-group docs (#119), and the derived [rollups] (which include the single
/// group node), stamped with the [generation] the store will write.
class MaterializedView {
  const MaterializedView({
    required this.generation,
    required this.accounts,
    required this.rollups,
    this.groups = const [],
    this.skippedUnmanagedStudents = 0,
    this.skippedUnmanagedStaff = 0,
  });

  final int generation;
  final List<MaterializedAccount> accounts;

  /// The per-group documents for the group-action family (#119).
  final List<MaterializedGroup> groups;
  final List<Rollup> rollups;

  /// How many linked students the materialize deliberately left out because
  /// they exist only in a school we do **not** manage and own no account of
  /// ours (#178) — the drop that used to be silent (#230).
  ///
  /// Not part of the persisted view; it is pass metadata the sync reports, so an
  /// operator who cannot find an intake in Acties can tell "filtered out by the
  /// managed-school flags in Instellingen" from "never came back from WISA".
  final int skippedUnmanagedStudents;

  /// How many linked **staff** the materialize deliberately left out because
  /// they belong to a school of the group we do not manage and hold no account
  /// of ours (#340) — the personeel twin of [skippedUnmanagedStudents].
  ///
  /// Expect this to be large: the shared WISA credentials pull the group's whole
  /// personeel and most of it is other schools'. Also pass metadata rather than
  /// part of the persisted view, and reported by the sync for the same reason —
  /// the drop must be legible, since the records themselves are deliberately
  /// kept intact behind it so no removal action is ever proposed for a colleague
  /// the group still employs.
  final int skippedUnmanagedStaff;
}
