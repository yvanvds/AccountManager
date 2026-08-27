/// The per-machine connection bootstrap (#370, #384): where this install's
/// backend lives and which Azure AD app registration it signs in with, read from
/// a local JSON file rather than from the settings document.
///
/// There is a genuine chicken-and-egg behind the split, worth stating plainly:
/// **the settings document lives in Cosmos, so the Cosmos coordinates cannot
/// live in the settings document.** The resolution is to keep the two apart —
/// deployment identity in this file, school configuration in `AppSettings` —
/// not to try to nest one inside the other. The Azure AD app registration (#384)
/// is the same argument one layer earlier: signing in is what gets you to
/// Cosmos, so it cannot be stored behind the sign-in either.
///
/// The file holds endpoint URIs and app-registration identifiers, and nothing
/// else. No key, no token, no credential: authentication is the operator's own
/// AAD token either way, which is why this sits in plain JSON next to the
/// DPAPI-encrypted token cache rather than inside it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:account_state/account_state.dart';

import '../auth/aad_app_config.dart';
import '../auth/sign_in_session.dart';
import '../reconcile/reconcile_bootstrap.dart' show StoreEndpoints;

/// The file the machine's coordinates are read from, under the same
/// `%APPDATA%\AccountManager\` root as the token cache.
const String connectionFileName = 'connection.json';

/// Where a resolved half of the bootstrap actually came from (#370) — what the
/// Verbinding tab reports, so the operator can tell a value they set from one
/// the build shipped.
enum ConnectionSource {
  /// This machine's [connectionFileName].
  file,

  /// The values compiled into the build: the `--dart-define` overrides where the
  /// build carried them, and the shipped constants otherwise.
  defaults,
}

/// One resolution of the bootstrap file: the values, where each half came from,
/// and anything that went wrong on the way.
class ResolvedConnection {
  const ResolvedConnection({
    required this.endpoints,
    required this.source,
    this.aad = const AadAppConfig(),
    this.aadSource = ConnectionSource.defaults,
    this.warning = '',
  });

  /// The coordinates the app should bootstrap against.
  final StoreEndpoints endpoints;

  /// Which layer [endpoints] came from — [ConnectionSource.file] when the file
  /// named at least one endpoint key, the build's own values otherwise.
  final ConnectionSource source;

  /// The Azure AD app registration this install signs in with (#384).
  final AadAppConfig aad;

  /// Which layer [aad] came from, tracked apart from [source] because the two
  /// halves genuinely differ on an install that predates #384: a file the #370
  /// version of the app wrote names every endpoint and no AAD key at all, so its
  /// endpoints come from the file while its sign-in config comes from the build.
  /// Reporting one source for both would tell the operator their empty client id
  /// was read out of a file that never mentioned it.
  final ConnectionSource aadSource;

  /// Why a connection file that *was* there did not win — malformed JSON, an
  /// unreadable file, an empty one.
  ///
  /// Carried rather than thrown on purpose: a broken connection file must fall
  /// back to the defaults with something visible to read, never take the launch
  /// down. A launch that dies on its own config file leaves no screen on which
  /// to fix the config file.
  final String warning;

  /// Whether [warning] has anything to say.
  bool get hasWarning => warning.isNotEmpty;
}

/// Where the per-machine bootstrap coordinates are read and written.
///
/// A seam rather than a bare file so the Verbinding section can be driven
/// headlessly: a test binds an [InMemoryConnectionStore] (or a temp-file
/// [FileConnectionStore]) and never touches the operator's real `%APPDATA%`.
abstract interface class ConnectionStore {
  /// Resolves the bootstrap: the file over the `--dart-define`/compiled layer,
  /// per field. Never throws — see [ResolvedConnection.warning].
  Future<ResolvedConnection> read();

  /// Persists [endpoints] and [aad] as this machine's connection file, replacing
  /// whatever was there.
  ///
  /// Both halves in one call because they are one file: an install configured
  /// through Instellingen → Verbinding writes a complete answer rather than a
  /// fragment layered over whatever the build happened to carry.
  Future<void> write({
    required StoreEndpoints endpoints,
    required AadAppConfig aad,
  });

  /// Where the values live, as the operator should read it — the file path in
  /// production. Shown in the Verbinding section so "I edited connection.json
  /// and nothing changed" is answerable without guessing which one.
  String get location;
}

/// The production [ConnectionStore]: a plain JSON file on disk.
class FileConnectionStore implements ConnectionStore {
  FileConnectionStore(
    this.file, {
    StoreEndpoints? fallback,
    AadAppConfig? aadFallback,
  })  : _fallback = fallback ?? StoreEndpoints.fromEnvironment(),
        _aadFallback = aadFallback ?? AadAppConfig.fromEnvironment();

  /// The connection file, which need not exist — an install that never had one
  /// resolves to [ConnectionSource.defaults], which is exactly how every install
  /// behaved before this file did.
  final File file;

