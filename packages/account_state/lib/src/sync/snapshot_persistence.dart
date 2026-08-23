import 'package:account_core/account_core.dart' as core;

import '../cosmos/cosmos_snapshot_store.dart';
import 'system_state.dart';

/// Wraps [inner] so each successful pull is persisted to [store] as the cold
/// snapshot the next session seeds from (#107).
///
/// Persistence is **best-effort**: a store write that fails is reported to
/// [onError] and swallowed, never failing an otherwise-good pull. The operator
/// still gets fresh data this session; the only cost of a failed write is that
/// the next session re-pulls instead of seeding. This keeps a transient Cosmos
/// or Blob hiccup from turning a good sync into a sync error.
///
/// [payloadOf] serializes the fresh snapshot (`Snapshot.toJson`); [deltaTokenOf]
/// extracts the Azure delta token (omit for WISA/Smartschool). [syncedBy] is the
/// operator (UPN) recorded on the stored metadata.
Syncer<S> persistingSyncer<S extends core.Snapshot>({
  required core.Origin system,
  required Syncer<S> inner,
  required SnapshotStore store,
  required String syncedBy,
  required Map<String, dynamic> Function(S snapshot) payloadOf,
  String? Function(S snapshot)? deltaTokenOf,
  void Function(Object error)? onError,
}) {
  return (previous, {bool fullRead = false}) async {
    // Forwarded rather than swallowed: whether the pass is a re-read is the
    // caller's decision (#316), and this wrapper only adds persistence to
    // whatever [inner] produces.
    final fresh = await inner(previous, fullRead: fullRead);
    try {
      await store.save(
        system,
        payload: payloadOf(fresh),
        fetchedAt: fresh.fetchedAt,
        syncedBy: syncedBy,
        deltaToken: deltaTokenOf?.call(fresh),
      );
    } on Object catch (e) {
      onError?.call(e);
    }
    return fresh;
  };
}

/// Loads the stored snapshot for [system] and reconstructs it via [fromPayload],
/// to seed a [SystemState.initial] so a fresh session trusts the stored state
/// instead of pulling (#107).
///
/// Returns `null` when nothing is stored yet (first ever run) **or** the stored
/// payload can't be reconstructed (schema drift after an upgrade) — reported to
/// [onError] — so a bad stored copy degrades to a re-pull rather than a crash.
Future<S?> seedSnapshot<S extends core.Snapshot>({
  required core.Origin system,
  required SnapshotStore store,
  required S Function(Map<String, dynamic> payload) fromPayload,
  void Function(Object error)? onError,
}) async {
  final stored = await store.load(system);
  if (stored == null) return null;
  try {
    return fromPayload(stored.payload);
  } on Object catch (e) {
    onError?.call(e);
    return null;
  }
}
