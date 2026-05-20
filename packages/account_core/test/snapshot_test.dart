import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

class _FakeWisaSnapshot implements Snapshot {
  @override
  final DateTime fetchedAt;
  @override
  Origin get origin => Origin.wisa;
  const _FakeWisaSnapshot(this.fetchedAt);
}

void main() {
  test('Snapshot interface exposes fetchedAt and origin', () {
    // The interface is what the linker and UI depend on; per-system
    // concrete classes live in connector packages and add their own fields.
    final snap = _FakeWisaSnapshot(DateTime.utc(2026, 5, 20));
    expect(snap.fetchedAt, equals(DateTime.utc(2026, 5, 20)));
    expect(snap.origin, equals(Origin.wisa));
  });
}