  final StoreEndpoints _fallback;
  final AadAppConfig _aadFallback;

  @override
  String get location => file.path;

  @override
  Future<ResolvedConnection> read() async {
    ResolvedConnection defaults([String warning = '']) => ResolvedConnection(
          endpoints: _fallback,
          source: ConnectionSource.defaults,
          aad: _aadFallback,
          aadSource: ConnectionSource.defaults,
          warning: warning,
        );
    try {
      if (!file.existsSync()) return defaults();
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return defaults('${file.path} is leeg. De standaardwaarden van deze '
            'build worden gebruikt.');
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return defaults('${file.path} bevat geen JSON-object. De '
            'standaardwaarden van deze build worden gebruikt.');
      }
      // Each half reports the layer that actually answered for it (#384). A file
      // written before this issue names every endpoint key and no AAD key, so it
      // reads as "endpoints uit connection.json, Azure AD standaardwaarde" —
      // which is the truth, and is what tells a fresh install that its sign-in
      // config is still the empty compiled one.
      return ResolvedConnection(
        endpoints: StoreEndpoints.fromJson(decoded, fallback: _fallback),
        source: StoreEndpoints.namedIn(decoded)
            ? ConnectionSource.file
            : ConnectionSource.defaults,
        aad: AadAppConfig.fromJson(decoded, fallback: _aadFallback),
        aadSource: AadAppConfig.namedIn(decoded)
            ? ConnectionSource.file
            : ConnectionSource.defaults,
      );
    } on Object catch (e) {
      // Any failure at all — unparseable JSON, a locked or unreadable file —
      // degrades to the defaults with the reason attached (#370).
      return defaults('${file.path} kon niet gelezen worden ($e). De '
          'standaardwaarden van deze build worden gebruikt.');
    }
  }

  @override
  Future<void> write({
    required StoreEndpoints endpoints,
    required AadAppConfig aad,
  }) async {
    file.parent.createSync(recursive: true);
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    final Map<String, dynamic> json = <String, dynamic>{
      ...endpoints.toJson(),
      ...aad.toJson(),
    };
    await file.writeAsString('${encoder.convert(json)}\n');
  }
}

/// A [ConnectionStore] that keeps the file in memory.
///
/// Two uses, and both matter: it is what tests bind so a headless run cannot
/// write to the operator's real `%APPDATA%`, and it is what a non-Windows (or
/// APPDATA-less) run falls back to — where sign-in is already per-run only, so a
/// per-run connection is no worse.
class InMemoryConnectionStore implements ConnectionStore {
  InMemoryConnectionStore({
    StoreEndpoints? stored,
    AadAppConfig? storedAad,
    StoreEndpoints? fallback,
    AadAppConfig? aadFallback,
  })  : _stored = stored,
        _storedAad = storedAad,
        _fallback = fallback ?? StoreEndpoints.fromEnvironment(),
        _aadFallback = aadFallback ?? AadAppConfig.fromEnvironment();

  StoreEndpoints? _stored;
  AadAppConfig? _storedAad;
  final StoreEndpoints _fallback;
  final AadAppConfig _aadFallback;

  /// What a [write] last put here, or `null` while nothing has been written —
  /// the stand-in for "the file names the endpoints".
  StoreEndpoints? get stored => _stored;

  /// The same for the Azure AD half (#384). Held apart from [stored] so a test
  /// can model the realistic in-between file: one the #370 version of the app
  /// wrote, with endpoints and no sign-in config.
  AadAppConfig? get storedAad => _storedAad;

  @override
  String get location => '$connectionFileName (niet bewaard op deze machine)';

  @override
  Future<ResolvedConnection> read() async {
    final StoreEndpoints? stored = _stored;
    final AadAppConfig? storedAad = _storedAad;
    return ResolvedConnection(
      endpoints: stored ?? _fallback,
      source:
          stored == null ? ConnectionSource.defaults : ConnectionSource.file,
      aad: storedAad ?? _aadFallback,
      aadSource:
          storedAad == null ? ConnectionSource.defaults : ConnectionSource.file,
    );
  }

  @override
  Future<void> write({
    required StoreEndpoints endpoints,
    required AadAppConfig aad,
  }) async {
    _stored = endpoints;
    _storedAad = aad;
  }
}

/// The connection store for the machine this process is running on:
/// `%APPDATA%\AccountManager\connection.json` on Windows, an in-memory one
/// anywhere APPDATA is absent — the same rule the token cache follows
/// (`main._persistentTokenCache`).
ConnectionStore connectionStoreForThisMachine() {
  final String? appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null || appData.isEmpty) {
    return InMemoryConnectionStore();
  }
  return FileConnectionStore(
    File('$appData\\AccountManager\\$connectionFileName'),
  );
}

