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
    },
    skip: config == null
        ? 'Set AZURE_ACCESS_TOKEN (+ client/tenant/domain/prefix) to run.'
        : false,
  );
}
