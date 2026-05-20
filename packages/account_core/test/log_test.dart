import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

class _MemoryLog implements ILog {
  final List<(Origin, String, bool)> entries = [];

  @override
  void addMessage(Origin origin, String message) {
    entries.add((origin, message, false));
  }

  @override
  void addError(Origin origin, String message) {
    entries.add((origin, message, true));
  }
}

void main() {
  test('ILog records origin and severity for each entry', () {
    final log = _MemoryLog();
    log.addMessage(Origin.wisa, 'synced');
    log.addError(Origin.azure, 'token expired');
    expect(log.entries, hasLength(2));
    expect(log.entries[0], equals((Origin.wisa, 'synced', false)));
    expect(log.entries[1], equals((Origin.azure, 'token expired', true)));
  });
}