/// One probed backend and whether this machine can reach it with the coordinates
/// as typed (#370).
class ConnectionProbeResult {
  const ConnectionProbeResult({
    required this.id,
    required this.label,
    required this.ok,
    this.detail = '',
  });

  /// Stable slug, used to key the line the Verbinding section renders.
  final String id;

  /// How the backend is named on screen.
  final String label;

  /// Whether the probe came back.
  final bool ok;

  /// What went wrong, when it did not.
  final String detail;
}

/// Probes the backends a set of coordinates points at, without committing them.
///
/// A seam so the Verbinding section's **Verbinding testen** button can be driven
/// headlessly; production wires [probeConnectionLive].
typedef ConnectionProbe = Future<List<ConnectionProbeResult>> Function(
  StoreEndpoints endpoints,
);

/// The Key Vault secret the probe asks for. It deliberately does not exist: Key
/// Vault answers **404** for an absent secret in a vault it *can* reach, so the
/// probe distinguishes "vault answered" from "vault is not there" without
/// reading anybody's credential.
const SecretRef connectionProbeSecret = SecretRef('connection.probe');

/// The real **Verbinding testen**: a read-only round-trip to the two backends
/// the app cannot start without — the Cosmos account holding the settings
/// document, and the Key Vault holding the connector credentials.
///
/// Read-only on purpose. The Cosmos leg is a `TOP 1` query scoped to the
/// settings partition, which 404s on a wrong database or container instead of
/// silently succeeding the way a point read of an absent document would; the
/// vault leg reads a secret that is not there. Neither creates anything, so an
/// operator can press the button against production as often as they like.
///
/// Blob and SignalR are deliberately not probed: an install runs without either
/// (an empty SignalR endpoint is a supported configuration, and Blob is reached
/// only by a snapshot large enough to overflow Cosmos), so a red line for them
/// would report a problem the operator does not have.
Future<List<ConnectionProbeResult>> probeConnectionLive(
  StoreEndpoints endpoints, {
  required SignInSession session,
}) async {
  final ConnectionProbeResult cosmos = await _probe(
    id: 'cosmos',
    label: 'Cosmos DB',
    run: () async {
      final HttpCosmosClient client = HttpCosmosClient(
        config: CosmosConfig(
          endpoint: endpoints.cosmosEndpoint,
          database: endpoints.cosmosDatabase,
        ),
        transport: HttpCosmosTransport(),
        tokens: CosmosSessionTokenProvider(session),
      );
      await client.queryDocuments(
        container: settingsContainer,
        query: 'SELECT TOP 1 c.id FROM c',
        partitionKey: settingsDocumentId,
      );
    },
  );
  final ConnectionProbeResult vault = await _probe(
    id: 'vault',
    label: 'Key Vault',
    run: () async {
      final KeyVaultSecretProvider secrets = KeyVaultSecretProvider(
        config: KeyVaultConfig(vaultUri: endpoints.vaultUri),
        tokens: VaultSessionTokenProvider(session),
      );
      try {
        await secrets.read(connectionProbeSecret);
      } finally {
        secrets.close();
      }
    },
  );
  return <ConnectionProbeResult>[cosmos, vault];
}

Future<ConnectionProbeResult> _probe({
  required String id,
  required String label,
  required Future<void> Function() run,
}) async {
  try {
    await run();
    return ConnectionProbeResult(id: id, label: label, ok: true);
  } on Object catch (e) {
    return ConnectionProbeResult(id: id, label: label, ok: false, detail: '$e');
  }
}

/// The connection seams the Settings view edits against (#370).
///
/// Held apart from [SettingsServices] on purpose, and for the reason the whole
/// issue exists: those seams are built *from* these coordinates, so they are
/// exactly what is broken when the operator needs this section. The Verbinding
/// section depends on nothing that a wrong Cosmos endpoint can take away.
class ConnectionServices {
  const ConnectionServices({
    required this.store,
    this.probe,
    this.forgetTokens,
  });

  /// Where the coordinates are read and written.
  final ConnectionStore store;

  /// The reachability probe behind **Verbinding testen**, or `null` on a build
  /// with no session to mint tokens from — the button is then absent rather than
  /// present and inert.
  final ConnectionProbe? probe;

  /// Drops this machine's cached AAD tokens (#384), called when a save changes
  /// the **tenant**.
  ///
  /// A cached token is issued by one tenant's STS for one tenant's resources, so
  /// after a tenant change every token on disk has the wrong audience: keeping
  /// them means the next launch tries a silent acquisition that can only fail,
  /// and fails in a way that reads as "sign-in is broken" rather than as "you
  /// changed tenant". #381 asks the same question for an upgrade, where the
  /// answer is no because nothing moved; here it is unambiguously yes.
  ///
  /// A seam, and `null` on a build with nowhere to clear (a test, a machine with
  /// no `%APPDATA%` and therefore an in-memory cache that dies with the process
  /// anyway).
  final Future<void> Function()? forgetTokens;
}
