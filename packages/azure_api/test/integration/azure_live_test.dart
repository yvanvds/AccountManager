@Timeout(Duration(minutes: 3))
library;

import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

/// Opt-in, **read-only** live test against a real Azure AD tenant.
///
/// `sync()` fans out a per-group member fetch against the live tenant, so a
/// full read takes ~30s+ locally — well over the 30s default test timeout.
/// The generous [Timeout] keeps the live job from failing on duration alone;
/// a true hang still trips the limit. (The N+1 member pull is the connector's
/// "Azure bulk pull" concern, tracked separately — not a test bug.)
///
/// Honours the repo live-testing policy: CI live tests never write. The
/// interactive sign-in is skipped — a pre-acquired bearer token is supplied
/// via `AZURE_ACCESS_TOKEN` (e.g. `az account get-access-token
/// --resource https://graph.microsoft.com`).
///
/// Runs only when the Azure env vars are present; otherwise it is skipped, so
/// `dart test` stays offline by default.
void main() {
  final config = AzureLiveConfig.fromEnvironment();

  group(
    'Azure live (read-only)',
    () {
      late AzureConnector connector;

      setUp(() {
        connector = AzureConnector(
          credentials: AzureCredentials(
            clientId: config!.clientId,
            tenantId: config.tenantId,
            azureDomain: config.azureDomain,
            schoolPrefix: config.schoolPrefix,
          ),
          authProvider: StaticAuthProvider(config.accessToken),
        );
      });

      tearDown(() => connector.close());

      test('sync() returns a filtered, non-empty snapshot', () async {
        final prefix = config!.schoolPrefix.toLowerCase();
        final snapshot = await connector.sync();
        // Filtered read should not return the whole tenant; sanity-bound it.
        expect(snapshot.users, isNotEmpty);
        expect(
          snapshot.users.every(
            (u) =>
                (u.companyName?.toLowerCase() == prefix) ||
                (u.department?.toLowerCase().startsWith(prefix) ?? false),
          ),
          isTrue,
        );
        // A delta token must be primed for the next incremental sync.
        expect(snapshot.deltaToken, isNotNull);
      });

      test('the pull carries each account\'s creation date back (#363)',
          () async {
        // Read-only, and the one thing a fake transport cannot prove: that
        // `createdDateTime` in the `$select` is *accepted* and answered. This
        // is the check #363 was split off #360 for — a `$select` Graph refuses
        // fails the whole pull, incremental included, for every school at once,
        // and no offline suite can tell an accepted field from a rejected one.
        //
        // `sync()` exercises both reads that carry the `$select`: the
        // `$filter`ed bulk read, and the `$deltatoken=latest` priming whose
        // query options Graph replays on every later resume (#288).
        final snapshot = await connector.sync();
        expect(snapshot.users, isNotEmpty);
        expect(
          snapshot.users.where((u) => u.createdAt != null),
          isNotEmpty,
          reason: 'createdDateTime is missing from the read if nothing has one',
        );
        // Nothing here asserts on `signInActivity`. It is never part of a bulk
        // read, it is fetched only for a duplicated `employeeId`, and whether
        // it answers at all depends on a consent this test must not encode.
      });

      test('groups come back with the shape that says who manages them (#331)',
          () async {
        // Read-only, per the live-testing policy: this asserts the *shape* is
        // read, never that a write is refused. It is the one thing a fake
        // transport cannot prove — that `$select` really carries `mailEnabled`
        // and `groupTypes` back from Graph. Drop either and every group reads
        // `mailEnabled: false, groupTypes: []`, which is exactly the blindness
        // that let a mail-enabled security group be proposed for a membership
        // sync on every pass.
        final snapshot = await connector.sync();
        expect(snapshot.groups, isNotEmpty);

        // The school's class groups are Microsoft 365 groups, so at least one
        // must carry `Unified` — the proof the field arrives at all.
        expect(
          snapshot.groups.where((g) => g.isUnified),
          isNotEmpty,
          reason: 'groupTypes is missing from the read if nothing is unified',
        );
        // And the two flags must agree with each other on every group: a
        // unified group is mail-enabled and never Exchange-mastered.
        for (final group in snapshot.groups.where((g) => g.isUnified)) {
          expect(group.mailEnabled, isTrue, reason: group.displayName);
          expect(group.canManageMembership, isTrue, reason: group.displayName);
        }
        // A group we will not write to is one Exchange masters, and nothing
        // else — stated as an invariant so a live tenant that grows a second
        // `SSM-1A` is reported rather than silently synced.
        for (final group
            in snapshot.groups.where((g) => !g.canManageMembership)) {
          expect(group.mailEnabled, isTrue, reason: group.displayName);
          expect(group.isUnified, isFalse, reason: group.displayName);
        }
      });
    },
    skip: config == null
        ? 'Set AZURE_ACCESS_TOKEN (+ client/tenant/domain/prefix) to run.'
        : false,
  );
}
