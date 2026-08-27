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
/// Since #387 two files can answer, in this order: this machine's own under
/// `%APPDATA%`, then an optional seed IT placed beside the installed executable.
/// Writes always go to the first — the install directory is the deployment's,
/// rewritten by whatever upgrade or re-deploy comes next, so a correction made
/// in Instellingen has to live somewhere that does not. The seed exists because
/// the *installer* may not carry these values: it is a public artifact, and
/// baking the school's tenant and client id into it would publish them exactly
/// as committing them here would. A file placed by hand next to an installed
/// copy publishes nothing.
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
/// `%APPDATA%\AccountManager\` root as the token cache — and, since #387, the
/// name of the optional read-only seed beside the installed executable.
const String connectionFileName = 'connection.json';

/// Where a resolved half of the bootstrap actually came from (#370, #387) — what
/// the Verbinding tab reports, so the operator can tell a value they set from
/// one IT placed and from one the build shipped.
enum ConnectionSource {
  /// This machine's own [connectionFileName], under `%APPDATA%` — the layer
  /// **Verbinding bewaren** writes, and the only one that outranks the rest.
  file,

  /// The [connectionFileName] sitting next to the installed executable (#387):
  /// a seed placed there by IT, read-only from the app's point of view.
  seed,

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
    this.seedLocation = '',
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

  /// The path of the executable-adjacent seed that took part in this resolution
  /// (#387), or empty when there is none on this machine.
  ///
  /// Reported whether the seed *won* or not, because both answers are ones the
  /// Verbinding tab has to be able to give: "this value came out of the file
  /// beside the program" and "there is such a file, and your own
  /// `%APPDATA%` copy is overriding it". Without the second, an IT that edits
  /// the seed on a machine which already has a local file sees nothing change
  /// and has nothing on screen to explain it.
  final String seedLocation;

  /// Whether an executable-adjacent seed took part in this resolution at all.
  bool get hasSeed => seedLocation.isNotEmpty;

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
  /// Resolves the bootstrap: this machine's file over the executable-adjacent
  /// seed over the `--dart-define`/compiled layer, per field. Never throws — see
  /// [ResolvedConnection.warning].
  Future<ResolvedConnection> read();

  /// Persists [endpoints] and [aad] as this machine's connection file, replacing
  /// whatever was there.
  ///
  /// Both halves in one call because they are one file: an install configured
  /// through Instellingen → Verbinding writes a complete answer rather than a
  /// fragment layered over whatever the build happened to carry.
  ///
  /// Always writes the **`%APPDATA%`** copy, never the executable-adjacent seed
  /// (#387). Two reasons, and either would be enough: the seed is IT's statement
  /// about a fleet, which a single operator's machine is not entitled to
  /// rewrite; and the install directory is the deployment's, so the next
  /// upgrade or re-deploy of that file is free to overwrite anything written
  /// there — a correction has to live where nothing but this app writes.
  Future<void> write({
    required StoreEndpoints endpoints,
    required AadAppConfig aad,
  });

  /// Where a [write] puts the values, as the operator should read it — the
  /// `%APPDATA%` file path in production. Shown in the Verbinding section so "I
  /// edited connection.json and nothing changed" is answerable without guessing
  /// which one; [ResolvedConnection.seedLocation] names the other candidate.
  String get location;
}

/// One layer of the resolution: the values it leaves behind, whether the file
/// *at* this layer said anything about either half, and the warnings collected
/// on the way up.
///
/// A layer rather than a special case per file because there are two files now
/// (#387) and they behave identically: each merges over whatever is under it,
/// per field, and each degrades to what is under it when it cannot be read.
class _Layer {
  const _Layer({
    required this.endpoints,
    required this.aad,
    this.namesEndpoints = false,
    this.namesAad = false,
    this.warning = '',
  });

  final StoreEndpoints endpoints;
  final AadAppConfig aad;

  /// Whether the file *at this layer* named a backend coordinate — deliberately
  /// not inherited from the layer below, because it is what decides which source
  /// the Verbinding tab reports.
  final bool namesEndpoints;

  /// The same for the Azure AD half (#384).
  final bool namesAad;

  final String warning;

  /// Whether this file supplied anything at all.
  bool get namesAnything => namesEndpoints || namesAad;

  /// This layer's values passed straight through, claiming nothing of their own
  /// and carrying [warning] on top of whatever was already collected.
  ///
  /// What an absent, empty, malformed or unreadable file at the layer above
  /// resolves to: the values from underneath it, and no claim to have named
  /// them.
  _Layer passThrough([String extra = '']) => _Layer(
        endpoints: endpoints,
        aad: aad,
        warning: <String>[warning, extra].where((s) => s.isNotEmpty).join(' '),
      );
}

/// The production [ConnectionStore]: a plain JSON file on disk, optionally over
/// a second, read-only one beside the executable (#387).
class FileConnectionStore implements ConnectionStore {
  FileConnectionStore(
    this.file, {
    this.seed,
    StoreEndpoints? fallback,
    AadAppConfig? aadFallback,
  })  : _fallback = fallback ?? StoreEndpoints.fromEnvironment(),
        _aadFallback = aadFallback ?? AadAppConfig.fromEnvironment();

  /// The connection file, which need not exist — an install that never had one
  /// resolves to the layer under it, which is exactly how every install behaved
  /// before this file did. This is the file [write] writes, always.
  final File file;

