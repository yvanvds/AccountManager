/// The refusal tone (#407).
///
/// What is actually testable here is the *choice*, not the sound: the tone has
/// to be unmistakable next to the scanner's own confirmation chirp, which the
/// operator hears on every card all morning. That chirp sits around 2–3 kHz and
/// lasts a few tens of milliseconds, so "low" and "long" are the two properties
/// the refusal depends on and the two a future tidy-up could quietly undo.
///
/// Whether a square wave comes out of the speaker is a claim about
/// `kernel32!Beep` and an audio device; no CI runner can assert it, and a suite
/// that made the build machine buzz would be its own kind of failure.
library;

import 'package:account_manager/src/late_arrivals/refusal_beep.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the refusal tone is far below a scanner\'s confirmation beep', () {
    // A handheld scanner beeps around 2–3 kHz. Three octaves down is not a
    // matter of taste: it is what makes the two impossible to confuse.
    expect(refusalBeepHertz, lessThan(400));
    expect(refusalBeepHertz, greaterThan(50));
  });

  test('the refusal tone lasts long enough to be noticed and acted on', () {
    // The scanner's own beep is a click. This has to still be sounding when the
    // operator looks up from the queue.
    expect(
        refusalBeepDuration,
        greaterThanOrEqualTo(const Duration(
          milliseconds: 500,
        )));
    // …and short enough that a second refused scan is not queued behind it.
    expect(refusalBeepDuration, lessThan(const Duration(seconds: 2)));
  });

  test('the silent binding is a no-op rather than a throw', () {
    const RefusalBeep beep = SilentRefusalBeep();
    expect(beep.play, returnsNormally);
  });

  test('the production tone carries the chosen pitch and length', () {
    final SquareWaveRefusalBeep beep = SquareWaveRefusalBeep();
    expect(beep.hertz, refusalBeepHertz);
    expect(beep.duration, refusalBeepDuration);
  });
}
