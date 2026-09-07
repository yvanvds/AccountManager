import 'package:late_arrivals/late_arrivals.dart';

import 'cosmos_client.dart';
import 'cosmos_config.dart';

/// The [LateArrivalMirrorStore] backed by the Cosmos [lateArrivalsContainer]
/// (#403).
///
/// The shared copy of the reception desk's day: one document per registration,
/// upserted on the registration itself and again on every status change, so the
/// day's queue survives the loss of the machine that made it and a colleague on
/// her own laptop can pick up what was never drained.
///
/// Deliberately the thinnest adapter in this package. Everything that decides
/// *when* to write, how often to retry and what to do about a persistent
/// failure lives in [LateArrivalMirror], in the pure package, where it is
/// testable with no infra; this only binds the container. Note what is **not**
/// here: no `If-Match`, no lease, no claim. Two desks writing the same student's
/// half-day is accepted by design (#403) — they write two documents, and a
/// presence save updates the cell rather than duplicating a row.
class CosmosLateArrivalMirrorStore implements LateArrivalMirrorStore {
  CosmosLateArrivalMirrorStore(this._client);

  final CosmosClient _client;

  @override
  Future<void> put(MirroredRegistration entry) async {
    await _client.upsertDocument(
      container: lateArrivalsContainer,
      partitionKey: entry.partitionKey,
      document: <String, dynamic>{...entry.toDocument()},
    );
  }

  @override
  Future<List<MirroredRegistration>> readDay(SchoolDay day) async {
    // Scoped to the day's own logical partition: the whole point of
    // partitioning by day is that this read never goes cross-partition.
    final List<Map<String, dynamic>> documents = await _client.queryDocuments(
      container: lateArrivalsContainer,
      query: 'SELECT * FROM c WHERE c.pk = @pk',
      parameters: <String, Object?>{'@pk': day.id},
      partitionKey: day.id,
    );
    return <MirroredRegistration>[
      for (final Map<String, dynamic> doc in documents)
        if (MirroredRegistration.tryFromDocument(doc) case final entry?) entry,
    ];
  }
}
