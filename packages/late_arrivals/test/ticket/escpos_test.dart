import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

void main() {
  group('commands', () {
    test('initialize, code page and alignment are the documented bytes', () {
      expect(escPosInitialize(), <int>[0x1B, 0x40]);
      expect(
        escPosSelectCodePage(escPosCodePageWpc1252),
        <int>[0x1B, 0x74, 16],
      );
      expect(escPosAlign(EscPosAlign.center), <int>[0x1B, 0x61, 1]);
      expect(escPosAlign(EscPosAlign.left), <int>[0x1B, 0x61, 0]);
    });

    test('character size packs width in the high nibble, height in the low',
        () {
      expect(escPosCharacterSize(), <int>[0x1D, 0x21, 0x00]);
      expect(escPosCharacterSize(width: 2, height: 2), <int>[0x1D, 0x21, 0x11]);
      expect(escPosCharacterSize(width: 3, height: 3), <int>[0x1D, 0x21, 0x22]);
      expect(escPosCharacterSize(width: 1, height: 8), <int>[0x1D, 0x21, 0x07]);
      expect(escPosCharacterSize(width: 8, height: 1), <int>[0x1D, 0x21, 0x70]);
    });

    test('a magnification the printer has no room for is refused', () {
      expect(() => escPosCharacterSize(width: 0), throwsRangeError);
      expect(() => escPosCharacterSize(height: 9), throwsRangeError);
    });

    test('emphasis and feed', () {
      expect(escPosEmphasis(on: true), <int>[0x1B, 0x45, 0x01]);
      expect(escPosEmphasis(on: false), <int>[0x1B, 0x45, 0x00]);
      expect(escPosFeedLines(4), <int>[0x1B, 0x64, 4]);
    });

    test('the cut is Function B, feed-and-partial-cut', () {
      expect(escPosCut(), <int>[0x1D, 0x56, ticketCutCommandVariant, 0]);
      expect(ticketCutCommandVariant, 66);
      expect(escPosCut(feedDots: 80), <int>[0x1D, 0x56, 66, 80]);
    });
  });

  group('raster image', () {
    test('carries the width in bytes and the height in dots, little-endian',
        () {
      // 300 dots wide -> 38 bytes per row; 260 rows exercises both size bytes.
      final TicketLogo logo = TicketLogo.fromArt(
        List<String>.filled(26, '.' * 30),
        scale: 10,
      );
      final List<int> bytes = escPosRasterImage(logo);
      expect(bytes.sublist(0, 4), <int>[0x1D, 0x76, 0x30, 0x00]);
      expect(bytes[4], 38); // xL
      expect(bytes[5], 0); // xH
      expect(bytes[6], 260 & 0xFF); // yL
      expect(bytes[7], 260 >> 8); // yH
      expect(bytes.length, 8 + 38 * 260);
    });

    test('emits the packed bitmap verbatim, in reading order', () {
      final TicketLogo logo =
          TicketLogo.fromArt(<String>['#.......', '.......#']);
      expect(escPosRasterImage(logo), <int>[
        0x1D, 0x76, 0x30, 0x00, //
        1, 0, 2, 0, //
        0x80, 0x01,
      ]);
    });

    test('a logo wider than the paper is refused rather than clipped', () {
      // The printer drops the overflow silently; on a ticket that looks like a
      // truncated logo nobody can explain.
      final TicketLogo tooWide = TicketLogo.fromArt(
        <String>['#' * (ticketPrintWidthDots + 1)],
      );
      expect(tooWide.fitsPaper, isFalse);
      expect(() => escPosRasterImage(tooWide), throwsArgumentError);
    });
  });

  group('encodeCp1252', () {
    test('passes ASCII through', () {
      expect(encodeCp1252('1A'), <int>[0x31, 0x41]);
      expect(encodeCp1252('08:14'), '08:14'.codeUnits);
    });

    test('encodes the accents Flemish names actually carry', () {
      // The reason the printer is switched off PC437 at all.
      expect(encodeCp1252('Noël'), <int>[0x4E, 0x6F, 0xEB, 0x6C]);
      expect(encodeCp1252('Désiré'), <int>[0x44, 0xE9, 0x73, 0x69, 0x72, 0xE9]);
      expect(encodeCp1252('François'),
          <int>[0x46, 0x72, 0x61, 0x6E, 0xE7, 0x6F, 0x69, 0x73]);
    });

    test('maps the CP1252-only punctuation Latin-1 has no room for', () {
      expect(encodeCp1252('’'), <int>[0x92]); // curly apostrophe
      expect(encodeCp1252('–'), <int>[0x96]); // en dash
      expect(encodeCp1252('€'), <int>[0x80]); // euro
    });

    test('substitutes rather than throwing on a character with no glyph', () {
      // The registration is already on disk by the time this runs: a name the
      // code page cannot spell must still produce a ticket.
      expect(encodeCp1252('Zoë 京'), <int>[0x5A, 0x6F, 0xEB, 0x20, 0x3F]);
      expect(encodeCp1252('a\u{1F600}b'), <int>[0x61, 0x3F, 0x62]);
    });
  });
}
