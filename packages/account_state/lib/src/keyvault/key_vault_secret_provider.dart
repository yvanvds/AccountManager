import 'dart:convert';

import '../settings/secret_provider.dart';
import 'key_vault_config.dart';
import 'key_vault_token_provider.dart';
import 'key_vault_transport.dart';

/// A [SecretProvider] backed by the centralized Azure Key Vault.
///
/// The Phase B replacement for [InMemorySecretProvider] (issue #84): the WISA
/// password, Smartschool passphrase, and OAuth/token material move out of the
/// settings blob (PROJECT_OVERVIEW §6.2) and into the vault provisioned in the
/// B0 foundation (`accountmanager-kv`, see `docs/port-plan.md`). Nothing above
/// the seam changes — a [SecretRef] still names *where* a secret lives, and the
/// orchestration layer still calls [read]/[write]/[delete] — but the value now
/// lives in Key Vault instead of a process-local map.
///
/// A [SecretRef.name] maps to a Key Vault secret name through
/// [secretNameFor]/[refFor]. Because vault secret names are restricted to
/// `[0-9a-zA-Z-]` (1–127 chars) and matched **case-insensitively**, the refs the
/// config uses (`wisa.password`, `smartschool.passphrase`, …) cannot be used
/// verbatim — the `.` is illegal. The mapping escapes every character outside
/// `[0-9a-z]` as `-` + two lowercase hex digits, so it round-trips regardless of
/// how the service folds case (see [secretNameFor]).
///
/// AAD auth is a separate seam: each call reads a fresh short-lived token from
/// the injected [KeyVaultTokenProvider] (operator identity, no stored secret),
/// mirroring how the Azure SQL adapters read a per-open token. The HTTP itself
/// goes through the swappable [KeyVaultTransport], so this class is unit-tested
/// headlessly against a fake and the real `package:http` transport is exercised
/// only by the opt-in live check.
class KeyVaultSecretProvider implements SecretProvider {
  /// The Key Vault data-plane API version the requests target.
  static const String defaultApiVersion = '7.4';

  KeyVaultSecretProvider({
    required KeyVaultConfig config,
    required KeyVaultTokenProvider tokens,
    KeyVaultTransport? transport,
    String apiVersion = defaultApiVersion,
  })  : _config = config,
        _tokens = tokens,
        _transport = transport ?? HttpKeyVaultTransport(),
        _ownsTransport = transport == null,
        _apiVersion = apiVersion;

  final KeyVaultConfig _config;
  final KeyVaultTokenProvider _tokens;
  final KeyVaultTransport _transport;
  final bool _ownsTransport;
  final String _apiVersion;

  @override
  Future<String?> read(SecretRef ref) async {
    final resp = await _send('GET', ref);
    // An absent secret is a plain `null`, not an error — matching the
    // InMemorySecretProvider contract for an unconfigured credential.
    if (resp.isNotFound) return null;
    _ensureSuccess(resp);
    return resp.json['value'] as String?;
  }

  @override
  Future<void> write(SecretRef ref, String value) async {
    // PUT .../secrets/{name} creates a new secret or adds a version to an
    // existing one — Key Vault's upsert, matching "replacing any previous
    // value".
    final resp = await _send('PUT', ref, body: jsonEncode({'value': value}));
    _ensureSuccess(resp);
  }

  @override
  Future<void> delete(SecretRef ref) async {
    final resp = await _send('DELETE', ref);
    // Deleting an absent secret is a no-op, not an error (the seam contract).
    if (resp.isNotFound) return;
    _ensureSuccess(resp);
  }

  /// Releases the HTTP transport when this provider created it. A transport the
  /// caller injected is the caller's to close.
  void close() {
    final transport = _transport;
    if (_ownsTransport && transport is HttpKeyVaultTransport) {
      transport.close();
    }
  }

  Future<KeyVaultResponse> _send(String method, SecretRef ref,
      {String? body}) async {
    final token = await _tokens.vaultAccessToken();
    return _transport.send(KeyVaultRequest(
      method: method,
      url: _secretUrl(secretNameFor(ref)),
      headers: {
        'Authorization': 'Bearer $token',
        if (body != null) 'Content-Type': 'application/json',
      },
      body: body,
    ));
  }

  Uri _secretUrl(String secretName) => Uri.parse(_config.vaultUri).replace(
        pathSegments: ['secrets', secretName],
        queryParameters: {'api-version': _apiVersion},
      );

  void _ensureSuccess(KeyVaultResponse resp) {
    if (!resp.isSuccess) {
      throw KeyVaultException(resp.statusCode, resp.body);
    }
  }

  /// Maps a [SecretRef] to its Key Vault secret name.
  ///
  /// Every byte in `ref.name` that is a lowercase ASCII letter or digit passes
  /// through; every other byte — uppercase letters, `.`, `/`, `-` itself, and
  /// any non-ASCII byte — is escaped as `-` followed by two lowercase hex
  /// digits. The result therefore contains only `[0-9a-z-]`, satisfying the
  /// vault's `[0-9a-zA-Z-]` rule while staying stable under the service's
  /// case-insensitive folding: no two distinct refs can collide, and [refFor]
  /// recovers the original exactly. Escaping `-` itself keeps the delimiter
  /// unambiguous.
  ///
  /// Example: `wisa.password` → `wisa-2epassword`; `smartschool.passphrase` →
  /// `smartschool-2epassphrase`.
  ///
  /// Throws [ArgumentError] when `ref.name` is empty or maps to a name longer
  /// than the 127-character vault limit.
  static String secretNameFor(SecretRef ref) {
    final source = ref.name;
    if (source.isEmpty) {
      throw ArgumentError.value(source, 'ref.name', 'must not be empty');
    }
    final buffer = StringBuffer();
    for (final byte in utf8.encode(source)) {
      final isLowerAlnum = (byte >= 0x30 && byte <= 0x39) || // 0-9
          (byte >= 0x61 && byte <= 0x7a); // a-z
      if (isLowerAlnum) {
        buffer.writeCharCode(byte);
      } else {
        buffer
          ..write('-')
          ..write(byte.toRadixString(16).padLeft(2, '0'));
      }
    }
    final name = buffer.toString();
    if (name.length > 127) {
      throw ArgumentError.value(
        source,
        'ref.name',
        'maps to a Key Vault secret name longer than 127 characters '
            '(${name.length})',
      );
    }
    return name;
  }

  /// Recovers the [SecretRef] a Key Vault secret name was produced from — the
  /// exact inverse of [secretNameFor].
  ///
  /// Throws [FormatException] on a name that is not valid mapping output (a
  /// truncated or non-hex `-XX` escape).
  static SecretRef refFor(String secretName) {
    final bytes = <int>[];
    var i = 0;
    while (i < secretName.length) {
      final ch = secretName.codeUnitAt(i);
      if (ch == 0x2d) {
        // '-' introduces a two-hex-digit escape.
        if (i + 3 > secretName.length) {
          throw FormatException(
              'truncated escape in Key Vault secret name: $secretName');
        }
        final hex = secretName.substring(i + 1, i + 3);
        final value = int.tryParse(hex, radix: 16);
        if (value == null) {
          throw FormatException(
              'invalid escape "-$hex" in Key Vault secret name: $secretName');
        }
        bytes.add(value);
        i += 3;
      } else {
        bytes.add(ch);
        i += 1;
      }
    }
    return SecretRef(utf8.decode(bytes));
  }
}
