import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

void main() {
  group('TicketLogo.fromArt', () {
    test('packs a row most-significant-bit first and clears the tail', () {
      // 10 dots wide -> 2 bytes per row, 6 unused bits in the second.
      final TicketLogo logo = TicketLogo.fromArt(<String>['#......##.']);
      expect(logo.width, 10);
      expect(logo.height, 1);
      expect(logo.bytesPerRow, 2);
      // The leftmost dot is the high bit of the first byte, and the six bits
      // past the end of the row are clear rather than left as ink.
      expect(logo.bits, <int>[0x81, 0x80]);
      expect(logo.dotAt(0, 0), isTrue);
      expect(logo.dotAt(1, 0), isFalse);
      expect(logo.dotAt(7, 0), isTrue);
      expect(logo.dotAt(8, 0), isTrue);
      expect(logo.dotAt(9, 0), isFalse);
    });

    test('scale repeats every dot in both directions', () {
      final TicketLogo logo = TicketLogo.fromArt(<String>['#.'], scale: 3);
      expect(logo.width, 6);
      expect(logo.height, 3);
      for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
          expect(logo.dotAt(x, y), isTrue, reason: 'ink at $x,$y');
        }
        for (int x = 3; x < 6; x++) {
          expect(logo.dotAt(x, y), isFalse, reason: 'paper at $x,$y');
        }
      }
    });

    test('dotAt is false outside the bitmap rather than throwing', () {
      final TicketLogo logo = TicketLogo.fromArt(<String>['#']);
      expect(logo.dotAt(-1, 0), isFalse);
      expect(logo.dotAt(0, 9), isFalse);
    });

    test('a ragged or empty picture is a programming error', () {
      expect(() => TicketLogo.fromArt(<String>[]), throwsArgumentError);
      expect(() => TicketLogo.fromArt(<String>['']), throwsArgumentError);
      expect(
          () => TicketLogo.fromArt(<String>['##', '#']), throwsArgumentError);
      expect(
        () => TicketLogo.fromArt(<String>['#'], scale: 0),
        throwsArgumentError,
      );
    });
  });

  group('the shipped mark', () {
    test('is the art, scaled, and fits the loaded paper', () {
      expect(defaultTicketLogo.width, 24 * defaultTicketLogoScale);
      expect(defaultTicketLogo.height, 24 * defaultTicketLogoScale);
      expect(defaultTicketLogo.fitsPaper, isTrue);
      expect(defaultTicketLogo.width, lessThanOrEqualTo(ticketPrintWidthDots));

      // Every dot of the art survived the scaling, in place.
      for (int artY = 0; artY < defaultTicketLogoArt.length; artY++) {
        final String row = defaultTicketLogoArt[artY];
        for (int artX = 0; artX < row.length; artX++) {
          expect(
            defaultTicketLogo.dotAt(
              artX * defaultTicketLogoScale,
              artY * defaultTicketLogoScale,
            ),
            row[artX] == '#',
            reason: 'art cell $artX,$artY',
          );
        }
      }
    });

    test('is a square picture, which is what the art has to stay', () {
      expect(defaultTicketLogoArt, isNotEmpty);
      for (final String row in defaultTicketLogoArt) {
        expect(row.length, defaultTicketLogoArt.length);
      }
    });
  });
}
