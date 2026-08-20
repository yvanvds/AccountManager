/// A parsed name search needle: whitespace-tolerant, case-insensitive, and
/// order-independent.
///
/// The needle is split on whitespace and **every** part must occur somewhere in
/// the normalised name. Matching per part rather than on the whole needle is
/// what makes either name order work: "jan peeters" finds "Peeters Jan" just as
/// it finds "Jan Peeters", so the operator never has to guess which way round
/// the name is stored. A search that silently returns nothing for a
/// correctly-remembered name is worse than no search (#215, #217).
///
/// This is shared deliberately. The two Personeel searches — Wachtwoorden →
/// Personeel (`PasswordController`, #215) and the Acties Personeel drill-down
/// (`ActionsScreen`, #187/#217) — sit one tab apart and the operator will not
/// remember which is which, so they must behave identically; one helper is what
/// keeps them from drifting apart again.
class NameQuery {
  /// Parses [text] into the words to match on. An empty or whitespace-only
  /// needle yields no parts, and so matches everyone.
  NameQuery(String text) : parts = _words(text);

  /// The lower-cased words of the needle, in the order typed (which does not
  /// affect matching — every part is looked for independently).
  final List<String> parts;

  /// Whether the needle carries nothing to match on, so every name passes.
  /// Callers that can skip filtering entirely use this to keep the original
  /// list rather than rebuilding it.
  bool get isEmpty => parts.isEmpty;

  /// Whether every part of the needle occurs somewhere in [name],
  /// case-insensitively and regardless of the order the parts were typed in.
  bool matches(String name) {
    if (parts.isEmpty) return true;
    // Normalise the haystack the same way as the needle so runs of whitespace,
    // and a leading/trailing space from an empty voornaam or naam, cannot
    // decide a match.
    final haystack = _words(name).join(' ');
    return parts.every(haystack.contains);
  }

  /// The lower-cased, whitespace-separated words of [text], empties dropped —
  /// used to normalise both the needle and the name it is matched against.
  static List<String> _words(String text) => <String>[
        for (final part in text.toLowerCase().split(_whitespace))
          if (part.isNotEmpty) part,
      ];

  static final RegExp _whitespace = RegExp(r'\s+');
}
