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
      message: 'WISA ophalen...',
      isError: false,
    );

    expect(entry.line, '09:04:07  [wisa]  WISA ophalen...');
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

  // The line under the pointer (#197). The panel renders its entries as one
  // paragraph (#193), so a per-line action cannot ask "which row widget was
  // clicked" — it has to map a character offset in that paragraph back to an
  // entry. Counting newlines is what keeps that right when a long message
  // soft-wraps over several visual rows but is still one entry.
  group('logEntryIndexAt', () {
    const String paragraph = '00:00:00  [azure]  gamma\n'
        '00:00:00  [smartschool]  beta\n'
        '00:00:00  [wisa]  alpha';

    test('an offset inside a line resolves to that line', () {
      expect(logEntryIndexAt(paragraph, 0), 0);
      expect(logEntryIndexAt(paragraph, 5), 0);
      expect(logEntryIndexAt(paragraph, paragraph.indexOf('beta')), 1);
      expect(logEntryIndexAt(paragraph, paragraph.indexOf('alpha')), 2);
    });

    test('a caret on either edge of a newline stays on its own line', () {
      final int newline = paragraph.indexOf('\n');
      // Before the newline is still the end of the first line...
      expect(logEntryIndexAt(paragraph, newline), 0);
      // ...and just past it is the start of the second.
      expect(logEntryIndexAt(paragraph, newline + 1), 1);
      expect(logEntryIndexAt(paragraph, paragraph.length), 2);
    });

    test('an offset off either end clamps to the first and last line', () {
      expect(logEntryIndexAt(paragraph, -20), 0);
      expect(logEntryIndexAt(paragraph, paragraph.length + 99), 2);
    });

    test('a paragraph without newlines is always line 0', () {
      expect(logEntryIndexAt('09:04:07  [wisa]  only', 12), 0);
      expect(logEntryIndexAt('', 0), 0);
    });
  });
}
