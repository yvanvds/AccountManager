import 'dart:convert';
import 'dart:io';

import 'package:account_manager/src/auth/aad_app_config.dart';
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart'
    show StoreEndpoints;
import 'package:account_manager/src/settings/connection_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the middle resolution layer — what `--dart-define` put into
/// this build, or the shipped constants where it carried none. It cannot be
/// varied at run time (`String.fromEnvironment` is compile-time), so it is
/// injected as [FileConnectionStore]'s fallback: the *ordering* between the file
/// and whatever is under it is what these tests are about, and the layer under
/// the file behaves identically whether a define or a constant filled it.
const StoreEndpoints _build = StoreEndpoints(
  cosmosEndpoint: 'https://build.documents.azure.com:443/',
  cosmosDatabase: 'build-db',
  vaultUri: 'https://build-kv.vault.azure.net/',
  blobEndpoint: 'https://build.blob.core.windows.net',
  blobContainer: 'build-snapshots',
  signalrEndpoint: 'https://build.service.signalr.net',
  signalrHub: 'build-hub',
);

const StoreEndpoints _fromFile = StoreEndpoints(
  cosmosEndpoint: 'https://school.documents.azure.com:443/',
  cosmosDatabase: 'school-db',
  vaultUri: 'https://school-kv.vault.azure.net/',
  blobEndpoint: 'https://school.blob.core.windows.net',
  blobContainer: 'school-snapshots',
  signalrEndpoint: 'https://school.service.signalr.net',
  signalrHub: 'school-hub',
);

/// The same stand-in for the sign-in half (#384): what a `--dart-define` build
/// carried. On a build with no defines the real thing is four empty strings, so
/// a non-empty stand-in is what lets a test tell "the file won" apart from "the
/// build won" for these four.
const AadAppConfig _buildAad = AadAppConfig(
  clientId: 'build-client',
  tenantId: 'build-tenant',
  azureDomain: 'build.example',
  schoolPrefix: 'BLD',
);

const AadAppConfig _aadFromFile = AadAppConfig(
  clientId: 'school-client',
  tenantId: 'school-tenant',
  azureDomain: 'school.example',
  schoolPrefix: 'GBS',
);

