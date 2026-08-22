import 'dart:math';

/// How a throttled (**429 TooManyRequests**) Cosmos request is retried (#196).
///
/// A 429 is Cosmos saying "slow down", not "this write is impossible": the
/// response carries `x-ms-retry-after-ms` telling the client exactly how long to
/// wait. [delayFor] honours that hint as a *floor* and layers exponential
/// backoff with jitter on top, so a burst of throttled writes does not
/// re-converge on the same instant and re-trip the limit.
///
/// The policy is a pure value object — no clock, no sleeping — so the whole
/// backoff curve is unit-testable without wall-clock waits; [HttpCosmosClient]
/// owns the (injectable) sleep.
class CosmosRetryPolicy {
  const CosmosRetryPolicy({
    this.maxAttempts = 8,
    this.baseDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 15),
    this.jitterFraction = 0.5,
  });

  /// Total attempts for one request, the first included. Once exhausted the 429
  /// is surfaced to the caller (i.e. as a `CosmosException`), because at that
  /// point the account really cannot absorb the write.
  final int maxAttempts;

  /// The backoff for the first retry; it doubles per attempt up to [maxDelay].
  final Duration baseDelay;

  /// Ceiling for the exponential term. The server's own `retry-after` hint can
  /// still push the wait beyond this — the server knows better than we do.
  final Duration maxDelay;

  /// How much jitter is added on top of the computed wait, as a fraction of it.
  /// `0.5` spreads the retry over `[wait, 1.5 × wait)`.
  final double jitterFraction;

  /// The wait before retry number [attempt] (1 = after the first failure).
  ///
  /// The base wait is the larger of the exponential backoff and the server's
  /// [retryAfter] hint; [roll] (a `[0,1)` random draw, injected so tests are
  /// deterministic) then spreads it by up to [jitterFraction] of itself.
  Duration delayFor({
    required int attempt,
    required double roll,
    Duration? retryAfter,
  }) {
    // 2^(attempt-1), with the shift capped so a pathological attempt count can
    // never overflow the exponent.
    final shift = attempt <= 1 ? 0 : (attempt - 1).clamp(0, 20);
    var ms = baseDelay.inMilliseconds * (1 << shift);
    if (ms > maxDelay.inMilliseconds) ms = maxDelay.inMilliseconds;
    final hint = retryAfter?.inMilliseconds ?? 0;
    if (hint > ms) ms = hint;
    ms += (ms * jitterFraction * roll).round();
    return Duration(milliseconds: ms);
  }
}

/// Shared throttling state for one Cosmos account: the client records every 429
/// here, and the write fan-out reads [concurrency] to decide how wide to run
/// (#196).
///
/// This is the adaptive half of the 429 fix. Retrying alone absorbs a brief
/// spike but keeps pushing the same load at an account that is already saying
/// "too much"; narrowing the fan-out lowers the offered rate until the account
/// keeps up, then widens back slowly so one transient 429 does not cost the rest
/// of the persist its speed.
///
/// One instance is wired into *both* the [HttpCosmosClient] (which reports) and
/// the `CosmosLinkedStore` (which reads), so the writer reacts to the throttling
/// its own requests provoked.
class CosmosThrottleGovernor {
  CosmosThrottleGovernor({
    this.maxConcurrency = 24,
    this.minConcurrency = 2,
    this.recoverAfter = 40,
    this.reportEvery = 100,
    void Function(String message)? onReport,
  })  : assert(minConcurrency >= 1),
        assert(maxConcurrency >= minConcurrency),
        _report = onReport,
        _limit = maxConcurrency;

  /// The unthrottled fan-out: how many writes run in parallel when the account
  /// is keeping up. A full account container is ~9.6k docs, so a serial write is
  /// not an option (#168).
  final int maxConcurrency;

  /// The floor the fan-out narrows to under sustained throttling. Never zero —
  /// a throttled persist must still make progress, just slowly.
  final int minConcurrency;

  /// How many un-throttled requests must land before the fan-out widens by one.
  /// Recovery is deliberately far slower than the halving, so the writer settles
  /// just under the account's real capacity instead of oscillating.
  final int recoverAfter;

  /// How often a *continuing* throttle burst is re-reported. The first 429 of a
  /// burst is always reported; after that one line per [reportEvery] events, so
  /// a heavily throttled persist stays visible without flooding the log.
  final int reportEvery;

  final void Function(String message)? _report;

  int _limit;
  int _clean = 0;
  int _throttles = 0;

  /// How wide the write fan-out may currently run.
  int get concurrency => _limit;

  /// How many throttled responses have been seen (across all requests).
  int get throttles => _throttles;

  /// Whether the fan-out is currently narrowed below [maxConcurrency].
  bool get isNarrowed => _limit < maxConcurrency;

  /// Records a throttled response. [wait] is the backoff about to be slept;
  /// `null` means the request ran out of attempts and the 429 is being surfaced.
  void recordThrottle({required int attempt, Duration? wait}) {
    _throttles++;
    final wasWide = !isNarrowed;
    _clean = 0;
    final halved = _limit ~/ 2;
    _limit = halved < minConcurrency ? minConcurrency : halved;
    if (wait == null) {
      _report?.call(
        'Cosmos beperkt het tempo nog steeds na $attempt pogingen — deze '
        'aanvraag wordt opgegeven.',
      );
      return;
    }
    // Report the start of a burst, then only every [reportEvery]th event.
    if (wasWide || _throttles % reportEvery == 0) {
      _report?.call(
        'Cosmos beperkt het tempo (429) — opnieuw proberen over '
        '${wait.inMilliseconds} ms en het aantal gelijktijdige schrijfacties '
        'verlaagd naar $_limit ($_throttles keer beperkt tot nu toe).',
      );
    }
  }

  /// Records a request the account answered without throttling. Widens the
  /// fan-out by one every [recoverAfter] clean requests.
  void recordSuccess() {
    if (!isNarrowed) return;
    if (++_clean < recoverAfter) return;
    _clean = 0;
    _limit++;
    if (!isNarrowed) {
      _report?.call(
        'Cosmos beperkt het tempo niet meer — aantal gelijktijdige '
        'schrijfacties terug op $_limit.',
      );
    }
  }
}

/// The default jitter source: a shared [Random] drawn per retry.
final Random _random = Random();

/// The `[0,1)` draw [CosmosRetryPolicy.delayFor] jitters with. Injectable in
/// tests so a backoff curve can be asserted exactly.
double defaultJitterRoll() => _random.nextDouble();
