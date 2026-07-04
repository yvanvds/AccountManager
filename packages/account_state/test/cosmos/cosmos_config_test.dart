import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

void main() {
  group('CosmosConfig', () {
    const config = CosmosConfig(
      endpoint:
          'https://accountmanager-cosmos-arcadia.documents.azure.com:443/',
      database: 'accountmanager',
    );

    test('round-trips through JSON', () {
      expect(CosmosConfig.fromJson(config.toJson()), equals(config));
    });

    test('value equality distinguishes endpoint and database', () {
      expect(
        config,
        isNot(equals(const CosmosConfig(
          endpoint: 'https://other.documents.azure.com/',
          database: 'accountmanager',
        ))),
      );
      expect(
        config,
        isNot(equals(const CosmosConfig(
          endpoint:
              'https://accountmanager-cosmos-arcadia.documents.azure.com:443/',
          database: 'other',
        ))),
      );
    });

    test('toString names the target without a credential', () {
      expect(config.toString(), contains('accountmanager'));
    });
  });

  group('StaticCosmosTokenProvider', () {
    test('returns the injected token verbatim', () async {
      const provider = StaticCosmosTokenProvider('bearer-xyz');
      expect(await provider.cosmosAccessToken(), 'bearer-xyz');
    });
  });

  group('CosmosLiveConfig.fromEnvironment', () {
    test('returns null when the access token is absent (offline default)', () {
      expect(CosmosLiveConfig.fromEnvironment(const {}), isNull);
      expect(
        CosmosLiveConfig.fromEnvironment(const {'COSMOS_ACCESS_TOKEN': '  '}),
        isNull,
      );
    });

    test('reads all three variables when the token is set', () {
      final config = CosmosLiveConfig.fromEnvironment(const {
        'COSMOS_ENDPOINT': 'https://acct.documents.azure.com:443/',
        'COSMOS_DATABASE': 'accountmanager',
        'COSMOS_ACCESS_TOKEN': 'tok',
      });
      expect(config, isNotNull);
      expect(config!.endpoint, 'https://acct.documents.azure.com:443/');
      expect(config.database, 'accountmanager');
      expect(config.accessToken, 'tok');
    });

    test('a set token with a missing required variable throws', () {
      expect(
        () => CosmosLiveConfig.fromEnvironment(const {
          'COSMOS_ACCESS_TOKEN': 'tok',
          'COSMOS_DATABASE': 'accountmanager',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
