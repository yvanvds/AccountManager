/// The shared document shape (#403).
///
/// One property carries the feature and it is the one the local journal cannot
/// provide: a globally unique identity. The journal's `<day>-<sequence>` is
/// unique on the machine that wrote it, and a stand-in operator's fresh journal
/// mints exactly the same ids — so if the desk were not part of the shared key,
/// the very takeover this feature exists for would overwrite the dead laptop's
/// morning.
library;

import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

void main() {
  final DateTime monday = DateTime(2026, 9, 7, 8, 14, 33);
  final SchoolDay mondayDay = SchoolDay.of(monday);

  LateArrivalRecord recordOf({
    int sequence = 3,
    LateArrivalStatus status = LateArrivalStatus.pending,
    String uid = 'jane.doe',
  }) =>
      LateArrivalRecord(
        id: '${mondayDay.id}-${sequence.toString().padLeft(4, '0')}',
        day: mondayDay,
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

  MirroredRegistration mirrored({
    String desk = 'onthaal-1',
    int sequence = 3,
    LateArrivalStatus status = LateArrivalStatus.pending,
  }) =>
      MirroredRegistration(
        deskId: desk,
        record: recordOf(sequence: sequence, status: status),
        mirroredAt: monday.add(const Duration(milliseconds: 120)),
      );

  group('MirroredRegistration', () {
    test('partitions by the school day, so a day is one partition read', () {
      expect(mirrored().partitionKey, '2026-09-07');
      expect(mirrored().toDocument()['pk'], '2026-09-07');
    });

    test('two desks with the same local record id get two documents', () {
      final MirroredRegistration deskA = mirrored(desk: 'onthaal-1');
      final MirroredRegistration deskB = mirrored(desk: 'onthaal-2');

      // The journal ids collide — that is precisely the hazard.
      expect(deskA.record.id, deskB.record.id);
      expect(deskA.documentId, isNot(deskB.documentId));
      expect(deskA.documentId, '2026-09-07|onthaal-1|0003');
      expect(deskB.documentId, '2026-09-07|onthaal-2|0003');
    });

    test('a status change rewrites the same document, never a second one', () {
      final MirroredRegistration first = mirrored();
      final MirroredRegistration later =
          mirrored(status: LateArrivalStatus.confirmed);

      expect(later.documentId, first.documentId);
      expect(later.toDocument()['status'], 'confirmed');
    });

    test('round-trips through the document shape', () {
      final MirroredRegistration entry =
          mirrored(status: LateArrivalStatus.sent);

      final MirroredRegistration? back =
          MirroredRegistration.tryFromDocument(entry.toDocument());

      expect(back, isNotNull);
      expect(back!.deskId, 'onthaal-1');
      expect(back.record.id, entry.record.id);
      expect(back.record.status, LateArrivalStatus.sent);
      expect(back.record.motivation, '08:14 – Bus te laat');
      expect(back.record.internalUserId, 12016);
      expect(back.record.classGroupId, 298);
      expect(back.mirroredAt, entry.mirroredAt);
    });

    test('a damaged document reads as null rather than throwing', () {
      // One unreadable document must cost one registration, not the whole
      // recovery — the same discipline the journal replay follows.
      expect(
        MirroredRegistration.tryFromDocument(<String, Object?>{'id': 'x'}),
        isNull,
      );
      expect(
        MirroredRegistration.tryFromDocument(<String, Object?>{
          'desk': 'onthaal-1',
          'record': <String, Object?>{'id': 'nonsense'},
        }),
        isNull,
      );
    });

    test('a document written without a mirroredAt stamp still reads back', () {
      final Map<String, Object?> doc = mirrored().toDocument()
        ..remove('mirroredAt');

      final MirroredRegistration? back =
          MirroredRegistration.tryFromDocument(doc);

      expect(back, isNotNull);
      expect(back!.mirroredAt, monday, reason: 'falls back to the scan time');
    });
  });

  group('normalizeDeskId', () {
    test('folds a hostname into something a document id may carry', () {
      expect(normalizeDeskId('ONTHAAL-PC01'), 'onthaal-pc01');
      expect(normalizeDeskId('  balie 2  '), 'balie-2');
      // A Cosmos id may not contain / \ ? or #.
      expect(normalizeDeskId(r'DOMEIN\balie#2'), 'domein-balie-2');
    });

    test('a nameless machine still mirrors, under a placeholder', () {
      expect(normalizeDeskId(''), 'onbekend');
      expect(normalizeDeskId('///'), 'onbekend');
    });
  });
}
