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
