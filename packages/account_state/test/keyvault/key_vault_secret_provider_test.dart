import 'dart:convert';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A [KeyVaultTransport] that records outgoing requests and replays a scripted
/// response, so the provider is driven with no vault and no network.
class _FakeTransport implements KeyVaultTransport {
  _FakeTransport(this._responder);

  final KeyVaultResponse Function(KeyVaultRequest request) _responder;
  final List<KeyVaultRequest> requests = [];

  @override
  Future<KeyVaultResponse> send(KeyVaultRequest request) async {
    requests.add(request);
    return _responder(request);
  }
}

/// Hands out a distinct token per call so a test can assert the provider reads a
/// fresh token for every request instead of caching one.
class _CountingTokenProvider implements KeyVaultTokenProvider {
  int calls = 0;

  @override
  Future<String> vaultAccessToken() async {
    calls++;
    return 'tok-$calls';
  }
}

KeyVaultResponse _ok(Map<String, dynamic> body) =>
    KeyVaultResponse(statusCode: 200, body: jsonEncode(body));

const _config = KeyVaultConfig(
  vaultUri: 'https://accountmanager-kv.vault.azure.net/',
);

KeyVaultSecretProvider _provider(
  KeyVaultTransport transport, {
  KeyVaultTokenProvider? tokens,
}) =>
    KeyVaultSecretProvider(
      config: _config,
      tokens: tokens ?? const StaticKeyVaultTokenProvider('bearer-xyz'),
      transport: transport,
    );

// Valid Key Vault secret name: 1-127 chars of [0-9a-zA-Z-].
final _validSecretName = RegExp(r'^[0-9a-zA-Z-]{1,127}$');

