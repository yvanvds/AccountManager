/// Everything about the late-arrival ticket that is a property of the *paper
/// and the printer* rather than of the layout (#406).
///
/// Collected in one file on purpose. The Epson TM-m30III has not been connected
/// yet, so every value here is the documented default for the model rather than
/// something anybody has watched come out of a cutter. When the printer is
/// plugged in, this file is the whole of what may need to move — the composer,
/// the transport and the tests all read these names.
///
/// What to check against the real device, in the order it will show up:
///
/// 1. [ticketPaperWidthMm] / [ticketPrintWidthDots] — 80 mm roll, 72 mm print
///    area, 203 dpi. A TM-m30III fitted with the 58 mm spacer prints 360 dots
///    wide instead, and the logo would then have to shrink to match.
/// 2. [ticketCutCommandVariant] — the model documents both the one-byte
///    `GS V m` cut and the Function B `GS V 66 n` feed-and-cut. The latter is
///    used because a bare cut leaves the last printed line inside the cutter;
///    if the ticket comes out short, this and [ticketFeedLinesBeforeCut] are
///    the two dials.
/// 3. `defaultTicketLogoScale` — whether ~15 mm of monogram is "small".
library;

/// The raw-printing TCP port every ESC/POS network printer listens on. Not
/// configurable: it is what "raw" means, and a TM-m30III does not move it.
const int escPosRawPort = 9100;

/// The paper roll the printer is loaded with.
const int ticketPaperWidthMm = 80;

/// The printable width of that roll, in dots at the model's 203 dpi.
///
/// 72 mm of the 80 mm roll is printable, which is 576 dots. Nothing may be
/// composed wider — the printer silently drops the overflow rather than
/// wrapping, which on a ticket looks like a truncated name.
const int ticketPrintWidthDots = 576;

/// Blank lines fed after the last printed line and before the cut, so the text
/// clears the cutter — which sits below the print head.
const int ticketFeedLinesBeforeCut = 4;

/// Extra paper, in dots, the cut command itself feeds. Zero because
/// [ticketFeedLinesBeforeCut] already did it; raising this is the alternative
/// dial if the ticket still comes out short.
const int ticketCutFeedDots = 0;

/// Which documented cut command the ticket ends with, named so the choice is
/// visible rather than buried in a byte. `66` is ESC/POS "Function B"
/// (`GS V 66 n`): feed [ticketCutFeedDots] and partial-cut.
const int ticketCutCommandVariant = 66;
