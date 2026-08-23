import 'dart:async';

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A minimal [core.Snapshot] so these tests exercise [SystemState]'s
/// orchestration without pulling in a concrete connector snapshot type.
class _FakeSnapshot implements core.Snapshot {
  const _FakeSnapshot(this.fetchedAt, {this.tag = ''});

  @override
  final DateTime fetchedAt;

  final String tag;

  @override
  core.Origin get origin => core.Origin.wisa;
}

void main() {
  group('SystemState.sync', () {
    test('replaces the snapshot and stamps lastSync from fetchedAt', () async {
      final fetchedAt = DateTime.utc(2026, 7, 3, 9);
      final state = SystemState<_FakeSnapshot>(
        system: core.Origin.wisa,
        syncer: (_, {bool fullRead = false}) async =>
            _FakeSnapshot(fetchedAt, tag: 'fresh'),
      );

      expect(state.snapshot, isNull);
      expect(state.lastSync, isNull);

      final result = await state.sync();

      expect(result.tag, 'fresh');
      expect(state.snapshot, same(result));
      expect(state.lastSync, fetchedAt);
    });

    test('passes the current snapshot to the syncer as `previous`', () async {
      _FakeSnapshot? seen;
      var calls = 0;
      final state = SystemState<_FakeSnapshot>(
        system: core.Origin.azure,
        syncer: (previous, {bool fullRead = false}) async {
          seen = previous;
          return _FakeSnapshot(DateTime.utc(2026, 7, calls += 1));
        },
      );

      await state.sync();
      expect(seen, isNull, reason: 'first sync has no previous snapshot');

      final first = state.snapshot;
      await state.sync();
      expect(seen, same(first),
          reason:
              'second sync threads the stored snapshot back in (delta seam)');
    });

    test('forwards fullRead to the syncer, defaulting to an ordinary sync',
        () async {
      // The seam **Controleer op drift** threads down to the Azure syncer
      // (#316): the pass says whether it may build on the resume point the
      // stored snapshot carries. The snapshot itself goes in either way.
      final asked = <bool>[];
      final seen = <String?>[];
      final state = SystemState<_FakeSnapshot>(
        system: core.Origin.azure,
        initial: _FakeSnapshot(DateTime.utc(2026), tag: 'held'),
        syncer: (previous, {bool fullRead = false}) async {
          asked.add(fullRead);
          seen.add(previous?.tag);
          return _FakeSnapshot(DateTime.utc(2026, 7), tag: 'fresh');
        },
      );

      await state.sync();
      await state.sync(fullRead: true);

      expect(asked, <bool>[false, true]);
      expect(seen, <String?>['held', 'fresh'],
          reason: 'a re-read still gets the snapshot in hand as `previous`');
    });

    test('a failed sync leaves the previous snapshot and lastSync intact',
        () async {
      final good = DateTime.utc(2026, 7, 1);
      var shouldFail = false;
      final state = SystemState<_FakeSnapshot>(
        system: core.Origin.smartschool,
        syncer: (_, {bool fullRead = false}) async {
          if (shouldFail) throw const _SyncFailure();
          return _FakeSnapshot(good, tag: 'good');
        },
      );

      await state.sync();
      final stored = state.snapshot;
      expect(stored?.tag, 'good');

      shouldFail = true;
      await expectLater(state.sync(), throwsA(isA<_SyncFailure>()));

      expect(state.snapshot, same(stored), reason: 'snapshot unchanged');
      expect(state.lastSync, good, reason: 'lastSync unchanged');
    });

    test('seeds snapshot and lastSync from an initial snapshot', () {
      final at = DateTime.utc(2025, 12, 31);
      final state = SystemState<_FakeSnapshot>(
        system: core.Origin.wisa,
        syncer: (_, {bool fullRead = false}) async =>
            _FakeSnapshot(DateTime.utc(2026)),
        initial: _FakeSnapshot(at, tag: 'cached'),
      );
      expect(state.snapshot?.tag, 'cached');
      expect(state.lastSync, at);
    });

    test('rejects a concurrent sync rather than racing the snapshot slot',
        () async {
      final gate = Completer<void>();
      final state = SystemState<_FakeSnapshot>(
        system: core.Origin.wisa,
        syncer: (_, {bool fullRead = false}) async {
          await gate.future;
          return _FakeSnapshot(DateTime.utc(2026));
        },
      );

      final first = state.sync();
      expect(state.isSyncing, isTrue);
      await expectLater(state.sync(), throwsStateError);

      gate.complete();
      await first;
      expect(state.isSyncing, isFalse);
    });
  });

  group('SystemState.test (transient connection state)', () {
    SystemState<_FakeSnapshot> make() => SystemState<_FakeSnapshot>(
          system: core.Origin.wisa,
          syncer: (_, {bool fullRead = false}) async =>
              _FakeSnapshot(DateTime.utc(2026)),
        );

    test('starts unknown on a fresh state (never persisted)', () {
      expect(make().connection, core.ConnectionState.unknown);
    });

    test('records ok on a successful probe', () async {
      final state = make();
      expect(await state.test(() async => true), isTrue);
      expect(state.connection, core.ConnectionState.ok);
    });

    test('records failed on a negative probe', () async {
      final state = make();
      expect(await state.test(() async => false), isFalse);
      expect(state.connection, core.ConnectionState.failed);
    });

    test('records failed when the probe throws', () async {
      final state = make();
      expect(await state.test(() async => throw const _SyncFailure()), isFalse);
      expect(state.connection, core.ConnectionState.failed);
    });
  });
}

class _SyncFailure implements Exception {
  const _SyncFailure();
}
