/// How a background worker waits between failed attempts.
///
/// Small at first — a single 429 or a dropped Wi-Fi frame is over in a second —
/// and capped, because the desk is not waiting on any of this and hammering a
/// throttled account only makes the outage longer.
///
/// Shared by the two workers that sit behind the journal: the Cosmos mirror
/// (#403) and the Smartschool drain (#404). They tune it differently — a
/// mirror write is cheap and a presence write is three round-trips — but the
/// curve is the same one, so it lives in one place.
final class RetryBackoff {
  const RetryBackoff({
    this.base = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
  });

  final Duration base;
  final Duration max;

  /// The wait before attempt [attempt] + 1, doubling from [base] up to [max].
  Duration delayFor(int attempt) {
    if (attempt < 1) return base;
    // 2^30 µs already exceeds any sane cap; clamping the shift keeps the
    // multiply from overflowing on a long outage.
    final int shift = attempt - 1 > 20 ? 20 : attempt - 1;
    final int micros = base.inMicroseconds * (1 << shift);
    return micros >= max.inMicroseconds ? max : Duration(microseconds: micros);
  }
}