void main() {
  /// A fresh temp directory, removed when the test ends, so no test can touch
  /// the operator's real `%APPDATA%\AccountManager\connection.json`.
  File connectionFile() {
    final Directory dir = Directory.systemTemp.createTempSync('am-conn-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return File('${dir.path}${Platform.pathSeparator}$connectionFileName');
  }

  group('resolution order — file over define over compiled default (#370)', () {
    test('no file resolves to the layer under it, flagged as the default',
        () async {
      final store = FileConnectionStore(connectionFile(),
          fallback: _build, aadFallback: _buildAad);

      final resolved = await store.read();

      expect(resolved.endpoints, _build);
      expect(resolved.source, ConnectionSource.defaults);
      expect(resolved.hasWarning, isFalse);
    });

    test('a complete file wins over the layer under it', () async {
      final File file = connectionFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_fromFile.toJson()));
      final store =
          FileConnectionStore(file, fallback: _build, aadFallback: _buildAad);

      final resolved = await store.read();

      expect(resolved.endpoints, _fromFile);
      expect(resolved.source, ConnectionSource.file);
    });

    test('a partial file overrides only the keys it names', () async {
      // The realistic edit: an operator points one install at a different
      // Cosmos account and leaves every other coordinate alone. Merging per
      // field means the rest still comes from the build, rather than collapsing
      // to empty strings the app would then try to connect to.
      final File file = connectionFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(<String, dynamic>{
        StoreEndpoints.cosmosEndpointKey: _fromFile.cosmosEndpoint,
      }));
      final store =
          FileConnectionStore(file, fallback: _build, aadFallback: _buildAad);

      final resolved = await store.read();

      expect(resolved.source, ConnectionSource.file);
      expect(resolved.endpoints.cosmosEndpoint, _fromFile.cosmosEndpoint);
      expect(resolved.endpoints.cosmosDatabase, _build.cosmosDatabase);
      expect(resolved.endpoints.vaultUri, _build.vaultUri);
      expect(resolved.endpoints.blobEndpoint, _build.blobEndpoint);
      expect(resolved.endpoints.blobContainer, _build.blobContainer);
      expect(resolved.endpoints.signalrEndpoint, _build.signalrEndpoint);
      expect(resolved.endpoints.signalrHub, _build.signalrHub);
    });

    test('an explicitly empty SignalR endpoint is honoured, not defaulted',
        () async {
      // "No realtime here" is a supported configuration, and it is not the same
      // claim as "unset" — falling back on an empty string would make it
      // impossible to turn SignalR off on a build that ships one.
      final File file = connectionFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(<String, dynamic>{
        StoreEndpoints.signalrEndpointKey: '',
      }));
      final store =
          FileConnectionStore(file, fallback: _build, aadFallback: _buildAad);

      final resolved = await store.read();

      expect(resolved.endpoints.signalrEndpoint, isEmpty);
      expect(resolved.endpoints.cosmosEndpoint, _build.cosmosEndpoint);
    });

    test('the compiled defaults are the provisioned Arcadia infrastructure',
        () {
      // The bottom layer, unchanged by this issue: a build with no defines and
      // no file must behave exactly as it did before the file existed, so this
      // pins what "standaardwaarde" actually resolves to.
      final defaults = StoreEndpoints.fromEnvironment();

      expect(
        defaults.cosmosEndpoint,
        'https://accountmanager-cosmos-arcadia.documents.azure.com:443/',
      );
      expect(defaults.cosmosDatabase, 'accountmanager');
      expect(defaults.vaultUri, 'https://accountmanager-kv.vault.azure.net/');
      expect(
        defaults.blobEndpoint,
        'https://accountmanagerarcadia.blob.core.windows.net',
      );
      expect(defaults.blobContainer, 'snapshots');
      expect(defaults.signalrEndpoint, isEmpty);
      expect(defaults.signalrHub, 'reconcile');
    });
  });

  group('round-trip through the file (#370, #384)', () {
    test('what is written is what is read back, as the file layer', () async {
      final File file = connectionFile();
      final store = FileConnectionStore(
        file,
        fallback: _build,
        aadFallback: _buildAad,
      );

      await store.write(endpoints: _fromFile, aad: _aadFromFile);
      final resolved = await store.read();

      expect(resolved.endpoints, _fromFile);
      expect(resolved.source, ConnectionSource.file);
      expect(resolved.aad, _aadFromFile);
      expect(resolved.aadSource, ConnectionSource.file);
      expect(resolved.hasWarning, isFalse);
    });

    test('the file is plain JSON under the documented keys, and no secret',
        () async {
      final File file = connectionFile();
      final store = FileConnectionStore(
        file,
        fallback: _build,
        aadFallback: _buildAad,
      );

      await store.write(endpoints: _fromFile, aad: _aadFromFile);

      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded.keys, <String>{
        StoreEndpoints.cosmosEndpointKey,
        StoreEndpoints.cosmosDatabaseKey,
        StoreEndpoints.vaultUriKey,
        StoreEndpoints.blobEndpointKey,
        StoreEndpoints.blobContainerKey,
        StoreEndpoints.signalrEndpointKey,
        StoreEndpoints.signalrHubKey,
        AadAppConfig.clientIdKey,
        AadAppConfig.tenantIdKey,
        AadAppConfig.azureDomainKey,
        AadAppConfig.schoolPrefixKey,
      });
      expect(
          decoded[StoreEndpoints.cosmosEndpointKey], _fromFile.cosmosEndpoint);
      expect(decoded[AadAppConfig.clientIdKey], _aadFromFile.clientId);
      expect(decoded[AadAppConfig.tenantIdKey], _aadFromFile.tenantId);
    });

    test('a file written before #384 still loads, sign-in config and all',
        () async {
      // The upgrade path, and the one that decides whether this ships without a
      // migration: every install that took #370 has a connection.json with the
      // seven endpoint keys and no AAD key at all. It must keep resolving its
      // endpoints from the file and its sign-in config from the build — and it
      // must *say* so, rather than claiming the file supplied four values it
      // never mentioned.
      final File file = connectionFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_fromFile.toJson()));

      final resolved = await FileConnectionStore(
        file,
        fallback: _build,
        aadFallback: _buildAad,
      ).read();

      expect(resolved.endpoints, _fromFile);
      expect(resolved.source, ConnectionSource.file);
      expect(resolved.aad, _buildAad);
      expect(resolved.aadSource, ConnectionSource.defaults);
      expect(resolved.hasWarning, isFalse);
    });

    test('a write creates the parent directory on a first-run machine',
        () async {
      final Directory dir = Directory.systemTemp.createTempSync('am-conn-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final File nested = File(
        '${dir.path}${Platform.pathSeparator}AccountManager'
        '${Platform.pathSeparator}$connectionFileName',
      );

      await FileConnectionStore(
        nested,
        fallback: _build,
        aadFallback: _buildAad,
      ).write(endpoints: _fromFile, aad: _aadFromFile);

      expect(nested.existsSync(), isTrue);
    });
  });

  group('the Azure AD half resolves file over define over default (#384)', () {
    Future<ResolvedConnection> readWith(Map<String, dynamic> json) async {
      final File file = connectionFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(json));
      return FileConnectionStore(
        file,
        fallback: _build,
        aadFallback: _buildAad,
      ).read();
    }

    test('no file at all resolves to the layer under it', () async {
      final resolved = await FileConnectionStore(
        connectionFile(),
        fallback: _build,
        aadFallback: _buildAad,
      ).read();

      expect(resolved.aad, _buildAad);
      expect(resolved.aadSource, ConnectionSource.defaults);
    });

    test('a complete AAD block in the file wins over the build', () async {
      final resolved = await readWith(_aadFromFile.toJson());

      expect(resolved.aad, _aadFromFile);
      expect(resolved.aadSource, ConnectionSource.file);
      // …and it says nothing about the endpoints, so those stay where the build
      // put them.
      expect(resolved.endpoints, _build);
      expect(resolved.source, ConnectionSource.defaults);
    });

    test('a partial AAD block overrides only the keys it names', () async {
      final resolved = await readWith(<String, dynamic>{
        AadAppConfig.clientIdKey: _aadFromFile.clientId,
      });

      expect(resolved.aadSource, ConnectionSource.file);
      expect(resolved.aad.clientId, _aadFromFile.clientId);
      expect(resolved.aad.tenantId, _buildAad.tenantId);
      expect(resolved.aad.azureDomain, _buildAad.azureDomain);
      expect(resolved.aad.schoolPrefix, _buildAad.schoolPrefix);
    });

    test('an AAD key of the wrong type is ignored, not fatal', () async {
      // The same discipline the endpoints get, and it matters more here: a
      // half-hand-edited file must not be able to lock the install out of
      // sign-in, because sign-in is what reaches everything else.
      final resolved = await readWith(<String, dynamic>{
        AadAppConfig.clientIdKey: 42,
        AadAppConfig.tenantIdKey: _aadFromFile.tenantId,
      });

      expect(resolved.aad.clientId, _buildAad.clientId);
      expect(resolved.aad.tenantId, _aadFromFile.tenantId);
    });

    test('the compiled AAD defaults are empty, deliberately', () {
      // The bottom layer, and the reason this issue exists. These four are not
      // in this (public) repository, so a build carrying no --dart-define has
      // nothing to fall back on: `isConfigured` is false and the app has to be
      // configurable from Instellingen.
      final defaults = AadAppConfig.fromEnvironment();

      expect(defaults.clientId, isEmpty);
      expect(defaults.tenantId, isEmpty);
      expect(defaults.azureDomain, isEmpty);
      expect(defaults.schoolPrefix, isEmpty);
      expect(defaults.isConfigured, isFalse);
    });

    test('a client and a tenant are what "configured" means', () {
      expect(
        const AadAppConfig(clientId: 'c', tenantId: 't').isConfigured,
        isTrue,
      );
      expect(const AadAppConfig(clientId: 'c').isConfigured, isFalse);
      expect(const AadAppConfig(tenantId: 't').isConfigured, isFalse);
      // A domain and a prefix are not enough on their own — the broker needs the
      // other two.
      expect(
        const AadAppConfig(azureDomain: 'd', schoolPrefix: 'p').isConfigured,
        isFalse,
      );
    });

    test('a file with a saved AAD block makes an unconfigured build sign in',
        () async {
      // The end-to-end claim of the issue, at the store layer: a build with no
      // --dart-define (empty compiled defaults, `isConfigured` false) becomes
      // configured purely because a file on this machine says so.
      final File file = connectionFile();
      final store = FileConnectionStore(file); // real compiled fallbacks
      expect((await store.read()).aad.isConfigured, isFalse);

      await store.write(
        endpoints: StoreEndpoints.fromEnvironment(),
        aad: _aadFromFile,
      );

      final resolved = await store.read();
      expect(resolved.aad.isConfigured, isTrue);
      expect(resolved.aad, _aadFromFile);
      expect(resolved.aadSource, ConnectionSource.file);
    });
  });

  group('a broken file degrades instead of killing the launch (#370)', () {
    Future<ResolvedConnection> readWith(String raw) async {
      final File file = connectionFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(raw);
      return FileConnectionStore(
        file,
        fallback: _build,
        aadFallback: _buildAad,
      ).read();
    }

    test('malformed JSON falls back to the defaults with a warning', () async {
      final resolved = await readWith('{ this is not json');

      expect(resolved.endpoints, _build);
      expect(resolved.source, ConnectionSource.defaults);
      // Both halves degrade together — a file that cannot be parsed says
      // nothing about either, and neither half may take the launch down (#384).
      expect(resolved.aad, _buildAad);
      expect(resolved.aadSource, ConnectionSource.defaults);
      expect(resolved.hasWarning, isTrue);
      expect(resolved.warning, contains(connectionFileName));
    });

    test('JSON that is not an object falls back with a warning', () async {
      final resolved = await readWith('["cosmos"]');

      expect(resolved.endpoints, _build);
      expect(resolved.source, ConnectionSource.defaults);
      expect(resolved.warning, contains('geen JSON-object'));
    });

    test('an empty file falls back with a warning', () async {
      final resolved = await readWith('   \n');

      expect(resolved.endpoints, _build);
      expect(resolved.source, ConnectionSource.defaults);
      expect(resolved.warning, contains('leeg'));
    });

    test('a key of the wrong type is ignored, not fatal', () async {
      // Half-hand-edited files are the realistic failure. A number where a URI
      // belongs must cost that one coordinate, not the launch.
      final resolved = await readWith(jsonEncode(<String, dynamic>{
        StoreEndpoints.cosmosEndpointKey: 42,
        StoreEndpoints.cosmosDatabaseKey: _fromFile.cosmosDatabase,
      }));

      expect(resolved.source, ConnectionSource.file);
      expect(resolved.endpoints.cosmosEndpoint, _build.cosmosEndpoint);
      expect(resolved.endpoints.cosmosDatabase, _fromFile.cosmosDatabase);
    });
  });

  group('InMemoryConnectionStore', () {
    test('reads as the defaults until something is written', () async {
      final store = InMemoryConnectionStore(
        fallback: _build,
        aadFallback: _buildAad,
      );

      final before = await store.read();
      expect(before.endpoints, _build);
      expect(before.source, ConnectionSource.defaults);
      expect(before.aad, _buildAad);
      expect(before.aadSource, ConnectionSource.defaults);

      await store.write(endpoints: _fromFile, aad: _aadFromFile);

      final after = await store.read();
      expect(after.endpoints, _fromFile);
      expect(after.source, ConnectionSource.file);
      expect(after.aad, _aadFromFile);
      expect(after.aadSource, ConnectionSource.file);
      expect(store.stored, _fromFile);
      expect(store.storedAad, _aadFromFile);
    });

    test('it can model a #370-era file: endpoints stored, AAD not', () async {
      final store = InMemoryConnectionStore(
        stored: _fromFile,
        fallback: _build,
        aadFallback: _buildAad,
      );

      final resolved = await store.read();

      expect(resolved.source, ConnectionSource.file);
      expect(resolved.aadSource, ConnectionSource.defaults);
      expect(resolved.aad, _buildAad);
    });
  });
}