  /// The optional seed IT placed next to the installed executable (#387): read
  /// on every launch, never written, and outranked by [file] per field.
  ///
  /// Not merged into [file] on first launch on purpose. Copying it would make
  /// the seed permanently invisible afterwards, so an IT that re-points a fleet
  /// by replacing the one file beside the executable would see nothing happen on
  /// any machine that had launched once — the exact "I edited connection.json
  /// and nothing changed" failure this file layer is supposed to end. Reading it
  /// every launch keeps a fleet re-pointable, and the operator's own saved
  /// corrections still win because they land in [file].
  final File? seed;

  final StoreEndpoints _fallback;
  final AadAppConfig _aadFallback;

  @override
  String get location => file.path;

  @override
  Future<ResolvedConnection> read() async {
    const String buildLayer = 'De standaardwaarden van deze build worden '
        'gebruikt.';
    // Bottom up: the compiled/`--dart-define` values, then the seed beside the
    // executable, then this machine's own file. Per field at every step, so a
    // seed that names only the Azure AD block leaves the endpoints where the
    // build put them, and a local file that names one endpoint leaves the rest
    // of the seed's answer standing.
    final _Layer seedLayer = await _readLayer(
      seed,
      _Layer(endpoints: _fallback, aad: _aadFallback),
      instead: buildLayer,
    );
    final _Layer local = await _readLayer(
      file,
      seedLayer,
      // What a broken local file actually falls back *to* — the seed, when there
      // is one that says something. Naming the build's defaults there would be a
      // small lie, and the operator would go looking in the wrong place.
      instead: seedLayer.namesAnything
          ? 'De waarden uit ${seed!.path} worden gebruikt.'
          : buildLayer,
    );

    // Each half reports the layer that actually answered for it (#384, #387). A
    // file written before #384 names every endpoint key and no AAD key, so it
    // reads as "endpoints uit connection.json, Azure AD standaardwaarde" — and
    // with a seed present the same file reads as "Azure AD uit het bestand naast
    // het programma", which is again the truth and is what makes the tab's
    // source line answerable.
    ConnectionSource sourceOf({
      required bool fromLocal,
      required bool fromSeed,
    }) =>
        fromLocal
            ? ConnectionSource.file
            : fromSeed
                ? ConnectionSource.seed
                : ConnectionSource.defaults;

    return ResolvedConnection(
      endpoints: local.endpoints,
      source: sourceOf(
        fromLocal: local.namesEndpoints,
        fromSeed: seedLayer.namesEndpoints,
      ),
      aad: local.aad,
      aadSource: sourceOf(
        fromLocal: local.namesAad,
        fromSeed: seedLayer.namesAad,
      ),
      seedLocation: _exists(seed) ? seed!.path : '',
      warning: local.warning,
    );
  }

  /// Reads one file over [under], per field. Never throws: any failure at all —
  /// an absent file, unparseable JSON, a locked or unreadable one — degrades to
  /// [under] with the reason attached (#370), and [instead] says in the
  /// operator's words which layer answered in its place.
  ///
  /// That discipline is doubly load-bearing now that a seed can be involved: a
  /// malformed file dropped beside the executable must be no more able to brick
  /// a launch than a malformed one in `%APPDATA%`, and a launch that dies on its
  /// own config file leaves no screen on which to fix the config file.
  Future<_Layer> _readLayer(
    File? file,
    _Layer under, {
    required String instead,
  }) async {
    if (file == null) return under.passThrough();
    try {
      if (!file.existsSync()) return under.passThrough();
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return under.passThrough('${file.path} is leeg. $instead');
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return under.passThrough('${file.path} bevat geen JSON-object. '
            '$instead');
      }
      return _Layer(
        endpoints: StoreEndpoints.fromJson(decoded, fallback: under.endpoints),
        aad: AadAppConfig.fromJson(decoded, fallback: under.aad),
        namesEndpoints: StoreEndpoints.namedIn(decoded),
        namesAad: AadAppConfig.namedIn(decoded),
        warning: under.warning,
      );
    } on Object catch (e) {
      return under.passThrough(
        '${file.path} kon niet gelezen worden ($e). $instead',
      );
    }
  }

  /// Whether a candidate file is there, without letting the question itself
  /// become a reason the launch fails.
  static bool _exists(File? file) {
    try {
      return file != null && file.existsSync();
    } on Object {
      return false;
    }
  }

  /// Writes [file], never [seed] (#387): the seed is read-only from the app's
  /// side, and a save is this operator's correction — it belongs where the next
  /// upgrade or fleet re-deploy cannot replace it.
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

/// Where IT may drop a seed for this install (#387): a [connectionFileName] in
/// the directory the running executable lives in.
///
/// The install directory rather than a shared one because that is the thing the
/// installer creates and an administrator can write to on the machine they are
/// setting up. It publishes nothing — which is the entire point, and the reason
/// the *installer* is not allowed to carry these values itself: the published
/// installer is a public artifact, and a file placed by hand next to the
/// installed copy is not.
File executableSeedConnectionFile() => File(
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}$connectionFileName',
    );

/// The connection store for the machine this process is running on:
/// `%APPDATA%\AccountManager\connection.json` on Windows over an optional seed
/// beside the executable (#387), an in-memory one anywhere APPDATA is absent —
/// the same rule the token cache follows (`main._persistentTokenCache`).
///
/// The seed rides only on the file-backed branch. Where there is no `%APPDATA%`
/// there is nowhere to save a correction to either, so that branch is already a
/// per-run configuration; layering a fleet-wide seed under it would give the
/// Verbinding tab a source it could not write over.
ConnectionStore connectionStoreForThisMachine() {
  final String? appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null || appData.isEmpty) {
    return InMemoryConnectionStore();
  }
  return FileConnectionStore(
    File('$appData\\AccountManager\\$connectionFileName'),
    seed: executableSeedConnectionFile(),
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
