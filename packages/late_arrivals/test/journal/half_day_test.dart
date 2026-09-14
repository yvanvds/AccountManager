/// Which Smartschool half-day a scan is written to (#428).
library;

import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

void main() {
  group('HalfDay', () {
    test('a scan before noon is the morning', () {
      expect(HalfDay.of(DateTime(2026, 9, 7, 0, 0)), HalfDay.morning);
      expect(HalfDay.of(DateTime(2026, 9, 7, 8, 14)), HalfDay.morning);
      expect(HalfDay.of(DateTime(2026, 9, 7, 11, 59, 59)), HalfDay.morning);
    });

    test('a scan from noon onwards is the afternoon', () {
      // 12:00 sharp is already the afternoon: the cutoff is the hour, and the
      // lunch break belongs to the half-day the student is about to be late for.
      expect(HalfDay.of(DateTime(2026, 9, 7, 12, 0)), HalfDay.afternoon);
      expect(HalfDay.of(DateTime(2026, 9, 7, 12, 30)), HalfDay.afternoon);
      expect(HalfDay.of(DateTime(2026, 9, 7, 15, 45)), HalfDay.afternoon);
      expect(HalfDay.of(DateTime(2026, 9, 7, 23, 59)), HalfDay.afternoon);
    });

    test('reads the moment in its own zone', () {
      // The hour is taken as the DateTime carries it — no conversion to local
      // or to UTC on the way — so the operator's wall clock is what decides,
      // exactly as `SchoolDay.of` reads the day.
      expect(HalfDay.of(DateTime(2026, 9, 7, 11, 30)), HalfDay.morning);
      expect(HalfDay.of(DateTime.utc(2026, 9, 7, 11, 30)), HalfDay.morning);
      expect(HalfDay.of(DateTime.utc(2026, 9, 7, 13, 30)), HalfDay.afternoon);
    });

    test('the cutoff is noon', () {
      expect(HalfDay.noonHour, 12);
    });
  });
}
