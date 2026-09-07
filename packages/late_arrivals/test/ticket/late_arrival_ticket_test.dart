import 'dart:typed_data';

import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

/// Where [needle] starts in [haystack], or -1. The ticket is a byte stream, so
/// "the class is printed after the name" is an offset comparison.
int _indexOf(List<int> haystack, List<int> needle, [int from = 0]) {
  outer:
  for (int i = from; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

Matcher _containsBytes(List<int> needle) => predicate<List<int>>(
      (List<int> bytes) => _indexOf(bytes, needle) >= 0,
      'contains the bytes $needle',
    );

Uint8List _ticket({
  String name = 'Lotte Peeters',
  String className = '3STW',
  DateTime? at,
  TicketLogo? logo,
}) =>
    composeLateArrivalTicket(
      displayName: name,
      className: className,
      scannedAt: at ?? DateTime(2026, 9, 7, 8, 14),
      logo: logo,
    );

void main() {
  group('what the ticket says', () {
    test('carries the name, the class and the arrival time', () {
      final Uint8List bytes = _ticket();
      expect(bytes, _containsBytes(encodeCp1252('Lotte Peeters')));
      expect(bytes, _containsBytes(encodeCp1252('3STW')));
      expect(bytes, _containsBytes(encodeCp1252('08:14')));
    });

    test('prints the scan time, never the print time', () {
      // The whole point of the ticket: the teacher reads when the student was
      // at the desk, not when the printer got round to it.
      final DateTime scan = DateTime(2026, 9, 7, 8, 14);
      expect(_ticket(at: scan), _containsBytes(encodeCp1252('08:14')));
      expect(formatTicketTime(scan), '08:14');
      expect(formatTicketTime(DateTime(2026, 9, 7, 9, 3)), '09:03');
      expect(formatTicketTime(DateTime(2026, 9, 7, 13, 0)), '13:00');
    });

    test('quotes the same clock format the Smartschool motivation does', () {
      // Paper and Smartschool must never disagree about the minute.
      final DateTime scan = DateTime(2026, 9, 7, 8, 4);
      expect(
        composeMotivation(scan, 'Verkeer'),
        startsWith(formatTicketTime(scan)),
      );
    });

    test('carries nothing else — no reason, no barcode (#399)', () {
      // Deliberately out of scope: the reason is between the desk and
      // Smartschool, and putting it on paper the student carries to a teacher
      // is a different decision than the epic made.
      final Uint8List bytes = composeTicketForRecord(
        _record(reasonLabel: 'Verslapen'),
        logo: null,
      );
      expect(bytes, isNot(_containsBytes(encodeCp1252('Verslapen'))));
      // GS k — the barcode command — appears nowhere.
      expect(bytes, isNot(_containsBytes(<int>[gs, 0x6B])));
    });

    test('a student with no official class prints no blank gap', () {
      // `ScanIncomplete` (#401) can still be registered by hand; an empty tall
      // line in the middle of the ticket reads as a fault.
      final Uint8List bytes = _ticket(className: '   ');
      expect(bytes, _containsBytes(encodeCp1252('Lotte Peeters')));
      // Name, then straight on to the time.
      final int name = _indexOf(bytes, encodeCp1252('Lotte Peeters'));
      final int time = _indexOf(bytes, encodeCp1252('08:14'));
      expect(name, greaterThan(0));
      expect(time, greaterThan(name));
      // Exactly two printed lines, so exactly two line feeds before the
      // trailing feed-and-cut.
      expect(bytes.where((int b) => b == lf).length, 2);
    });

    test('prints an accented name in the code page it selected', () {
      final Uint8List bytes = _ticket(name: 'Noël Devrieze');
      expect(
          bytes, _containsBytes(escPosSelectCodePage(escPosCodePageWpc1252)));
      expect(bytes, _containsBytes(encodeCp1252('Noël Devrieze')));
      // …and not as UTF-8, which is what would print as "NoÃ«l".
      expect(bytes, isNot(_containsBytes(<int>[0xC3, 0xAB])));
    });
  });

  group('how the ticket is laid out', () {
    test('opens by resetting the printer and centring', () {
      final Uint8List bytes = _ticket();
      expect(bytes.sublist(0, 2), escPosInitialize());
      expect(
        bytes.sublist(2, 5),
        escPosSelectCodePage(escPosCodePageWpc1252),
      );
      expect(bytes.sublist(5, 8), escPosAlign(EscPosAlign.center));
    });

    test('ends by feeding the cutter clear and cutting', () {
      final Uint8List bytes = _ticket();
      final List<int> tail = <int>[
        ...escPosAlign(EscPosAlign.left),
        ...escPosFeedLines(ticketFeedLinesBeforeCut),
        ...escPosCut(),
      ];
      expect(bytes.sublist(bytes.length - tail.length), tail);
    });

    test('the arrival time is the biggest thing on the paper', () {
      // Bigger than the name, on purpose: the time is the evidence.
      expect(ticketTimeMagnification, greaterThan(ticketNameMagnification));
      expect(ticketNameMagnification,
          greaterThanOrEqualTo(ticketClassMagnification));

      final Uint8List bytes = _ticket();
      final int name = _indexOf(bytes, encodeCp1252('Lotte Peeters'));
      final int time = _indexOf(bytes, encodeCp1252('08:14'));
      expect(
        _indexOf(
          bytes,
          escPosCharacterSize(
            width: ticketNameMagnification,
            height: ticketNameMagnification,
          ),
        ),
        lessThan(name),
      );
      expect(
        _indexOf(
          bytes,
          escPosCharacterSize(
            width: ticketTimeMagnification,
            height: ticketTimeMagnification,
          ),
        ),
        allOf(greaterThan(name), lessThan(time)),
      );
    });

    test('every magnified line is followed by a reset to single size', () {
      // Otherwise the class would inherit the name's size — and, worse, so
      // would the next ticket on a printer that was left mid-job.
      final Uint8List bytes = _ticket();
      final List<int> normal = escPosCharacterSize();
      final int name = _indexOf(bytes, encodeCp1252('Lotte Peeters'));
      final int className = _indexOf(bytes, encodeCp1252('3STW'));
      expect(_indexOf(bytes, normal, name),
          allOf(greaterThan(name), lessThan(className)));
    });

    test('the name is emphasized and the emphasis is turned back off', () {
      final Uint8List bytes = _ticket();
      final int on = _indexOf(bytes, escPosEmphasis(on: true));
      final int name = _indexOf(bytes, encodeCp1252('Lotte Peeters'));
      final int off = _indexOf(bytes, escPosEmphasis(on: false), name);
      expect(on, allOf(greaterThan(0), lessThan(name)));
      expect(off, greaterThan(name));
    });
  });

  group('the logo', () {
    test('is printed as a raster image ahead of the name', () {
      final Uint8List bytes = _ticket(logo: defaultTicketLogo);
      final int raster = _indexOf(bytes, escPosRasterImage(defaultTicketLogo));
      final int name = _indexOf(bytes, encodeCp1252('Lotte Peeters'));
      expect(raster, greaterThan(0));
      expect(raster, lessThan(name));
    });

    test('is omitted entirely when the school has supplied none', () {
      // A ticket with no logo, not a ticket with a placeholder nobody chose.
      final Uint8List bytes = _ticket();
      expect(bytes, isNot(_containsBytes(<int>[gs, 0x76, 0x30])));
      expect(bytes, _containsBytes(encodeCp1252('Lotte Peeters')));
    });

    test('a logo too wide for the paper stops the ticket, loudly', () {
      final TicketLogo tooWide = TicketLogo.fromArt(
        <String>['#' * (ticketPrintWidthDots + 8)],
      );
      expect(() => _ticket(logo: tooWide), throwsArgumentError);
    });
  });

  group('composeTicketForRecord', () {
    test('takes the record the journal already flushed (#402)', () {
      final Uint8List bytes = composeTicketForRecord(
        _record(),
        logo: defaultTicketLogo,
      );
      expect(bytes, _containsBytes(encodeCp1252('Lotte Peeters')));
      expect(bytes, _containsBytes(encodeCp1252('3STW')));
      expect(bytes, _containsBytes(encodeCp1252('08:14')));
      expect(
        bytes,
        equals(
          composeLateArrivalTicket(
            displayName: 'Lotte Peeters',
            className: '3STW',
            scannedAt: DateTime(2026, 9, 7, 8, 14),
            logo: defaultTicketLogo,
          ),
        ),
      );
    });

    test('is byte-for-byte stable, so a redeploy cannot silently reflow it',
        () {
      expect(
        composeTicketForRecord(_record(), logo: null),
        composeTicketForRecord(_record(), logo: null),
      );
    });
  });
}

LateArrivalRecord _record({String reasonLabel = 'Verkeer'}) =>
    LateArrivalRecord(
      id: '2026-09-07-0003',
      day: SchoolDay.of(DateTime(2026, 9, 7)),
      sequence: 3,
      scannedAt: DateTime(2026, 9, 7, 8, 14),
      smartschoolUid: 'lotte.peeters',
      wisaId: '123456',
      displayName: 'Lotte Peeters',
      className: '3STW',
      internalUserId: 4711,
      classGroupId: 298,
      reasonLabel: reasonLabel,
      reasonIsValid: true,
      motivation: composeMotivation(DateTime(2026, 9, 7, 8, 14), reasonLabel),
      status: LateArrivalStatus.pending,
    );
