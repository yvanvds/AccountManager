import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/passwords/password_backends.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:flutter_test/flutter_test.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;

/// A recording SOAP transport whose every write succeeds (return code 0).
class _RecordingSoap implements ss.SmartschoolSoapTransport {
  final List<String> actions = <String>[];

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    actions.add(soapAction);
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope '
        'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><response><return>0</return></response>'
        '</soap:Body></soap:Envelope>';
  }
}

/// A Graph transport that answers GETs (user lookup) from [userExists] and
/// records PATCHes (the password reset).
class _FakeGraph implements az.GraphTransport {
  _FakeGraph({required this.userExists});

  final bool userExists;
  final List<az.GraphRequest> patches = <az.GraphRequest>[];

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    if (request.method == 'GET') {
      return userExists
          ? const az.GraphResponse(
              statusCode: 200,
              body: '{"id":"az1","userPrincipalName":"jane@student.school"}',
            )
          : const az.GraphResponse(statusCode: 404);
    }
    patches.add(request);
    return const az.GraphResponse(statusCode: 204);
  }
}

ss.SmartschoolConnector _ss(ss.SmartschoolSoapTransport transport) =>
    ss.SmartschoolConnector.fromParts(
      site: 'demo',
      accessCode: 'secret',
      transport: transport,
    );

az.AzureConnector _az(az.GraphTransport transport) => az.AzureConnector(
      credentials: az.AzureCredentials(
        clientId: 'c',
        tenantId: 't',
        azureDomain: 'school.example',
        schoolPrefix: 'GBS',
      ),
      authProvider: const az.StaticAuthProvider('token'),
      transport: transport,
    );

void main() {
  group('ConnectorPasswordBackends (#180)', () {
    test('setSmartschoolPassword delegates to the connector savePassword',
        () async {
      final soap = _RecordingSoap();
      final backends = ConnectorPasswordBackends(smartschool: _ss(soap));
      final ok = await backends.setSmartschoolPassword(
          'jane', core.AccountType.coAccount1, 'Sw0rd!');
      expect(ok, isTrue);
      expect(soap.actions, isNotEmpty);
    });

    test('setAzurePassword looks the user up then PATCHes a new password',
        () async {
      final graph = _FakeGraph(userExists: true);
      final backends = ConnectorPasswordBackends(azure: _az(graph));
      final ok =
          await backends.setAzurePassword('jane@student.school', 'Sw0rd!');
      expect(ok, isTrue);
      expect(graph.patches, hasLength(1));
      expect(graph.patches.single.method, 'PATCH');
    });

    test('setAzurePassword skips (false) when the user does not exist',
        () async {
      final graph = _FakeGraph(userExists: false);
      final log = _CollectingLog();
      final backends = ConnectorPasswordBackends(azure: _az(graph), log: log);
      final ok = await backends.setAzurePassword('ghost@student.school', 'x');
      expect(ok, isFalse);
      expect(graph.patches, isEmpty);
      expect(log.errors, isNotEmpty);
    });

    test('a null connector makes the push a no-op that returns false',
        () async {
      final backends = ConnectorPasswordBackends();
      expect(
          await backends.setSmartschoolPassword(
              'x', core.AccountType.student, 'p'),
          isFalse);
      expect(await backends.setAzurePassword('x@school', 'p'), isFalse);
    });
  });
}

class _CollectingLog implements core.ILog {
  final List<String> errors = <String>[];

  @override
  void addError(core.Origin origin, String message) => errors.add(message);

  @override
  void addMessage(core.Origin origin, String message) {}
}
