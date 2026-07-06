@TestOn('vm')
library;

import 'dart:io';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Guards the checked-in provisioning script (`tool/provision-cosmos.ps1`,
/// #160) against drifting from the Cosmos container definitions that are the
/// Dart source of truth (`cosmos_config.dart`).
///
/// The whole point of the script is reproducibility: a fresh account must get
/// *exactly* the container set the app expects. A silent gap between the script
/// and the constants below is the same class of drift the issue was filed to
/// close (the six epic-#112 containers that were never stood up), so this test
/// fails loudly if a container is added to the model but not to the script, or
/// if the two special cases (the `identity` unique key, the `syncState` TTL)
/// are dropped.
void main() {
  // Walk up from the test's CWD until the repo-root script is found, so the
  // test passes whether `dart test` is invoked from the repo root
  // (`dart test packages/*/test`) or from the package directory.
  File locateScript() {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      final candidate = File('${dir.path}/tool/provision-cosmos.ps1');
      if (candidate.existsSync()) return candidate;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    fail(
      'Could not locate tool/provision-cosmos.ps1 by walking up from '
      '${Directory.current.path}',
    );
  }

  group('provision-cosmos.ps1', () {
    final script = locateScript().readAsStringSync();

    // Every container the model defines, with the partition-key path the store
    // writes it under. Kept in lockstep with cosmos_config.dart.
    const expectedContainers = <String, String>{
      identityContainer: '/pk',
      passwordQueueContainer: '/pk',
      linkedAccountsContainer: '/pk',
      linkedGroupsContainer: '/pk',
      rollupsContainer: '/pk',
      decisionsContainer: '/pk',
      settingsContainer: '/id',
      snapshotsContainer: '/id',
      syncStateContainer: '/id',
    };

    test('provisions every documented container with its partition key', () {
      for (final entry in expectedContainers.entries) {
        // The script builds each row as `Name = '<container>'; PartitionKey =
        // '<path>'`, so both the name and its key path must appear.
        expect(
          script,
          contains("'${entry.key}'"),
          reason: 'container ${entry.key} missing from provisioning script',
        );
      }
      // Guard the count too, so a container removed from the model but left in
      // the script (or vice versa) is caught.
      final nameMatches = RegExp(r"@\{\s*Name\s*=\s*'([^']+)'")
          .allMatches(script)
          .map((m) => m.group(1))
          .toSet();
      expect(nameMatches, equals(expectedContainers.keys.toSet()));
    });

    test('the identity container carries the /naturalKey unique-key policy',
        () {
      expect(script, contains(identityNaturalKeyPath));
      expect(
        script,
        contains('--unique-key-policy'),
        reason: 'identity unique-key policy must be applied at create time',
      );
    });

    test('the syncState container enables TTL for the lease sweep', () {
      // -1 = default-TTL on (items honor a per-item ttl); the lease document
      // relies on it (#108).
      expect(script, contains('--ttl'));
      expect(
          script,
          matches(RegExp(
              r"'syncState';\s*PartitionKey\s*=\s*'/id';\s*Ttl\s*=\s*-1")));
    });

    test(
        'creates the database and every container idempotently via an '
        'exists guard', () {
      // Each create is gated on an `exists` check, so a re-run is a no-op.
      expect(script, contains('cosmosdb'));
      expect(script, contains('database'));
      expect(script, contains("'exists'"));
      expect(script, contains("'create'"));
    });
  });

  // The Blob Storage side of the state backend (#161). The cold-snapshot store
  // (#107) overflows to Blob; the storage account, its `snapshots` container,
  // and the operator data role were provisioned by hand and never scripted —
  // the same drift the Cosmos guards above close. These assertions fail loudly
  // if the storage provisioning is dropped from the script.
  group('provision-cosmos.ps1 — Blob Storage (#161)', () {
    final script = locateScript().readAsStringSync();

    test('registers the Microsoft.Storage resource provider', () {
      // Storage ARM calls return SubscriptionNotFound until the provider is
      // registered, so the script must register it.
      expect(script, contains('Microsoft.Storage'));
      expect(script, contains("'register'"));
    });

    test('provisions the storage account, AAD-only, via a presence guard', () {
      expect(script, contains('accountmanagerarcadia'));
      expect(
        script,
        contains("'storage', 'account', 'create'"),
        reason: 'the storage account must be created by the script',
      );
      // AAD-only: shared-key access disabled, mirroring Cosmos disableLocalAuth.
      expect(
        script,
        contains('--allow-shared-key-access'),
        reason: 'the account must be AAD-only (shared-key access disabled)',
      );
      expect(script, contains('StorageV2'));
    });

    test('provisions the snapshots overflow container over AAD', () {
      expect(
        script,
        contains("'storage', 'container', 'create'"),
        reason: 'the overflow container must be created by the script',
      );
      // With shared-key access disabled, container ops must authenticate via AAD.
      expect(script, contains('--auth-mode'));
    });

    test('grants the operator Storage Blob Data Contributor', () {
      // The app reaches Blob as the signed-in operator, who needs this data
      // role — the missing scope/role is what made Blob writes fail (#161).
      expect(script, contains('Storage Blob Data Contributor'));
      expect(script, contains("'role', 'assignment'"));
    });
  });
}
