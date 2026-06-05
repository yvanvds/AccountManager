/// Opt-in integration test: drives the connector against a real Smartschool
/// tenant. Skipped when `SMARTSCHOOL_ACCESSCODE` is empty so `dart test`
/// stays offline by default.
///
/// **Read-only** (sync only) per the project's live-testing policy: CI live
/// tests never write. Asserts only structural invariants — a non-empty group
/// tree and internally consistent memberships — and logs counts only, never
/// row contents, never the request envelope.
library;

import 'dart:io';

import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  final config = SmartschoolLiveConfig.fromEnvironment();
  final skipReason = config == null
      ? 'SMARTSCHOOL_ACCESSCODE not set; skipping live integration tests.'
      : null;

  group('smartschool_api live integration', skip: skipReason, () {
    late SmartschoolConnector connector;

    setUpAll(() {
      // config is non-null here because the group is unskipped.
      connector = config!.connector();
    });

    test('sync returns a non-empty, consistent snapshot', () async {
      SmartschoolSnapshot snapshot;
      try {
        snapshot = await connector.sync();
      } on Object catch (e) {
        throw Exception('sync threw: ${redactAccessCode(e.toString())}');
      }

      // Counts only — never the rows themselves.
      stdout.writeln(
        '  groups=${snapshot.groups.length} '
        'accounts=${snapshot.accounts.length} '
        'memberships=${snapshot.memberships.length}',
      );

      expect(snapshot.groups, isNotEmpty, reason: 'sync returned no groups');

      // Every membership references a known group and a known account.
      final groupIds = snapshot.groups.map((g) => g.id.value).toSet();
      final uids = snapshot.accounts.map((a) => a.uid).toSet();
      for (final m in snapshot.memberships) {
        expect(groupIds, contains(m.groupId.value));
        expect(uids, contains(m.uid));
      }
    });
  });
}