void main() {
  group('ref <-> secret-name mapping', () {
    test('escapes the illegal dot in the config refs', () {
      expect(
        KeyVaultSecretProvider.secretNameFor(const SecretRef('wisa.password')),
        'wisa-2epassword',
      );
      expect(
        KeyVaultSecretProvider.secretNameFor(
            const SecretRef('smartschool.passphrase')),
        'smartschool-2epassphrase',
      );
    });

    test('escapes a literal dash so the delimiter stays unambiguous', () {
      // '-' is 0x2d; escaping it prevents collision with the escape marker.
      expect(
        KeyVaultSecretProvider.secretNameFor(const SecretRef('wisa-pw')),
        'wisa-2dpw',
      );
    });

    test('produced names are always valid vault secret names', () {
      for (final ref in const [
        SecretRef('wisa.password'),
        SecretRef('smartschool.passphrase'),
        SecretRef('vault/wisa-pw'),
        SecretRef('Azure.OAuth.Token'),
        SecretRef('accént.wachtwoord'),
      ]) {
        final name = KeyVaultSecretProvider.secretNameFor(ref);
        expect(name, matches(_validSecretName), reason: 'for $ref');
      }
    });

    test('round-trips refs with dots, slashes, dashes, case and unicode', () {
      for (final original in const [
        'wisa.password',
        'smartschool.passphrase',
        'vault/wisa-pw',
        'Azure.OAuth.Token',
        'a-b.c/d',
        'accént.wachtwoord',
        '123',
      ]) {
        final ref = SecretRef(original);
        final name = KeyVaultSecretProvider.secretNameFor(ref);
        expect(KeyVaultSecretProvider.refFor(name), ref,
            reason: 'round-trip of $original');
      }
    });

    test('folds independently of case (output has no uppercase)', () {
      // Vault names are matched case-insensitively, so the mapping must not
      // rely on letter case to stay reversible: uppercase is escaped too.
      final name =
          KeyVaultSecretProvider.secretNameFor(const SecretRef('Passphrase'));
      expect(name, isNot(matches(RegExp('[A-Z]'))));
      expect(
          KeyVaultSecretProvider.refFor(name), const SecretRef('Passphrase'));
    });

    test('throws on an empty ref name', () {
      expect(
        () => KeyVaultSecretProvider.secretNameFor(const SecretRef('')),
        throwsArgumentError,
      );
    });

    test('throws when the mapped name exceeds the 127-char vault limit', () {
      // Each '.' costs three chars ('-2e'), so 43 dots map to 129 chars.
      final long = List.filled(43, '.').join();
      expect(
        () => KeyVaultSecretProvider.secretNameFor(SecretRef(long)),
        throwsArgumentError,
      );
    });

    test('refFor rejects a truncated escape', () {
      expect(
          () => KeyVaultSecretProvider.refFor('wisa-2'), throwsFormatException);
    });

    test('refFor rejects a non-hex escape', () {
      expect(() => KeyVaultSecretProvider.refFor('wisa-zzpw'),
          throwsFormatException);
    });
  });

  group('read', () {
    test('returns the value from a 200 secret bundle', () async {
      final transport = _FakeTransport(
          (_) => _ok({'value': 'hunter2', 'id': 'https://.../secrets/x/1'}));
      final value = await _provider(transport).read(
        const SecretRef('wisa.password'),
      );
      expect(value, 'hunter2');
    });

    test('returns null for an absent (404) secret', () async {
      final transport = _FakeTransport(
        (_) => const KeyVaultResponse(
          statusCode: 404,
          body: '{"error":{"code":"SecretNotFound","message":"not found"}}',
        ),
      );
      expect(
        await _provider(transport).read(const SecretRef('wisa.password')),
        isNull,
      );
    });

    test('throws KeyVaultException on a non-2xx, non-404 status', () async {
      final transport = _FakeTransport(
        (_) => const KeyVaultResponse(
          statusCode: 403,
          body: '{"error":{"code":"Forbidden","message":"denied"}}',
        ),
      );
      await expectLater(
        _provider(transport).read(const SecretRef('wisa.password')),
        throwsA(isA<KeyVaultException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.code, 'code', 'Forbidden')),
      );
    });

    test('GETs the escaped secret name with the api-version and bearer token',
        () async {
      final transport = _FakeTransport((_) => _ok({'value': 'v'}));
      await _provider(transport).read(const SecretRef('wisa.password'));

      final req = transport.requests.single;
      expect(req.method, 'GET');
      expect(req.url.host, 'accountmanager-kv.vault.azure.net');
      expect(req.url.path, '/secrets/wisa-2epassword');
      expect(req.url.queryParameters['api-version'],
          KeyVaultSecretProvider.defaultApiVersion);
      expect(req.headers['Authorization'], 'Bearer bearer-xyz');
      expect(req.body, anyOf(isNull, isEmpty));
    });
  });

  group('write', () {
    test('PUTs a {"value": ...} body as JSON and succeeds on 200', () async {
      final transport = _FakeTransport((_) => _ok({'value': 'hunter2'}));
      await _provider(transport)
          .write(const SecretRef('wisa.password'), 'hunter2');

      final req = transport.requests.single;
      expect(req.method, 'PUT');
      expect(req.url.path, '/secrets/wisa-2epassword');
      expect(req.headers['Content-Type'], 'application/json');
      expect(jsonDecode(req.body!), {'value': 'hunter2'});
    });

    test('throws KeyVaultException on a non-2xx status', () async {
      final transport =
          _FakeTransport((_) => const KeyVaultResponse(statusCode: 500));
      await expectLater(
        _provider(transport).write(const SecretRef('wisa.password'), 'x'),
        throwsA(isA<KeyVaultException>()),
      );
    });
  });

  group('delete', () {
    test('DELETEs the secret and succeeds on 200', () async {
      final transport = _FakeTransport((_) => _ok({'value': 'gone'}));
      await _provider(transport).delete(const SecretRef('wisa.password'));

      final req = transport.requests.single;
      expect(req.method, 'DELETE');
      expect(req.url.path, '/secrets/wisa-2epassword');
    });

    test('is a no-op on a 404 (nothing stored)', () async {
      final transport =
          _FakeTransport((_) => const KeyVaultResponse(statusCode: 404));
      await expectLater(
        _provider(transport).delete(const SecretRef('wisa.password')),
        completes,
      );
    });

    test('throws KeyVaultException on a non-2xx, non-404 status', () async {
      final transport =
          _FakeTransport((_) => const KeyVaultResponse(statusCode: 500));
      await expectLater(
        _provider(transport).delete(const SecretRef('wisa.password')),
        throwsA(isA<KeyVaultException>()),
      );
    });
  });

  group('auth', () {
    test('reads a fresh token for every request', () async {
      final tokens = _CountingTokenProvider();
      final transport = _FakeTransport((_) => _ok({'value': 'v'}));
      final provider = _provider(transport, tokens: tokens);

      await provider.read(const SecretRef('wisa.password'));
      await provider.write(const SecretRef('wisa.password'), 'v');
      await provider.delete(const SecretRef('wisa.password'));

      expect(tokens.calls, 3);
      expect(transport.requests.map((r) => r.headers['Authorization']), [
        'Bearer tok-1',
        'Bearer tok-2',
        'Bearer tok-3',
      ]);
    });

    test('close is safe when the transport was injected', () async {
      final transport = _FakeTransport((_) => _ok({'value': 'v'}));
      // Injected transport is the caller's to close; the provider must not
      // choke on close().
      expect(_provider(transport).close, returnsNormally);
    });
  });

  group('KeyVaultConfig', () {
    test('round-trips through JSON', () {
      expect(KeyVaultConfig.fromJson(_config.toJson()), _config);
    });

    test('value equality distinguishes the vault URI', () {
      expect(
        _config,
        isNot(const KeyVaultConfig(vaultUri: 'https://other.vault.azure.net/')),
      );
    });

    test('toString names the vault without a credential', () {
      expect(_config.toString(), contains('accountmanager-kv'));
    });
  });

  group('StaticKeyVaultTokenProvider', () {
    test('returns the injected token verbatim', () async {
      const provider = StaticKeyVaultTokenProvider('bearer-xyz');
      expect(await provider.vaultAccessToken(), 'bearer-xyz');
    });
  });

  group('KeyVaultResponse / KeyVaultException', () {
    test('json decodes an object body and treats an empty body as {}', () {
      expect(
        const KeyVaultResponse(statusCode: 200, body: '{"value":"v"}').json,
        {'value': 'v'},
      );
      expect(const KeyVaultResponse(statusCode: 204).json, isEmpty);
    });

    test('isSuccess and isNotFound classify the status', () {
      expect(const KeyVaultResponse(statusCode: 200).isSuccess, isTrue);
      expect(const KeyVaultResponse(statusCode: 404).isNotFound, isTrue);
      expect(const KeyVaultResponse(statusCode: 500).isSuccess, isFalse);
    });

    test('exception surfaces the vault error code and message', () {
      const ex = KeyVaultException(
        403,
        '{"error":{"code":"Forbidden","message":"denied by policy"}}',
      );
      expect(ex.code, 'Forbidden');
      expect(ex.message, 'denied by policy');
      expect(ex.toString(), contains('denied by policy'));
    });

    test('exception falls back to the raw body on a non-JSON error', () {
      const ex = KeyVaultException(502, 'Bad Gateway');
      expect(ex.code, isNull);
      expect(ex.toString(), contains('Bad Gateway'));
    });
  });
}
