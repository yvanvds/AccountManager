/// The handful of ESC/POS commands a late-arrival ticket needs (#406).
///
/// Small on purpose: this is not a printer library, it is the vocabulary of one
/// ticket. Each function returns the bytes for one command, so
/// `composeLateArrivalTicket` reads as the ticket does — align, size, text,
/// feed, cut — and every command can be asserted on in isolation.
///
/// The commands are the ones Epson documents for the TM-m30III. Nothing here
/// negotiates or asks the printer anything: raw ESC/POS over port 9100 is a
/// one-way byte stream, which is exactly why printing can be fire-and-forget.
library;

import 'dart:typed_data';

import 'ticket_logo.dart';
import 'ticket_metrics.dart';

/// `ESC` — the escape byte most commands start with.
const int esc = 0x1B;

/// `GS` — the group-separator byte the raster and cut commands start with.
const int gs = 0x1D;

/// Line feed. Ends every printed line.
const int lf = 0x0A;

/// The code page the printer is switched to: `WPC1252`, page 16 in Epson's
/// table.
///
/// Not the factory default (PC437), and the difference is not cosmetic here:
/// Flemish surnames carry é, ë, ï and ç, and on PC437 half of them come out as
/// a different letter. Selecting the page and encoding to match is what makes
/// "Noël" print as "Noël".
const int escPosCodePageWpc1252 = 16;

/// Horizontal alignment of everything printed after it.
enum EscPosAlign {
  left(0),
  center(1),
  right(2);

  const EscPosAlign(this.code);

  /// The `n` of `ESC a n`.
  final int code;
}

/// `ESC @` — reset the printer to its power-on settings.
///
/// First thing on every ticket. The connection is stateless but the *printer*
/// is not: a previous job that died mid-stream can leave it in double-width or
/// centred, and the next ticket would inherit it.
List<int> escPosInitialize() => <int>[esc, 0x40];

/// `ESC t n` — select the character code page.
List<int> escPosSelectCodePage(int page) => <int>[esc, 0x74, page];

/// `ESC a n` — set justification.
List<int> escPosAlign(EscPosAlign align) => <int>[esc, 0x61, align.code];

/// `GS ! n` — set character magnification, 1–8 in each direction.
///
/// The one command that carries the ticket's hierarchy: the arrival time is
/// printed bigger than the name because the time is what the ticket exists to
/// prove.
List<int> escPosCharacterSize({int width = 1, int height = 1}) {
  RangeError.checkValueInInterval(width, 1, 8, 'width');
  RangeError.checkValueInInterval(height, 1, 8, 'height');
  return <int>[gs, 0x21, ((width - 1) << 4) | (height - 1)];
}

/// `ESC E n` — emphasized (bold) on or off.
List<int> escPosEmphasis({required bool on}) =>
    <int>[esc, 0x45, on ? 0x01 : 0x00];

/// `ESC d n` — print the buffer and feed [lines] blank lines.
List<int> escPosFeedLines(int lines) {
  RangeError.checkValueInInterval(lines, 0, 255, 'lines');
  return <int>[esc, 0x64, lines];
}

/// `GS V 66 n` — feed [feedDots] and partial-cut the paper.
///
/// Function B rather than the bare one-byte cut: the cutter sits below the
/// print head, so a cut with no feed of its own leaves the last line of the
/// ticket on the *next* one. See [ticketCutCommandVariant] for the dials.
List<int> escPosCut({int feedDots = ticketCutFeedDots}) {
  RangeError.checkValueInInterval(feedDots, 0, 255, 'feedDots');
  return <int>[gs, 0x56, ticketCutCommandVariant, feedDots];
}

/// `GS v 0 m xL xH yL yH d1...dk` — print [logo] as a raster bit image.
///
/// Raster mode rather than the older column mode: the data is the bitmap in
/// reading order, which is what [TicketLogo] already holds, so nothing has to
/// be transposed at print time.
List<int> escPosRasterImage(TicketLogo logo) {
  if (!logo.fitsPaper) {
    throw ArgumentError.value(
      logo,
      'logo',
      'is wider than the $ticketPrintWidthDots-dot print area; the printer '
          'would clip it rather than scale it',
    );
  }
  final int xBytes = logo.bytesPerRow;
  return <int>[
    gs, 0x76, 0x30,
    0x00, // m = 0: normal size, no doubling
    xBytes & 0xFF, (xBytes >> 8) & 0xFF,
    logo.height & 0xFF, (logo.height >> 8) & 0xFF,
    ...logo.bits,
  ];
}

/// Encodes [text] for a printer switched to [escPosCodePageWpc1252].
///
/// Anything the page cannot represent becomes `?` rather than throwing or being
/// dropped: a name with a character the printer has no glyph for still has to
/// produce a ticket, because the student is standing at the desk and the
/// registration has already been journalled.
Uint8List encodeCp1252(String text) {
  final BytesBuilder out = BytesBuilder(copy: false);
  for (final int rune in text.runes) {
    if (rune < 0x80 || (rune >= 0xA0 && rune <= 0xFF)) {
      out.addByte(rune);
      continue;
    }
    final int? mapped = _cp1252High[rune];
    out.addByte(mapped ?? 0x3F);
  }
  return out.toBytes();
}

/// The 27 characters CP1252 puts in the 0x80–0x9F range that Latin-1 leaves
/// undefined — typographic quotes and dashes, mostly, which is what arrives
/// when a name is pasted out of a word processor.
const Map<int, int> _cp1252High = <int, int>{
  0x20AC: 0x80, // €
  0x201A: 0x82, // ‚
  0x0192: 0x83, // ƒ
  0x201E: 0x84, // „
  0x2026: 0x85, // …
  0x2020: 0x86, // †
  0x2021: 0x87, // ‡
  0x02C6: 0x88, // ˆ
  0x2030: 0x89, // ‰
  0x0160: 0x8A, // Š
  0x2039: 0x8B, // ‹
  0x0152: 0x8C, // Œ
  0x017D: 0x8E, // Ž
  0x2018: 0x91, // '
  0x2019: 0x92, // '
  0x201C: 0x93, // "
  0x201D: 0x94, // "
  0x2022: 0x95, // •
  0x2013: 0x96, // –
  0x2014: 0x97, // —
  0x02DC: 0x98, // ˜
  0x2122: 0x99, // ™
  0x0161: 0x9A, // š
  0x203A: 0x9B, // ›
  0x0153: 0x9C, // œ
  0x017E: 0x9E, // ž
  0x0178: 0x9F, // Ÿ
};
