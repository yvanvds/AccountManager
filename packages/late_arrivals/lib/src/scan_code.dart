/// Normalisation of the raw keystroke burst a handheld scanner produces.
library;

/// The lookup key for [raw] — what the scan index is built on and looked up by
/// (#401).
///
/// The scanner is a keyboard wedge: it *types* the code and then presses Enter,
/// so what arrives is the code plus terminator noise that is the scanner's, not
/// the student's. Everything that cannot be part of an Internnummer is dropped
/// — every whitespace and control character, wherever it sits, not just at the
/// ends — and what is left is folded to lower case so the index and the lookup
/// agree whatever an operator's manual re-type looks like. Codes are numeric in
/// practice, so removing interior noise cannot fuse two halves of a real value.
///
/// Returns the empty string when nothing but noise was scanned (a stray Enter,
/// a scanner that fired at nothing) — the caller treats that as "no scan", not
/// as an unknown student.
String normalizeScanCode(String raw) {
  final out = StringBuffer();
  for (final rune in raw.runes) {
    if (_isNoise(rune)) continue;
    out.writeCharCode(rune);
  }
  return out.toString().toLowerCase();
}

/// Whether [rune] is scanner noise rather than part of the code.
///
/// Spelled out as ranges rather than left to a regex `\s`, because what a wedge
/// emits around the payload is not only whitespace: the C0 controls (CR, LF,
/// TAB) are the terminator itself, and some scanners frame the burst with STX /
/// ETX. The exotic spaces below are what a manual re-type or a copy-paste out
/// of a spreadsheet leaves behind.
bool _isNoise(int rune) =>
    rune <= 0x20 || // C0 controls and the plain space
    (rune >= 0x7f && rune <= 0xa0) || // DEL, C1 controls, no-break space
    rune == 0x1680 || // Ogham space mark
    (rune >= 0x2000 && rune <= 0x200a) || // en/em quad … hair space
    rune == 0x2028 || // line separator
    rune == 0x2029 || // paragraph separator
    rune == 0x202f || // narrow no-break space
    rune == 0x205f || // medium mathematical space
    rune == 0x3000 || // ideographic space
    rune == 0xfeff; // zero-width no-break space (BOM)
