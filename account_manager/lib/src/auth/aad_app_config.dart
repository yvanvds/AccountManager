import 'package:azure_api/azure_api.dart' show AzureCredentials;

import 'aad_resource.dart';

/// The Azure AD app-registration settings the sign-in layer needs.
///
/// These are school-specific and are deliberately **not** baked into the binary:
/// this repository is public, and the tenant/client identifiers are kept out of
/// it. So the compiled defaults below are empty, and a build that carries no
/// `--dart-define` has [isConfigured] `false`.
///
/// Four layers resolve them, outermost first (#384, #387) — the same order the
/// backend coordinates already used (#370):
///
/// 1. this machine's `%APPDATA%\AccountManager\connection.json`
///    (`ConnectionStore`), merged **per field**;
/// 2. a `connection.json` placed next to the installed executable by IT (#387),
///    merged the same way — read-only, so a save still lands in `%APPDATA%`;
/// 3. the `--dart-define` values this build carried
///    ([AadAppConfig.fromEnvironment]);
/// 4. the compiled defaults, which for these four are the empty string.
///
/// The seed outranks `--dart-define` deliberately. A define is baked in at build
/// time by whoever produced the binary; the seed is placed at deployment time by
/// whoever installed *this* copy, and the later, more specific statement should
/// win. In practice the published build carries no defines at all — they would
/// be published with it — so the only builds that carry them are local ones,
/// where nobody puts a seed next to `build\windows\...\Release\` by accident.
///
/// The file layer is what makes an *installed* build configurable at all. #371
/// turned "you can pass `--dart-define`" from an inconvenience into a
/// falsehood: an operator who installed the app never meets a command line, so
/// v1.0.0 shipped a build that could not sign in and gated itself into a
/// "niet geconfigureerd" screen with no way out. Instellingen → Verbinding →
/// **Azure AD** is that way out, and it is reachable precisely because it needs
/// no token to render.
///
/// Not in the Cosmos settings document, for the reason #370 gave for the
/// endpoints and which applies twice over here: signing in is what gets you to
/// Cosmos, so the sign-in configuration cannot live inside Cosmos. None of it is
/// secret either — these are identifiers. Tokens stay in the DPAPI-encrypted
/// broker cache and credentials stay in Key Vault.
class AadAppConfig {
  const AadAppConfig({
    this.clientId = '',
    this.tenantId = '',
    this.azureDomain = '',
    this.schoolPrefix = '',
  });

  final String clientId;
  final String tenantId;
  final String azureDomain;
  final String schoolPrefix;

  /// Reads the config from compile-time environment defines:
  /// `AAD_CLIENT_ID`, `AAD_TENANT_ID`, `AAD_DOMAIN`, `SCHOOL_PREFIX`.
  ///
  /// None of the four has a `defaultValue`, which is the deliberate half of
  /// this: [String.fromEnvironment] answers the empty string for a define the
  /// build did not carry, and empty is the only honest compiled default for a
  /// value that must not be committed to a public repository. The file layer
  /// above supplies the real ones on an installed machine.
  factory AadAppConfig.fromEnvironment() => const AadAppConfig(
        clientId: String.fromEnvironment('AAD_CLIENT_ID'),
        tenantId: String.fromEnvironment('AAD_TENANT_ID'),
        azureDomain: String.fromEnvironment('AAD_DOMAIN'),
        schoolPrefix: String.fromEnvironment('SCHOOL_PREFIX'),
      );

  /// The keys these four values use inside `connection.json` (#384), named after
  /// the `--dart-define`s they stand in for so a hand-edited file reads the same
  /// way a build command does.
  ///
  /// Named constants because [toJson] writes them and [AadAppConfig.fromJson]
  /// reads them back; a typo in one of the two would silently drop a value to
  /// its (empty) default and lock the install out of sign-in — the very failure
  /// this exists to end.
  static const String clientIdKey = 'aadClientId';
  static const String tenantIdKey = 'aadTenantId';
  static const String azureDomainKey = 'aadDomain';
  static const String schoolPrefixKey = 'schoolPrefix';

  /// Every key this config occupies in the connection file, so a reader can ask
  /// whether a file says anything about Azure AD at all — see [namedIn].
  static const List<String> jsonKeys = <String>[
    clientIdKey,
    tenantIdKey,
    azureDomainKey,
    schoolPrefixKey,
  ];

  /// Whether [json] names any of the four — the difference between a file that
  /// configures sign-in and one written by the #370 version of the app, which
  /// carried only the endpoints.
  ///
  /// Used for the Verbinding tab's source label, so the Azure AD section cannot
  /// claim "uit connection.json" over four values the file never mentioned.
  static bool namedIn(Map<String, dynamic> json) =>
      jsonKeys.any(json.containsKey);

  /// Serializes to the `connection.json` shape (#384). Identifiers only — no
  /// token, no secret, which is why this rides in the same plain-JSON file as
  /// the endpoints rather than behind the DPAPI wrapper the token cache uses.
  Map<String, dynamic> toJson() => <String, dynamic>{
        clientIdKey: clientId,
        tenantIdKey: tenantId,
        azureDomainKey: azureDomain,
        schoolPrefixKey: schoolPrefix,
      };

  /// Reads a connection file over [fallback] — the `--dart-define`/compiled
  /// layer — **per field**, exactly as `StoreEndpoints.fromJson` does.
  ///
  /// Never throws. A key holding the wrong type is treated as absent rather than
  /// as a reason to fail the launch: the point of the file is to rescue a
  /// misconfigured install, so it must not be able to brick one. A file with no
  /// AAD keys at all — everything one written before #384 has — resolves to
  /// [fallback] in full, so it keeps loading exactly as it did.
  factory AadAppConfig.fromJson(
    Map<String, dynamic> json, {
    required AadAppConfig fallback,
  }) {
    String read(String key, String fallbackValue) {
      final Object? value = json[key];
      return value is String ? value : fallbackValue;
    }

    return AadAppConfig(
      clientId: read(clientIdKey, fallback.clientId),
      tenantId: read(tenantIdKey, fallback.tenantId),
      azureDomain: read(azureDomainKey, fallback.azureDomain),
      schoolPrefix: read(schoolPrefixKey, fallback.schoolPrefix),
    );
  }

  /// Whether enough is set to attempt a sign-in. Client and tenant are the
  /// minimum the broker needs.
  bool get isConfigured => clientId.isNotEmpty && tenantId.isNotEmpty;

  /// The STS authority for this tenant.
  String get authority => 'https://login.microsoftonline.com/$tenantId';

  /// The Graph credentials (scopes default from [AzureCredentials]).
  AzureCredentials get credentials => AzureCredentials(
        clientId: clientId,
        tenantId: tenantId,
        azureDomain: azureDomain,
        schoolPrefix: schoolPrefix,
      );

  /// The Graph resource, scoped from [credentials].
  AadResource get graph => AadResource.graph(credentials);

  @override
  bool operator ==(Object other) =>
      other is AadAppConfig &&
      other.clientId == clientId &&
      other.tenantId == tenantId &&
      other.azureDomain == azureDomain &&
      other.schoolPrefix == schoolPrefix;

  @override
  int get hashCode =>
      Object.hash(clientId, tenantId, azureDomain, schoolPrefix);

  /// Names the tenant and client, never anything more: this ends up in log
  /// lines and error text.
  @override
  String toString() => 'AadAppConfig($clientId@$tenantId)';
}
