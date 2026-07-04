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

import 'package:account_actions/account_actions.dart' show FieldChange;
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
              },
          ],
        'canApply': canApply,
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
            ),
        ],
        canApply: json['canApply'] as bool? ?? true,
      );
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

/// A persisted operator decision about one account.
///
/// [targetKind] is the "situation" the decision resolves — the [kind] of the
/// [CandidateAction] it applies to, or a warning id for [acceptedDuplicate]. On
/// the next sync the merge keeps this decision only while an account still has
/// a matching situation (see [mergeDecisions]).
class AccountDecision {
  const AccountDecision({
    required this.accountId,
    required this.kind,
    required this.targetKind,
    this.payload = const {},
    required this.decidedBy,
    required this.decidedAt,
  });

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

  /// Account-scoped warnings (e.g. the duplicate-mail message naming this uid).
  final List<String> warnings;

  final List<CandidateAction> candidates;

  /// Still-applicable operator decisions re-attached by the last sync.
  final List<AccountDecision> decisions;

  /// Whether an apply pass would write anything here (drives the "pending"
  /// badge counts): at least one applyable candidate.
  bool get hasPending => candidates.any((c) => c.canApply);

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

/// Which level of the drill-down a [Rollup] aggregates.
enum RollupLevel {
  school,
  gradeYear,
  classroom,
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
  const SystemSyncMeta({required this.syncedBy, required this.at});

  /// The operator (AAD UPN) whose session pulled this system.
  final String syncedBy;

  /// When that pull's snapshot was fetched.
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'syncedBy': syncedBy,
        'at': at.toIso8601String(),
      };

  factory SystemSyncMeta.fromJson(Map<String, dynamic> json) => SystemSyncMeta(
        syncedBy: json['syncedBy'] as String,
        at: DateTime.parse(json['at'] as String),
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

/// The complete materialized output of one sync: the per-account docs plus the
/// derived [rollups], stamped with the [generation] the store will write.
class MaterializedView {
  const MaterializedView({
    required this.generation,
    required this.accounts,
    required this.rollups,
  });

  final int generation;
  final List<MaterializedAccount> accounts;
  final List<Rollup> rollups;
}
