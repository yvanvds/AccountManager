/// The small, data-free notifications the realtime layer (#116) carries between
/// operators so the shared materialized view stays live without polling.
///
/// At 20–40 concurrent operators, polling Cosmos for freshness would keep the
/// serverless account permanently awake and erase its cost benefit. Instead a
/// **writer** (a sync/drift pass, or — later — an apply) pushes a small signal
/// over Azure SignalR carrying only *identifiers*, never data; on receipt a
/// client reads just the affected shard from Cosmos, so the DB wakes only on a
/// real change. The signal is the *nudge*; the stored `generation` marker in
/// `syncState` is the *source of truth* for "am I current" — a just-connected or
/// missed-a-message client compares generations and refetches regardless.
library;

/// What a [ChangeSignal] tells the receiving clients to do.
enum ChangeSignalKind {
  /// A sync/drift **lease** was acquired (#108): the holder is [ChangeSignal.owner].
  /// Other clients disable Synchronise / Check-for-drift and name the owner. The
  /// signal is only a nudge — the receiver re-reads the real lease from the store
  /// to get its owner/expiry, so a missed message self-heals.
  syncStarted,

  /// The sync/drift lease was released: other clients re-enable Synchronise /
  /// Check-for-drift. Again a nudge — the receiver re-reads the (now absent)
  /// lease from the store.
  syncEnded,

  /// A materialize wrote a new view [ChangeSignal.generation]. A client whose
  /// cached generation is older refetches the changed [ChangeSignal.shard] (or,
  /// when the shard is null, the whole materialized overview the current
  /// sync/materialize path rewrites wholesale) — no connector pull, no `link()`.
  viewChanged,
}

/// Names the part of the shared state a [ChangeSignalKind.viewChanged] concerns,
/// so a receiver can refetch only that shard rather than the whole view.
///
/// A **null** shard on a `viewChanged` signal means the entire materialized view
/// was rewritten — which is what the sync/materialize path does (it replaces
/// every per-account doc and rollup in one pass), so its signal names no
/// narrower shard. A **named** shard (a school, a classroom, or a single
/// account) is what a real apply broadcasts since #254: its write-back touches
/// only the documents it changed, so a receiver can skip re-reading a
/// drill-down the shard proves it cannot have moved. An apply that spans several
/// classrooms, or that removed a document (whose partition the writer no longer
/// knows), widens back to the whole view rather than naming a shard it cannot
/// vouch for.
class ShardRef {
  const ShardRef({this.school, this.classroom, this.accountId});

  /// The school partition the change falls in, when known.
  final String? school;

  /// The classroom whose `linkedAccounts` changed, when the change is that
  /// narrow. Paired with [school].
  final String? classroom;

  /// The single linked-account id that changed, for an apply-level signal.
  final String? accountId;

  /// True when this ref names nothing — a whole-view change (the sync path).
  bool get isWholeView =>
      school == null && classroom == null && accountId == null;

  /// Whether a change in this shard **could** have touched the [school]
  /// partition. True for a whole-view change and for any shard that names no
  /// school; false only when this shard positively names a different one.
  ///
  /// Deliberately permissive: a receiver uses it to *skip* re-reads it can prove
  /// pointless, so an unknown shard must always read as "might have".
  bool touchesPartition(String school) =>
      this.school == null || this.school == school;

  /// Whether a change in this shard could have touched [classroom] of [school] —
  /// the test a session with a classroom open uses to decide whether the drilled
  /// -in list has to be re-read at all (#254).
  bool touchesClassroom({required String school, required String classroom}) =>
      touchesPartition(school) &&
      (this.classroom == null || this.classroom == classroom);

  Map<String, dynamic> toJson() => {
        if (school != null) 'school': school,
        if (classroom != null) 'classroom': classroom,
        if (accountId != null) 'accountId': accountId,
      };

  factory ShardRef.fromJson(Map<String, dynamic> json) => ShardRef(
        school: json['school'] as String?,
        classroom: json['classroom'] as String?,
        accountId: json['accountId'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is ShardRef &&
      other.school == school &&
      other.classroom == classroom &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(school, classroom, accountId);

  @override
  String toString() =>
      isWholeView ? 'ShardRef(whole view)' : 'ShardRef(${toJson()})';
}

/// One realtime notification: a [kind] plus the few identifiers that kind needs.
///
/// Deliberately tiny and data-free so it is cheap to fan out to every connected
/// operator and safe to log — it carries who holds the lease ([owner]) or which
/// [generation] / [shard] changed, never account data. Round-trips through
/// [toJson] / [fromJson] as the SignalR message payload.
class ChangeSignal {
  const ChangeSignal._({
    required this.kind,
    this.owner,
    this.generation,
    this.shard,
  });

  /// A sync/drift lease was acquired by [owner] (AAD UPN).
  const ChangeSignal.syncStarted({required String owner})
      : this._(kind: ChangeSignalKind.syncStarted, owner: owner);

  /// The sync/drift lease held by [owner] was released.
  const ChangeSignal.syncEnded({required String owner})
      : this._(kind: ChangeSignalKind.syncEnded, owner: owner);

  /// A materialize bumped the view to [generation]; [shard] names the changed
  /// part, or is null for a whole-view rewrite (the sync/materialize path).
  const ChangeSignal.viewChanged({required int generation, ShardRef? shard})
      : this._(
          kind: ChangeSignalKind.viewChanged,
          generation: generation,
          shard: shard,
        );

  final ChangeSignalKind kind;

  /// The lease holder (AAD UPN) for [ChangeSignalKind.syncStarted] /
  /// [ChangeSignalKind.syncEnded]; null otherwise.
  final String? owner;

  /// The new view generation for [ChangeSignalKind.viewChanged]; null otherwise.
  final int? generation;

  /// The changed shard for [ChangeSignalKind.viewChanged], or null for a
  /// whole-view change; always null for the lease kinds.
  final ShardRef? shard;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (owner != null) 'owner': owner,
        if (generation != null) 'generation': generation,
        if (shard != null) 'shard': shard!.toJson(),
      };

  factory ChangeSignal.fromJson(Map<String, dynamic> json) {
    final kind = ChangeSignalKind.values.byName(json['kind'] as String);
    final shardJson = json['shard'] as Map<String, dynamic>?;
    return ChangeSignal._(
      kind: kind,
      owner: json['owner'] as String?,
      generation: json['generation'] as int?,
      shard: shardJson == null ? null : ShardRef.fromJson(shardJson),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChangeSignal &&
      other.kind == kind &&
      other.owner == owner &&
      other.generation == generation &&
      other.shard == shard;

  @override
  int get hashCode => Object.hash(kind, owner, generation, shard);

  @override
  String toString() => 'ChangeSignal(${toJson()})';
}
