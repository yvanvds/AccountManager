/// The journal's day partition and the pinned motivation format (#402).
library;

import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

void main() {
  group('SchoolDay', () {
    test('takes the day a moment falls on in its own zone', () {
      // 00:30 local is still that day, which is the whole reason this is not a
      // UTC conversion.
      expect(SchoolDay.of(DateTime(2026, 9, 7, 0, 30)),
          const SchoolDay(2026, 9, 7));
      expect(SchoolDay.of(DateTime(2026, 9, 7, 23, 45)),
          const SchoolDay(2026, 9, 7));
    });

    test('round-trips through its id', () {
      const SchoolDay day = SchoolDay(2026, 1, 5);
      expect(day.id, '2026-01-05');
      expect(SchoolDay.tryParse(day.id), day);
    });

    test('refuses anything that is not a real YYYY-MM-DD', () {
      for (final String bad in <String>[
        '',
        '2026-9-7',
        '2026/09/07',
        '2026-13-01',
        '2026-02-30',
        'late-arrivals',
      ]) {
        expect(SchoolDay.tryParse(bad), isNull, reason: bad);
      }
    });

    test('counts whole days across a daylight-saving boundary', () {
      // Europe/Brussels moves the clock on 25 Oct 2026; the answer is still 2.
      expect(
        const SchoolDay(2026, 10, 24).daysBefore(const SchoolDay(2026, 10, 26)),
        2,
      );
      expect(
        const SchoolDay(2026, 10, 26).daysBefore(const SchoolDay(2026, 10, 24)),
        -2,
      );
    });

    test('orders chronologically', () {
      final List<SchoolDay> days = <SchoolDay>[
        const SchoolDay(2026, 9, 7),
        const SchoolDay(2025, 12, 31),
        const SchoolDay(2026, 1, 1),
      ]..sort((SchoolDay a, SchoolDay b) => a.compareTo(b));

      expect(
        days.map((SchoolDay d) => d.id),
        <String>['2025-12-31', '2026-01-01', '2026-09-07'],
      );
    });
  });

  group('journal file names', () {
    test('round-trip', () {
      const SchoolDay day = SchoolDay(2026, 9, 7);
      expect(journalFileName(day), 'late-arrivals-2026-09-07.jsonl');
      expect(schoolDayOfJournalFile(journalFileName(day)), day);
    });

    test('a stray file in the directory is not a journal file', () {
      for (final String name in <String>[
        'README.md',
        'late-arrivals.jsonl',
        'late-arrivals-2026-09-07.jsonl.bak',
        'preferences.json',
      ]) {
        expect(schoolDayOfJournalFile(name), isNull, reason: name);
      }
    });
  });

  group('composeMotivation', () {
    test('is HH:mm – reden, zero-padded', () {
      expect(
        composeMotivation(DateTime(2026, 9, 7, 8, 4), 'Bus te laat'),
        '08:04 – Bus te laat',
      );
    });

    test('keeps the format for the invalid reason too', () {
      expect(
        composeMotivation(DateTime(2026, 9, 7, 9, 15), 'zonder geldige reden'),
        '09:15 – zonder geldige reden',
      );
    });

    test('drops the separator when there is no reason at all', () {
      expect(composeMotivation(DateTime(2026, 9, 7, 9, 15), '   '), '09:15');
    });
  });
}
