import 'dart:typed_data';

import '../journal/late_arrival_record.dart';
import 'escpos.dart';
import 'ticket_metrics.dart';

/// The ticket the student carries to class (#406), as the bytes an Epson
/// TM-m30III turns into paper.
///
/// **A pure function, and that is the design.** The printer lives at a
/// reception desk and not on a build agent, so the layout has to be assertable
/// without it. Everything that touches a socket lives in `account_manager`;
/// everything that decides what the paper says lives here and is covered by
/// tests that read the byte stream back.
///
/// What is on it, and nothing else (the epic is explicit that the reason is
/// **not**, and neither is a barcode):
///
/// - the school's **header** — a few characters the desk configured, largest
///   of all, at the top (#429);
/// - the student's name, large and bold;
/// - the class;
/// - the **date** of the scan, weekday and all (#430);
/// - the **registration time** — the moment of the scan, bigger than the name.
///
/// The time is the point of the whole ticket. It is the teacher's evidence of
/// *when* the student was at the desk, so it is clear whether they came
/// straight to class or spent another twenty minutes getting there — and it is
/// the one thing Smartschool cannot hold, because its Presence module only
/// knows am/pm half-days (#399). The date is what makes that evidence stand a
/// week later, when the ticket turns up in a bag.
///
/// [scannedAt] is read in its own zone: the operator's wall clock is what the
/// student and the teacher read, exactly as `composeMotivation` reads it.
///
/// [header] is the mark at the top: the school's code, as the desk has it
/// configured. Empty prints no top line at all — which is what a desk that has
/// not set one should get rather than a placeholder nobody chose. Longer than
/// [ticketHeaderMaxLength] throws: the printer would clip it rather than wrap
/// it, and a clipped header is a fault nobody can explain from the paper.
Uint8List composeLateArrivalTicket({
  required String displayName,
  required String className,
  required DateTime scannedAt,
  required String header,
}) {
  final String mark = header.trim();
  if (mark.length > ticketHeaderMaxLength) {
    throw ArgumentError.value(
      header,
      'header',
      'is longer than the $ticketHeaderMaxLength characters that fit the '
          '$ticketPrintWidthDots-dot print area at magnification '
          '$ticketHeaderMagnification; the printer would clip it',
    );
  }

  final BytesBuilder out = BytesBuilder(copy: false);

  // Reset first: the socket is stateless, the printer is not.
  out.add(escPosInitialize());
  out.add(escPosSelectCodePage(escPosCodePageWpc1252));
  out.add(escPosAlign(EscPosAlign.center));

  if (mark.isNotEmpty) {
    _line(
      out,
      mark,
      width: ticketHeaderMagnification,
      height: ticketHeaderMagnification,
      bold: true,
    );
    out.add(escPosFeedLines(1));
  }

  _line(
    out,
    displayName,
    width: ticketNameMagnification,
    height: ticketNameMagnification,
    bold: true,
  );
  _line(
    out,
    className,
    width: ticketClassMagnification,
    height: ticketClassMagnification,
  );
  out.add(escPosFeedLines(1));
  _line(
    out,
    formatTicketDate(scannedAt),
    width: ticketDateMagnification,
    height: ticketDateMagnification,
  );
  _line(
    out,
    formatTicketTime(scannedAt),
    width: ticketTimeMagnification,
    height: ticketTimeMagnification,
    bold: true,
  );

  // Leave the printer as it was found, then clear the cutter and cut.
  out.add(escPosAlign(EscPosAlign.left));
  out.add(escPosFeedLines(ticketFeedLinesBeforeCut));
  out.add(escPosCut());
  return out.toBytes();
}

/// The ticket for a journalled registration (#402) — the entry point the scan
/// tab (#407) prints from.
///
/// Takes the record rather than the scan result on purpose: by the time a
/// ticket may print, the registration is already flushed to disk, and the
/// record is what says so. It also carries the scan time, so the ticket cannot
/// drift onto the print time however long the printer took to answer.
Uint8List composeTicketForRecord(
  LateArrivalRecord record, {
  required String header,
}) =>
    composeLateArrivalTicket(
      displayName: record.displayName,
      className: record.className,
      scannedAt: record.scannedAt,
      header: header,
    );

/// The arrival time as the ticket prints it: `HH:mm`, the same clock format the
/// motivation quotes, so the paper and Smartschool never disagree.
String formatTicketTime(DateTime scannedAt) {
  final String hour = scannedAt.hour.toString().padLeft(2, '0');
  final String minute = scannedAt.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// The scan date as the ticket prints it: the Dutch weekday in full and the
/// day-first numeric date the school writes everywhere else, e.g.
/// `vrijdag 11/09/2026` (#430).
///
/// The weekday is not decoration. A teacher reading "11/09" has to work out
/// what day that was; "vrijdag" they remember.
String formatTicketDate(DateTime scannedAt) {
  final String day = scannedAt.day.toString().padLeft(2, '0');
  final String month = scannedAt.month.toString().padLeft(2, '0');
  final String year = scannedAt.year.toString().padLeft(4, '0');
  return '${ticketWeekdayNames[scannedAt.weekday - 1]} $day/$month/$year';
}

/// Dutch weekday names, indexed by `DateTime.weekday - 1` (Monday first).
///
/// A table rather than `intl`: this package is pure Dart with no locale data,
/// and there are seven of them.
const List<String> ticketWeekdayNames = <String>[
  'maandag',
  'dinsdag',
  'woensdag',
  'donderdag',
  'vrijdag',
  'zaterdag',
  'zondag',
];

/// Character magnification for the header — the school's mark, and the
/// largest thing on the paper so the ticket is recognisable from across a
/// classroom. At Font A's 24-dot height this prints ~15 mm tall.
const int ticketHeaderMagnification = 5;

/// How many characters of header fit the print area at
/// [ticketHeaderMagnification] — 9 on the 80 mm roll. The composer refuses a
/// longer one and the settings field cannot enter one, so the two agree by
/// construction rather than by convention.
const int ticketHeaderMaxLength =
    ticketPrintWidthDots ~/ (ticketFontWidthDots * ticketHeaderMagnification);

/// Character magnification for the student's name.
const int ticketNameMagnification = 2;

/// …for the class, one step down: it identifies, it does not have to carry.
const int ticketClassMagnification = 2;

/// …for the date: legible, but under the time it belongs to.
const int ticketDateMagnification = 2;

/// …and for the arrival time, the largest thing on the ticket after the
/// header. See the class doc for why the time and not the name.
const int ticketTimeMagnification = 3;

/// Prints one centred line at the requested magnification and returns the
/// printer to plain single-size text, so no line can inherit the previous
/// one's size.
///
/// An empty value prints nothing at all rather than an empty tall line — a
/// student with no official class (`ScanIncomplete`, #401) can still be
/// registered by hand, and a blank gap on the ticket reads as a fault.
void _line(
  BytesBuilder out,
  String text, {
  required int width,
  required int height,
  bool bold = false,
}) {
  final String value = text.trim();
  if (value.isEmpty) return;
  out.add(escPosCharacterSize(width: width, height: height));
  if (bold) out.add(escPosEmphasis(on: true));
  out.add(encodeCp1252(value));
  out.addByte(lf);
  if (bold) out.add(escPosEmphasis(on: false));
  out.add(escPosCharacterSize());
}
