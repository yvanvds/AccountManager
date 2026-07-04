import 'dart:convert';

import 'package:account_core/account_core.dart' as core;

import '../blob/blob_store.dart';
import 'cosmos_client.dart';
import 'cosmos_config.dart';

/// A cold snapshot as it comes back from the store: the raw connector payload
/// plus the metadata the sync/drift process reads to decide freshness.
///
/// [payload] is the JSON the owning connector's `Snapshot.fromJson` reconstructs
/// from (`WisaSnapshot.fromJson`, `SmartschoolSnapshot.fromJson`,
/// `AzureSnapshot.fromJson`). [deltaToken] is surfaced in the metadata (not only
/// buried in the Azure payload) so the sync process can read the token to
/// resume `/users/delta` **without** fetching a possibly-Blob-sized payload.
class StoredSnapshot {
  const StoredSnapshot({
    required this.payload,
    required this.fetchedAt,
    required this.syncedBy,
    this.deltaToken,
  });

  final Map<String, dynamic> payload;
  final DateTime fetchedAt;

  /// The operator (UPN) whose session produced this snapshot.
  final String syncedBy;

  /// The Azure `$deltatoken` for the next incremental sync; `null` for WISA and
  /// Smartschool (which read fully each time).
  final String? deltaToken;
}

/// Persists the WISA, Smartschool and Azure snapshots as **cold storage** so a
/// fresh session seeds from the store instead of re-pulling, and a passive
/// session pulls nothing at all (#107, part of #112).
///
/// Only the sync/drift process reads or writes through this seam — the
/// dashboard never touches it. Keeping it an interface (with the Cosmos+Blob
/// [CosmosSnapshotStore] as the production implementation and an in-memory fake
/// in tests) mirrors the other persistence seams in this package.
abstract interface class SnapshotStore {
  /// Loads the stored snapshot for [system], or `null` when none has been
  /// persisted yet (first ever run) — so first-run has no special case.
  Future<StoredSnapshot?> load(core.Origin system);

  /// Replaces the stored snapshot for [system] with [payload] and its metadata.
  /// [deltaToken] is the Azure delta token (omit for WISA/Smartschool).
  Future<void> save(
    core.Origin system, {
    required Map<String, dynamic> payload,
    required DateTime fetchedAt,
    required String syncedBy,
    String? deltaToken,
  });
}

/// The [SnapshotStore] backed by the Cosmos `snapshots` container plus a
/// [BlobStore] overflow.
///
/// Each system's snapshot is one metadata document (`{ id, pk, system,
/// fetchedAt, syncedBy, deltaToken }`) that carries the raw payload one of two
/// ways: **inline** in a `payload` field when it fits, or a **`blobRef`** to the
/// [BlobStore] when the encoded payload would push the document past Cosmos's
/// 2 MB limit (a whole-school WISA or Azure snapshot easily can). The read path
/// is symmetric: a `blobRef` document fetches the payload from Blob, an inline
/// one reads it straight from the document.
class CosmosSnapshotStore implements SnapshotStore {
  CosmosSnapshotStore(
    this._client,
    this._blobs, {
    int inlineLimitBytes = _defaultInlineLimitBytes,
  }) : _inlineLimitBytes = inlineLimitBytes;

  final CosmosClient _client;
  final BlobStore _blobs;
  final int _inlineLimitBytes;

  /// The inline-payload byte ceiling. Cosmos caps a whole document at 2 MB;
  /// this leaves headroom for the metadata fields and Cosmos's own envelope, so
  /// a payload under it is safe to inline.
  static const int _defaultInlineLimitBytes = 1900 * 1024;

  @override
  Future<StoredSnapshot?> load(core.Origin system) async {
    final id = _docId(system);
    final doc = await _client.readDocument(
      container: snapshotsContainer,
      id: id,
      partitionKey: id,
    );
    if (doc == null) return null;

    final Map<String, dynamic> payload;
    final blobRef = doc['blobRef'];
    if (blobRef is String) {
      final raw = await _blobs.read(blobRef);
      // The metadata points at a payload that is gone; treat the whole snapshot
      // as absent so the caller falls back to pulling rather than half-reading.
      if (raw == null) return null;
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } else {
      final inline = doc['payload'];
      payload = inline is Map<String, dynamic> ? inline : <String, dynamic>{};
    }

    return StoredSnapshot(
      payload: payload,
      fetchedAt: DateTime.parse(doc['fetchedAt'] as String),
      syncedBy: (doc['syncedBy'] as String?) ?? '',
      deltaToken: doc['deltaToken'] as String?,
    );
  }

  @override
  Future<void> save(
    core.Origin system, {
    required Map<String, dynamic> payload,
    required DateTime fetchedAt,
    required String syncedBy,
    String? deltaToken,
  }) async {
    final id = _docId(system);
    final doc = <String, dynamic>{
      'id': id,
      'pk': id,
      'system': system.toJson(),
      'fetchedAt': fetchedAt.toIso8601String(),
      'syncedBy': syncedBy,
      if (deltaToken != null) 'deltaToken': deltaToken,
    };

    final encoded = jsonEncode(payload);
    if (utf8.encode(encoded).length > _inlineLimitBytes) {
      doc['blobRef'] = await _blobs.write(_blobName(system), encoded);
    } else {
      doc['payload'] = payload;
    }

    await _client.upsertDocument(
      container: snapshotsContainer,
      partitionKey: id,
      document: doc,
    );
  }

  /// The metadata document id (and partition-key value) for [system].
  static String _docId(core.Origin system) => _systemName(system);

  /// The deterministic overflow-blob name for [system]. Deterministic so a
  /// re-sync overwrites the same blob rather than leaking a new one each time.
  static String _blobName(core.Origin system) =>
      'snapshot-${_systemName(system)}.json';

  static String _systemName(core.Origin system) {
    switch (system) {
      case core.Origin.wisa:
      case core.Origin.smartschool:
      case core.Origin.azure:
        return system.toJson();
      case core.Origin.all:
      case core.Origin.other:
        throw ArgumentError.value(
          system,
          'system',
          'snapshots are stored per concrete system (wisa/smartschool/azure)',
        );
    }
  }
}
