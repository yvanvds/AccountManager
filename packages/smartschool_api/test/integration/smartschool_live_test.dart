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

    // A full live sync walks every group with a sequential
    // getAllAccountsExtended call (hundreds against a real tenant), so it
    // runs well past the test package's 30s default. Give it room.
    test('sync returns a non-empty, consistent snapshot',
        timeout: const Timeout(Duration(minutes: 5)), () async {
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

      // A real tenant has many groups nested under the root, a populated
      // account set, and memberships linking the two. Asserting only
      // "groups is non-empty" let #37 hide — the group-tree walk stopped at
      // the root (groups=1) and the empty account/membership sets passed the
      // vacuous consistency check below. Assert all three are populated.
      expect(
        snapshot.groups.length,
        greaterThan(1),
        reason: 'expected the group tree to descend past the root (see #37)',
      );
      expect(snapshot.accounts, isNotEmpty,
          reason: 'sync returned no accounts');
      expect(
        snapshot.memberships,
        isNotEmpty,
        reason: 'sync returned no memberships',
      );

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
