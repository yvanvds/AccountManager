import 'package:account_core/account_core.dart' show ILog, Origin;
import 'package:flutter/foundation.dart';

/// One entry in the inline log panel.
class LogEntry {
  const LogEntry({
    required this.time,
    required this.origin,
    required this.message,
    required this.isError,
  });

  final DateTime time;
  final Origin origin;
  final String message;
  final bool isError;

  /// The entry as one plain-text line — `HH:mm:ss  [origin]  message`.
  ///
  /// This is both what the panel renders and what a copy puts on the clipboard
  /// (#193), deliberately in one place: an operator pasting a log excerpt into
  /// a support ticket must be quoting exactly what they read on screen.
  String get line {
    final String hhmmss = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
    return '$hhmmss  [${origin.name}]  $message';
  }
}

/// Which entry a [characterOffset] into the panel's rendered paragraph falls
/// in (#197).
///
/// The panel renders its entries as a *single* selectable paragraph — one
/// [LogEntry.line] per line, joined by newlines (#193) — because a
/// `SelectionArea` over per-row widgets concatenates them with no separator
/// and would copy a multi-line selection as one blob. That leaves no widget
/// per row to hang a per-line action on, so the line under the pointer is
/// resolved from the paragraph itself: the entry index is how many newlines
/// precede the character the pointer landed on.
///
/// Counting newlines rather than dividing a hit by a line height is what makes
/// this survive soft wrapping: a message wider than the panel occupies several
/// visual rows but is still one entry.
int logEntryIndexAt(String paragraph, int characterOffset) {
  final int end = characterOffset.clamp(0, paragraph.length);
  var index = 0;
  for (var i = 0; i < end; i++) {
    if (paragraph.codeUnitAt(i) == 0x0a) index++;
  }
  return index;
}

/// The app's [ILog] sink: an in-memory, notifying buffer the inline log panel
/// renders (#99). Wired into the connectors at bootstrap and used by the
/// reconcile controller for its own progress messages, so every diagnostic in
/// one run lands in the same panel.
///
/// Keeps at most [capacity] entries, dropping the oldest — the panel is a
/// session diagnostic, not an archive (promote to its own view later only if
/// it gets busy, per the issue).
class LogBuffer extends ChangeNotifier implements ILog {
  LogBuffer({this.capacity = 500, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final int capacity;
  final DateTime Function() _clock;
  final List<LogEntry> _entries = <LogEntry>[];

  /// The buffered entries, oldest first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  bool get hasErrors => _entries.any((e) => e.isError);

  /// The whole buffer as plain text, oldest first, one [LogEntry.line] per
  /// line — what the panel's **Alles kopiëren** writes to the clipboard (#193).
  ///
  /// Reads the entries rather than the rendered selection on purpose: the
  /// panel only lays out what fits, so a selection can never reach the older
  /// end of a [capacity]-entry buffer.
  String toPlainText() => _entries.map((LogEntry e) => e.line).join('\n');

  @override
  void addMessage(Origin origin, String message) =>
      _add(origin, message, isError: false);

  @override
  void addError(Origin origin, String message) =>
      _add(origin, message, isError: true);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  void _add(Origin origin, String message, {required bool isError}) {
    _entries.add(LogEntry(
      time: _clock(),
      origin: origin,
      message: message,
      isError: isError,
    ));
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    notifyListeners();
  }
}
