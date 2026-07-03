@Timeout(Duration(minutes: 1))
library;

import 'dart:convert';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Opt-in, **read-only** live check of the Azure SQL authentication foundation
/// (issue #82).
///
/// The Phase B database is AAD-only, so before any adapter can read or write it
/// an operator must be able to mint a bearer token scoped to the SQL resource
/// (`https://database.windows.net/`) against the real tenant. This test proves
/// exactly that half of the foundation from Dart: it drives the [
/// AadTokenProvider] seam over the supplied token and asserts the token is live
/// and correctly scoped. It performs **no** database write, honouring the repo
/// live-testing policy.
///
/// The full connect + write + read-back round-trip was proven by the
/// connectivity spike (`docs/port-plan.md`) and is re-exercised in Dart once
/// the ODBC/FFI adapter lands (#83), which is the first slice with a real DB
/// consumer.
///
/// Runs only when `AZURE_SQL_ACCESS_TOKEN` (+ server/database) is present;
/// otherwise it is skipped, so `dart test` stays offline by default.
void main() {
  final config = AzureSqlLiveConfig.fromEnvironment();

  group(
    'Azure SQL live (auth foundation, read-only)',
    () {
      test('the AAD token is scoped to the SQL resource and not expired',
          () async {
        final AadTokenProvider tokens =
            StaticAadTokenProvider(config!.accessToken);
        final token = await tokens.databaseAccessToken();

        final claims = _decodeJwtClaims(token);

        // Audience must be the Azure SQL resource, not Graph or another API.
        final audience = claims['aud'];
        expect(
          audience is String && audience.contains('database.windows.net'),
          isTrue,
          reason: 'token audience should be the SQL resource, got: $audience',
        );

        // Token must still be valid — a future `exp` (seconds since epoch).
        final exp = claims['exp'];
        expect(exp, isA<int>());
        final expiry = DateTime.fromMillisecondsSinceEpoch((exp as int) * 1000,
            isUtc: true);
        expect(
          expiry.isAfter(DateTime.now().toUtc()),
          isTrue,
          reason: 'token already expired at $expiry',
        );
      });
    },
    skip: config == null
        ? 'Set AZURE_SQL_ACCESS_TOKEN (+ AZURE_SQL_SERVER/DATABASE) to run.'
        : false,
  );
}

/// Decodes the claims (payload) segment of a JWT without verifying its
/// signature — enough to assert audience and expiry on a token we just minted.
Map<String, dynamic> _decodeJwtClaims(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) {
    throw FormatException(
        'not a JWT: expected 3 segments, got ${parts.length}');
  }
  final normalized = base64Url.normalize(parts[1]);
  final payload = utf8.decode(base64Url.decode(normalized));
  return jsonDecode(payload) as Map<String, dynamic>;
}
