import 'dart:typed_data';

import 'ticket_metrics.dart';

/// A monochrome bitmap for the ticket header (#406).
///
/// One bit per dot, packed the way ESC/POS raster mode wants it: rows of
/// `ceil(width / 8)` bytes, most significant bit leftmost, a set bit meaning
/// "put ink here". Trailing bits in the last byte of a row are clear.
///
/// Held as data rather than as an image file on purpose. This package is pure
/// Dart with no I/O and no Flutter, so it cannot open a PNG, and the printer
/// wants a bitmap anyway — decoding one at print time would put an image
/// library on the path of the one operation that has to be fire-and-forget.
final class TicketLogo {
  const TicketLogo._(this.width, this.height, this.bits);

  /// Builds a logo from ASCII art: one string per row, [ink] where a dot is
  /// printed and anything else where it is not.
  ///
  /// Art rather than packed bytes because this is the one part of the ticket
  /// nobody can check without the printer, and a reviewer can read a picture.
  /// [scale] repeats every dot in both directions, so the art stays small
  /// enough to edit by hand while the printed mark stays big enough to see —
  /// see [defaultTicketLogo].
  ///
  /// Every row must be the same length, and [scale] at least 1; both are
  /// programming errors rather than data errors, so they throw.
  factory TicketLogo.fromArt(List<String> art,
      {int scale = 1, String ink = '#'}) {
    if (art.isEmpty) throw ArgumentError.value(art, 'art', 'must not be empty');
    if (scale < 1) throw ArgumentError.value(scale, 'scale', 'must be >= 1');
    final int artWidth = art.first.length;
    if (artWidth == 0) {
      throw ArgumentError.value(art, 'art', 'rows must not be empty');
    }
    for (final String row in art) {
      if (row.length != artWidth) {
        throw ArgumentError.value(
            art, 'art', 'rows must all be $artWidth wide');
      }
    }

    final int width = artWidth * scale;
    final int height = art.length * scale;
    final int rowBytes = (width + 7) ~/ 8;
    final Uint8List bits = Uint8List(rowBytes * height);
    final int inkUnit = ink.codeUnitAt(0);
    for (int artY = 0; artY < art.length; artY++) {
      final String row = art[artY];
      for (int artX = 0; artX < artWidth; artX++) {
        if (row.codeUnitAt(artX) != inkUnit) continue;
        for (int dy = 0; dy < scale; dy++) {
          final int base = (artY * scale + dy) * rowBytes;
          for (int dx = 0; dx < scale; dx++) {
            final int x = artX * scale + dx;
            bits[base + (x >> 3)] |= 0x80 >> (x & 7);
          }
        }
      }
    }
    return TicketLogo._(width, height, bits);
  }

  /// Width in printer dots.
  final int width;

  /// Height in printer dots.
  final int height;

  /// The packed rows, `bytesPerRow * height` long.
  final Uint8List bits;

  /// Bytes per printed row — what the raster header's horizontal size counts.
  int get bytesPerRow => (width + 7) ~/ 8;

  /// Whether this logo fits the loaded paper. A wider one is not wrapped by the
  /// printer, it is silently clipped, so the composer refuses it instead.
  bool get fitsPaper => width <= ticketPrintWidthDots;

  /// Whether the dot at [x], [y] is set. For tests and for asserting a scaled
  /// logo really is the art it was built from.
  bool dotAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return false;
    return bits[y * bytesPerRow + (x >> 3)] & (0x80 >> (x & 7)) != 0;
  }

  @override
  String toString() => 'TicketLogo(${width}x$height)';
}

/// How many dots each cell of [defaultTicketLogoArt] becomes.
///
/// At the TM-m30III's 203 dpi, the shipped 24x24 art at scale 5 prints as a
/// 120-dot (~15 mm) square: small beside the name, unmistakably the school's
/// mark, and comfortably inside [ticketPrintWidthDots].
const int defaultTicketLogoScale = 5;

/// The shipped mark: a bold "A" monogram.
///
/// **A placeholder.** The school's real logo has not been supplied, and the
/// printer it has to look right on has not been connected. It is deliberately a
/// shape that survives being wrong — replacing it is editing the art below and
/// nothing else, and [TicketLogo.fromArt] takes any other rectangle just as
/// happily.
const List<String> defaultTicketLogoArt = <String>[
  '...........#............',
  '...........#............',
  '..........###...........',
  '..........###...........',
  '.........#####..........',
  '.........#####..........',
  '........#######.........',
  '........#######.........',
  '.......####.####........',
  '.......####.####........',
  '......####...####.......',
  '......####...####.......',
  '.....#####...#####......',
  '.....####.....####......',
  '....###############.....',
  '....###############.....',
  '...#################....',
  '...#################....',
  '..#####.........#####...',
  '..#####.........#####...',
  '.#####...........#####..',
  '.#####...........#####..',
  '#####.............#####.',
  '#####.............######',
];

/// The logo a ticket carries when the caller does not supply one.
final TicketLogo defaultTicketLogo = TicketLogo.fromArt(
  defaultTicketLogoArt,
  scale: defaultTicketLogoScale,
);
