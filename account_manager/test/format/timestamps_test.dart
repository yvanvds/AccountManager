import 'package:account_manager/src/format/timestamps.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the freshness stamp (#192) against a fixed clock. Time-only used to
/// make a sync from days ago read exactly like this morning's, which is the one
/// case the Reconcile last-sync box exists to surface.
void main() {
  // A fixed "now" so every expectation below is deterministic.
  final DateTime now = DateTime(2026, 8, 18, 17, 30);

  test('a stamp from today renders time-only', () {
    expect(
      formatFreshnessStamp(DateTime(2026, 8, 18, 9, 14), now: now),
      '09:14',
    );
  });

  test('today stays time-only even when the stamp is later than now', () {
    expect(
      formatFreshnessStamp(DateTime(2026, 8, 18, 23, 50), now: now),
      '23:50',
    );
  });

  test('the hour and minute are zero-padded', () {
    expect(
      formatFreshnessStamp(DateTime(2026, 8, 18, 5, 3), now: now),
      '05:03',
    );
  });

  test("a stamp from yesterday is labelled 'gisteren'", () {
    expect(
      formatFreshnessStamp(DateTime(2026, 8, 17, 9, 14), now: now),
      'gisteren 09:14',
    );
  });

  test('yesterday is a calendar day, not 24 elapsed hours', () {
    // Twenty minutes apart, but either side of midnight: to the operator that
    // is yesterday, and reading it as "23:50" would be the exact confusion
    // #192 fixes.
    expect(
      formatFreshnessStamp(
        DateTime(2026, 8, 17, 23, 50),
        now: DateTime(2026, 8, 18, 0, 10),
      ),
      'gisteren 23:50',
    );
  });

  test('yesterday works across a month boundary', () {
    expect(
      formatFreshnessStamp(
        DateTime(2026, 7, 31, 23, 0),
        now: DateTime(2026, 8, 1, 8, 0),
      ),
      'gisteren 23:00',
    );
  });

  test('yesterday works across a year boundary', () {
    expect(
      formatFreshnessStamp(
        DateTime(2025, 12, 31, 23, 0),
        now: DateTime(2026, 1, 1, 8, 0),
      ),
      'gisteren 23:00',
    );
  });

  test('an older stamp in the current year renders day/month', () {
    expect(
      formatFreshnessStamp(DateTime(2026, 8, 15, 9, 14), now: now),
      '15/08 09:14',
    );
  });

  test('two days ago is already dated, never bare time', () {
    final String s =
        formatFreshnessStamp(DateTime(2026, 8, 16, 9, 14), now: now);
    expect(s, '16/08 09:14');
    expect(s, isNot('09:14'));
  });

  test('a stamp from an earlier year carries the year', () {
    expect(
      formatFreshnessStamp(DateTime(2025, 8, 15, 9, 14), now: now),
      '15/08/2025 09:14',
    );
  });

  test('the day and month are zero-padded on a dated stamp', () {
    expect(
      formatFreshnessStamp(DateTime(2026, 1, 5, 9, 14), now: now),
      '05/01 09:14',
    );
  });

  test('a UTC stamp is bucketed against the local calendar day', () {
    // The store hands back UTC instants; the operator reads their own clock.
    final DateTime local = DateTime(2026, 8, 18, 9, 14);
    expect(formatFreshnessStamp(local.toUtc(), now: local), '09:14');
    expect(
        formatFreshnessStamp(local.toUtc(), now: local), isNot(contains('/')));
  });

  test('now defaults to the current clock', () {
    final DateTime today = DateTime.now();
    expect(formatFreshnessStamp(today), isNot(contains('/')));
    expect(formatFreshnessStamp(today), isNot(contains('gisteren')));
    expect(
      formatFreshnessStamp(DateTime(today.year - 1, 8, 15, 9, 14)),
      '15/08/${today.year - 1} 09:14',
    );
  });

  group('formatRuleStamp — when a standing decision was made (#285)', () {
    test('is absolute and carries the year, even for today', () {
      // The counterpart of the freshness stamp, and deliberately not the same
      // shape: a rule's stamp is read months later by whoever inherited the
      // configuration, and with no reason field on the record the full date is
      // what lets them reconstruct the context.
      expect(formatRuleStamp(DateTime(2026, 6, 30, 14, 5)), '30/06/2026 14:05');
    });

    test('never says "gisteren"', () {
      final DateTime yesterday =
          DateTime.now().subtract(const Duration(days: 1));
      expect(formatRuleStamp(yesterday), isNot(contains('gisteren')));
    });

    test('zero-pads day, month, hour and minute', () {
      expect(formatRuleStamp(DateTime(2026, 1, 5, 9, 3)), '05/01/2026 09:03');
    });

    test('renders a UTC stamp on the operator\'s own clock', () {
      // The document stores UTC; nobody reads their rules in UTC.
      final DateTime local = DateTime(2026, 6, 30, 14, 5);
      expect(formatRuleStamp(local.toUtc()), '30/06/2026 14:05');
    });
  });
}
