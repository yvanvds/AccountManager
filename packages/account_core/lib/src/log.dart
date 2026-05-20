import 'enums.dart';

/// Sink for diagnostic messages produced anywhere in the port.
///
/// Ported from `legacy-wpf/AccountApi/ILog.cs`. Each entry carries the
/// originating system ([Origin]) so the UI can filter by source.
abstract interface class ILog {
  void addMessage(Origin origin, String message);
  void addError(Origin origin, String message);
}
