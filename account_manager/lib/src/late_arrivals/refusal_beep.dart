/// The sound a refused scan makes (#407).
///
/// **Why this is a component and not one line of `SystemSound.play`.** The
/// operator at the reception desk hears the *scanner's own* confirmation beep on
/// every single card, all morning. The one sound that must never be mistaken for
/// it is the app saying "I did not take that scan" — because the whole refusal
/// rule (a scan arriving while the previous student is still unconfirmed is
/// refused, and that student rescans) only works if the person holding the
/// scanner notices. A generic system ding, played through the same speaker at
/// roughly the same pitch and length as the scanner's chirp, is exactly the
/// sound that gets tuned out.
///
/// So the tone is deliberately the opposite of a scanner beep on all three axes
/// an ear separates quickly:
///
/// - **Low.** [refusalBeepHertz] is 220 Hz — the A below middle C. A handheld
///   scanner's confirmation beep sits around 2–3 kHz, more than three octaves
///   up.
/// - **Long.** [refusalBeepDuration] is 700 ms, against the scanner's ~50 ms
///   click. Long enough to still be sounding when the operator looks up.
/// - **Square.** A buzz, not a chime. That is what Windows' `Beep` produces —
///   it is a square-wave generator by definition — and it is why this reaches
///   for `kernel32` rather than for an audio plugin: no asset to ship, no
///   platform channel to register in the Windows CMake build, and the waveform
///   is the API's own guarantee rather than something a WAV file has to encode.
///
/// A seam, because a test must never make the build machine buzz: every widget
/// and integration test binds a recording fake, and only `main()` binds the real
/// one.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';

/// The pitch of the refusal tone, in hertz. See the library doc for why it is
/// this low.
const int refusalBeepHertz = 220;

/// How long the refusal tone sounds. See the library doc for why it is this
/// long.
const Duration refusalBeepDuration = Duration(milliseconds: 700);

/// Sounds the "that scan was refused" tone.
///
/// [play] returns immediately and never throws: it runs while a student is
/// standing at the desk, and a machine with no sound card is a machine where the
/// operator reads the refusal off the screen instead.
abstract interface class RefusalBeep {
  void play();
}

/// A [RefusalBeep] that makes no sound.
///
/// The honest binding for a platform that cannot produce the tone, and what a
/// test binds when it does not care whether one sounded.
class SilentRefusalBeep implements RefusalBeep {
  const SilentRefusalBeep();

  @override
  void play() {}
}

/// The production [RefusalBeep]: a square wave from `kernel32!Beep`.
///
/// **Off the UI thread, always.** `Beep` is synchronous — it returns only once
/// the tone has finished — so calling it inline would freeze the app for
/// [refusalBeepDuration] at the exact moment the operator needs to see the
/// refusal and the student needs to rescan. It is therefore run on a
/// short-lived isolate and never awaited.
///
/// **One tone at a time.** A burst of refused scans (the second student scans
/// again, and again) must not stack overlapping isolates each buzzing over the
/// last. A tone already sounding is left to finish; the refusal is on screen
/// either way.
///
/// Silent off Windows, which is not a limitation worth engineering around: this
/// is a Windows desktop app standing on a reception desk.
class SquareWaveRefusalBeep implements RefusalBeep {
  SquareWaveRefusalBeep({
    this.hertz = refusalBeepHertz,
    this.duration = refusalBeepDuration,
  });

  final int hertz;
  final Duration duration;

  bool _sounding = false;

  @override
  void play() {
    if (!Platform.isWindows || _sounding) return;
    _sounding = true;
    unawaited(
      Isolate.run(() => _beep(hertz, duration.inMilliseconds))
          // A machine with no audio device, a locked-down session, an isolate
          // that could not spawn: the refusal is on screen regardless, and a
          // thrown error here would be an unhandled async failure over a sound.
          .catchError((Object _) {})
          .whenComplete(() => _sounding = false),
    );
  }
}

typedef _BeepNative = Int32 Function(Uint32 frequency, Uint32 duration);
typedef _BeepDart = int Function(int frequency, int duration);

/// Sounds one square-wave tone. Runs on its own isolate — see
/// [SquareWaveRefusalBeep].
///
/// Top-level rather than a closure so what crosses the isolate boundary is two
/// integers and nothing else.
void _beep(int hertz, int milliseconds) {
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  final _BeepDart beep = kernel32.lookupFunction<_BeepNative, _BeepDart>(
    'Beep',
  );
  beep(hertz, milliseconds);
}
