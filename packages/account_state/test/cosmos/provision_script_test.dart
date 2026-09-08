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

  /// Locates `pwsh` on PATH, or null when PowerShell is not installed (the
  /// script-execution tests below are skipped then rather than failing).
  String? locatePwsh() {
    for (final exe in const ['pwsh', 'pwsh.exe']) {
      try {
        final probe = Process.runSync(exe, const [
          '-NoProfile',
          '-Command',
          r'$PSVersionTable.PSVersion.Major'
        ]);
        if (probe.exitCode == 0) return exe;
      } on ProcessException {
        continue;
      }
    }
    return null;
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
      // The reception desk's mirrored late arrivals (#403), partitioned by the
      // school day so a day's registrations are one partition read.
      lateArrivalsContainer: '/pk',
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

  // On Windows `az` is `az.cmd`, a batch shim that forwards its arguments with
  // `%*`; cmd.exe re-parses that line, so any argument PowerShell did not have
  // to quote (no spaces) reaches cmd bare. A JMESPath filter such as
  // `length([?name=='x'])` died on its parentheses with `-o was unexpected at
  // this time.`, which aborted the script at step 3b and made the Blob half
  // unreachable — the reproducibility guarantee the script exists for (#416).
  group('provision-cosmos.ps1 — az.cmd argument safety (#416)', () {
    final scriptFile = locateScript();
    final script = scriptFile.readAsStringSync();

    test('passes no JMESPath --query to az at all', () {
      // Every filter worth writing carries parentheses, so the filtering moved
      // out of az and into PowerShell: reads ask for `-o json` and are matched
      // with Where-Object. This is the assertion that fails on the unpatched
      // script, which passed `length([?name=='...'])` and `length(@)`.
      expect(
        script,
        isNot(contains("'--query'")),
        reason: 'a --query expression is re-parsed by az.cmd; ask for '
            '-o json and filter in PowerShell instead',
      );
    });

    test('screens every az argument for cmd metacharacters', () {
      // The static sweep can only see literals; the arguments that actually
      // broke were interpolated values. So the script screens each argument at
      // call time, in all three az helpers.
      expect(script, contains('function Assert-CmdSafeArgs'));
      expect(
        RegExp(r'Assert-CmdSafeArgs \$AzArgs').allMatches(script).length,
        3,
        reason: 'Invoke-Az, Test-AzResource and Get-AzJson must all screen '
            'their arguments before handing them to az.cmd',
      );
    });

    final pwsh = locatePwsh();

    test('completes a -DryRun plan offline, without az', () {
      // -DryRun invokes no az at all, so this runs on any machine (and in CI)
      // with no Azure CLI and no credentials — while still walking every
      // argument array the real run would pass through the screen above. The
      // operator id is supplied so the role-assignment branch is walked too.
      final result = Process.runSync(pwsh!, [
        '-NoProfile',
        '-File',
        scriptFile.path,
        '-DryRun',
        '-OperatorObjectId',
        '00000000-0000-0000-0000-000000000001',
      ]);
      expect(
        result.exitCode,
        0,
        reason: 'dry run failed:\n${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('Done.'));
      // The whole plan, not just the Cosmos half that used to be reachable.
      expect(
          result.stdout, contains("Storage account 'accountmanagerarcadia'"));
      expect(result.stdout, contains("Blob container 'snapshots'"));
      expect(result.stdout, contains('role assignment list'));
    }, skip: pwsh == null ? 'pwsh not installed' : null);

    test('refuses an argument cmd.exe would re-parse', () {
      // The runtime guard behind the static sweeps above: it fires in -DryRun,
      // so a future argument carrying a cmd metacharacter is caught offline
      // rather than as `-o was unexpected at this time.` mid-provisioning.
      final result = Process.runSync(pwsh!, [
        '-NoProfile',
        '-File',
        scriptFile.path,
        '-DryRun',
        '-StorageAccount',
        'bad(name)',
      ]);
      expect(result.exitCode, isNot(0));
      expect(
          '${result.stdout}${result.stderr}', contains('Refusing to run az'));
    }, skip: pwsh == null ? 'pwsh not installed' : null);
  });
}
