import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import '../cosmos/cosmos_snapshot_store.dart';
import 'application_state.dart';
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

/// Writes back the snapshots a pass **patched locally**, so the cold store
/// carries what the pass ended with rather than what it started from (#347).
///
/// [persistingSyncer] covers the pull path; this covers the incremental-refresh
/// path it cannot see. A [SystemState.patch] deliberately bypasses the syncer —
/// that is the whole point of #345's local WISA filter and of the Smartschool /
/// Azure record splices — so nothing wrote the result anywhere, and the next
/// session to seed from the store linked from a roster this one had already
/// corrected: the staff member an operator told the app to stop importing was
/// back, and the work the rule silenced was proposed again.
///
/// Called **once at the end of a pass**, not per patch. A pass applying thirty
/// actions patches thirty times, and each write here serializes the whole roster
/// (a Cosmos document, or a Blob when it overflows) — per-patch write-through
/// would trade #345's twenty seconds for something worse. Only the systems the
/// pass actually touched are written; the rest are skipped untouched.
///
/// The patched snapshot's own `fetchedAt` is carried over rather than restamped:
/// a local filter is not a fresh fetch (the same reason [SystemState.patch]
/// leaves `lastSync` alone), so a cold seed's freshness stays honest. Azure's
/// delta token rides along for the same reason — the patch helpers preserve it,
/// and dropping it here would force the next session into a full tenant read.
///
/// Persistence is **best-effort**, exactly as it is on the pull path: a failed
/// write is reported to [onError] and swallowed, never failing a pass whose
/// writes to Smartschool and Office 365 really happened. The flag is left set on
/// failure, so the next pass to patch that system retries the write.
Future<void> persistPatchedSnapshots(
  ApplicationState app, {
  required SnapshotStore store,
  required String syncedBy,
  void Function(core.Origin system, Object error)? onError,
}) async {
  await _writeBack<WisaSnapshot>(
    app.wisa,
    store: store,
    syncedBy: syncedBy,
    payloadOf: (s) => s.toJson(),
    onError: onError,
  );
  await _writeBack<SmartschoolSnapshot>(
    app.smartschool,
    store: store,
    syncedBy: syncedBy,
    payloadOf: (s) => s.toJson(),
    onError: onError,
  );
  await _writeBack<AzureSnapshot>(
    app.azure,
    store: store,
    syncedBy: syncedBy,
    payloadOf: (s) => s.toJson(),
    deltaTokenOf: (s) => s.deltaToken,
    onError: onError,
  );
}

Future<void> _writeBack<S extends core.Snapshot>(
  SystemState<S> state, {
  required SnapshotStore store,
  required String syncedBy,
  required Map<String, dynamic> Function(S snapshot) payloadOf,
  String? Function(S snapshot)? deltaTokenOf,
  void Function(core.Origin system, Object error)? onError,
}) async {
  if (!state.hasUnpersistedPatch) return;
  final snapshot = state.snapshot;
  // Unreachable in practice — patching requires a snapshot to patch — but the
  // flag and the slot are separate pieces of state, so this stays total.
  if (snapshot == null) return;
  try {
    await store.save(
      state.system,
      payload: payloadOf(snapshot),
      fetchedAt: snapshot.fetchedAt,
      syncedBy: syncedBy,
      deltaToken: deltaTokenOf?.call(snapshot),
    );
    state.markPatchPersisted();
  } on Object catch (e) {
    onError?.call(state.system, e);
  }
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
