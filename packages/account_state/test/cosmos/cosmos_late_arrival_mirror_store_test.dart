/// The Cosmos binding of the late-arrival mirror (#403).
///
/// The worker's behaviour (retry, coalescing, reconciliation) is covered in
/// `late_arrivals`; what is asserted here is the wire: the container it writes,
/// the partition it addresses, and that a day's registrations across every desk
/// come back from **one** partition query.
library;

import 'package:account_state/account_state.dart';
import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

import 'fake_cosmos_client.dart';

void main() {
  final monday = DateTime(2026, 9, 7, 8, 14, 33);
  final mondayDay = SchoolDay.of(monday);
  final tuesdayDay = SchoolDay.of(monday.add(const Duration(days: 1)));

  LateArrivalRecord recordOf({
    required SchoolDay day,
    int sequence = 1,
    LateArrivalStatus status = LateArrivalStatus.pending,
    String uid = 'jane.doe',
  }) =>
      LateArrivalRecord(
        id: '${day.id}-${sequence.toString().padLeft(4, '0')}',
        day: day,
        sequence: sequence,
        scannedAt: monday,
        smartschoolUid: uid,
        wisaId: '123456',
        displayName: 'Jane Doe',
        className: '1A',
        internalUserId: 12016,
        classGroupId: 298,
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
        motivation: '08:14 – Bus te laat',
        status: status,
      );

  MirroredRegistration entry({
    String desk = 'onthaal-1',
    SchoolDay? day,
    int sequence = 1,
    LateArrivalStatus status = LateArrivalStatus.pending,
    String uid = 'jane.doe',
  }) =>
      MirroredRegistration(
        deskId: desk,
        record: recordOf(
          day: day ?? mondayDay,
          sequence: sequence,
          status: status,
          uid: uid,
        ),
        mirroredAt: monday,
      );

  group('CosmosLateArrivalMirrorStore', () {
    test('writes one document per registration, partitioned by the day',
        () async {
      final client = FakeCosmosClient();
      final store = CosmosLateArrivalMirrorStore(client);

      await store.put(entry());

      final docs = client.documentsIn(lateArrivalsContainer);
      expect(docs, hasLength(1));
      expect(docs.single['id'], '2026-09-07|onthaal-1|0001');
      expect(docs.single['pk'], '2026-09-07');
      expect(docs.single['desk'], 'onthaal-1');
      expect(docs.single['status'], 'pending');
      expect(client.lastPartitionKey[lateArrivalsContainer], '2026-09-07');
    });

    test('a status change upserts the same document', () async {
      final client = FakeCosmosClient();
      final store = CosmosLateArrivalMirrorStore(client);

      await store.put(entry());
      await store.put(entry(status: LateArrivalStatus.confirmed));

      final docs = client.documentsIn(lateArrivalsContainer);
      expect(docs, hasLength(1), reason: 'upsert, not append');
      expect(docs.single['status'], 'confirmed');
    });

    test('two desks keep two documents despite one local record id', () async {
      final client = FakeCosmosClient();
      final store = CosmosLateArrivalMirrorStore(client);

      await store.put(entry(desk: 'onthaal-1'));
      await store.put(entry(desk: 'onthaal-2', uid: 'john.roe'));

      // The stand-in operator's fresh journal mints the same `2026-09-07-0001`;
      // if the desk were not in the key, her first scan would erase the dead
      // laptop's first student.
      expect(client.documentsIn(lateArrivalsContainer), hasLength(2));
    });

    test('reads back one day, from that day\'s partition only', () async {
      final client = FakeCosmosClient();
      final store = CosmosLateArrivalMirrorStore(client);
      await store.put(entry(desk: 'onthaal-1'));
      await store.put(entry(desk: 'onthaal-2', sequence: 1, uid: 'john.roe'));
      await store.put(entry(day: tuesdayDay));

      final read = await store.readDay(mondayDay);

      expect(
        read.map((e) => e.documentId).toList()..sort(),
        <String>['2026-09-07|onthaal-1|0001', '2026-09-07|onthaal-2|0001'],
      );
      expect(read.every((e) => e.day == mondayDay), isTrue);
    });

    test('a day nobody registered on reads as empty, not as an error',
        () async {
      final store = CosmosLateArrivalMirrorStore(FakeCosmosClient());
      expect(await store.readDay(mondayDay), isEmpty);
    });

    test('a damaged document costs one registration, not the recovery',
        () async {
      final client = FakeCosmosClient();
      final store = CosmosLateArrivalMirrorStore(client);
      await store.put(entry());
      await client.upsertDocument(
        container: lateArrivalsContainer,
        partitionKey: mondayDay.id,
        document: <String, dynamic>{
          'id': '2026-09-07|onthaal-9|9999',
          'pk': mondayDay.id,
          'desk': 'onthaal-9',
          'record': <String, dynamic>{'id': 'nonsense'},
        },
      );

      final read = await store.readDay(mondayDay);

      expect(read, hasLength(1));
      expect(read.single.deskId, 'onthaal-1');
    });
  });
}
