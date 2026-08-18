import 'package:account_core/account_core.dart' show Origin;
import 'package:account_manager/src/reconcile/log_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plain-text shape of the log (#193): what the panel renders is what an
/// operator pastes into a bug report or a support ticket, so the line format
/// and the copy format are the same code and are pinned here.
void main() {
  final DateTime at = DateTime(2026, 7, 1, 9, 4, 7);

  test('a log line reads HH:mm:ss  [origin]  message, zero padded', () {
    final entry = LogEntry(
      time: DateTime(2026, 7, 1, 9, 4, 7),
      origin: Origin.wisa,
      message: 'Syncing WISA...',
      isError: false,
    );

    expect(entry.line, '09:04:07  [wisa]  Syncing WISA...');
  });

  test('an empty buffer copies as the empty string', () {
    expect(LogBuffer().toPlainText(), isEmpty);
  });

  test('toPlainText renders oldest first, one line per entry', () {
    final log = LogBuffer(clock: () => at)
      ..addMessage(Origin.wisa, 'first')
      ..addError(Origin.smartschool, 'second')
      ..addMessage(Origin.azure, 'third');

    expect(
      log.toPlainText(),
      '09:04:07  [wisa]  first\n'
      '09:04:07  [smartschool]  second\n'
      '09:04:07  [azure]  third',
    );
  });

  test('toPlainText covers the whole retained buffer, dropped entries aside',
      () {
    final log = LogBuffer(capacity: 2, clock: () => at)
      ..addMessage(Origin.wisa, 'dropped')
      ..addMessage(Origin.wisa, 'kept-1')
      ..addMessage(Origin.wisa, 'kept-2');

    final List<String> lines = log.toPlainText().split('\n');
    expect(lines, hasLength(2));
    expect(lines.first, endsWith('kept-1'));
    expect(lines.last, endsWith('kept-2'));
    expect(log.toPlainText(), isNot(contains('dropped')));
  });
}
