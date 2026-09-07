/// The on-disk half of the late-arrival journal (#402).
///
/// The pure package's tests prove the format and the recovery; this proves the
/// only thing they cannot — that a real file under `%APPDATA%` behaves the way
/// the seam promises, including the flushed append the ticket ordering rests on
/// and the torn tail a crash leaves behind.
library;

import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/late_arrivals/file_journal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;

void main() {
  late Directory dir;
  late FileJournalStore store;

  const SchoolDay monday = SchoolDay(2026, 9, 7);
  final DateTime mondayMorning = DateTime(2026, 9, 7, 8, 14);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('am-late-journal-test');
    store = FileJournalStore(
      Directory('${dir.path}${Platform.pathSeparator}late-arrivals'),
    );
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a desk that has registered nobody has an empty journal', () async {
    expect(await store.days(), isEmpty);
    expect(await store.read(monday), isEmpty);
    expect(store.directory.existsSync(), isFalse,
        reason: 'a read writes nothing');
  });

  test('append creates the directory and the day file', () async {
    await store.append(monday, '{"kind":"registration"}\n');

    final File file = File(
      '${store.directory.path}${Platform.pathSeparator}'
      '${journalFileName(monday)}',
    );
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), '{"kind":"registration"}\n');
    expect(store.locationOf(monday), file.path);
  });

  test('appends accumulate and days are listed ascending', () async {
    await store.append(const SchoolDay(2026, 9, 8), 'b\n');
    await store.append(monday, 'a1\n');
    await store.append(monday, 'a2\n');

    expect(
      await store.days(),
      <SchoolDay>[monday, const SchoolDay(2026, 9, 8)],
    );
    expect(await store.read(monday), 'a1\na2\n');
  });

  test('ignores a file that is not a journal file', () async {
    store.directory.createSync(recursive: true);
    File('${store.directory.path}${Platform.pathSeparator}README.txt')
        .writeAsStringSync('niet aankomen');

    expect(await store.days(), isEmpty);
  });

  test('delete removes a day, and a missing day is not an error', () async {
    await store.append(monday, 'a\n');
    await store.delete(monday);
    await store.delete(monday);

    expect(await store.days(), isEmpty);
  });

  test('a registration written here is readable by a fresh journal', () async {
    final LateArrivalJournal first =
        await LateArrivalJournal.open(store, now: mondayMorning);
    final LateArrivalRecord written = await first.register(
      scan: _registerable(),
      scannedAt: mondayMorning,
      reasonLabel: 'Bus te laat',
      reasonIsValid: true,
    );

    // A whole new process, over the same directory.
    final LateArrivalJournal second =
        await LateArrivalJournal.open(store, now: mondayMorning);

    expect(second.pending.single.id, written.id);
    expect(second.pending.single.motivation, '08:14 – Bus te laat');
    expect(second.recovery.isClean, isTrue);
  });

  test('a byte-level torn tail costs the line, not the day', () async {
    final LateArrivalJournal first =
        await LateArrivalJournal.open(store, now: mondayMorning);
    final LateArrivalRecord kept = await first.register(
      scan: _registerable(),
      scannedAt: mondayMorning,
      reasonLabel: 'Bus te laat',
      reasonIsValid: true,
    );

    // Truncate mid-line, and mid-UTF-8: the en dash of the motivation is a
    // three-byte sequence, so a cut inside it is exactly the malformed input a
    // strict decode would throw the whole day away over.
    final File file = File(
      '${store.directory.path}${Platform.pathSeparator}'
      '${journalFileName(monday)}',
    );
    final List<int> whole = file.readAsBytesSync();
    file.writeAsBytesSync(<int>[
      ...whole,
      // The head of a second line, chopped inside a multi-byte character.
      ...'{"kind":"registration","motivation":"08:20 –'.codeUnits.take(44),
      0xE2,
      0x80,
    ]);

    final LateArrivalJournal second =
        await LateArrivalJournal.open(store, now: mondayMorning);

    expect(
        second.records.map((LateArrivalRecord r) => r.id), <String>[kept.id]);
    expect(second.recovery.truncatedTails, 1);
  });
}

/// One registerable scan, resolved the way the desk resolves it (#401), so this
/// test exercises the journal through its real entry point rather than a
/// hand-built record.
ScanRegisterable _registerable() {
  final ScanResolver resolver = ScanResolver.fromSmartschool(
    ss.SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026, 9, 7),
      groups: <core.Group>[
        const core.Group(
          id: core.GroupId('SSM1A'),
          name: '1A',
          description: '',
          type: core.GroupType.classGroup,
          official: true,
          sourceId: 298,
          origin: core.Origin.smartschool,
        ),
      ],
      accounts: <ss.SmartschoolAccount>[
        const ss.SmartschoolAccount(
          uid: 'jane.doe',
          accountId: '123456',
          mail: 'jane.doe@example.org',
          registerId: '',
          stemId: 0,
          role: core.PersonRole.student,
          givenName: 'Jane',
          surname: 'Doe',
          extraNames: '',
          initials: '',
          preferredName: '',
          gender: core.Gender.female,
          birthDate: null,
          birthPlace: '',
          birthCountry: '',
          address: core.Address(
            street: '',
            houseNumber: '',
            postalCode: '',
            city: '',
            country: '',
          ),
          mobilePhone: '',
          homePhone: '',
          fax: '',
          untisId: '',
          status: 'actief',
          referenceIdentifier: '4069_12016_0',
        ),
      ],
      memberships: const <ss.SmartschoolMembership>[
        ss.SmartschoolMembership(
            uid: 'jane.doe', groupId: core.GroupId('SSM1A')),
      ],
    ),
  );
  return resolver.resolve('123456') as ScanRegisterable;
}
