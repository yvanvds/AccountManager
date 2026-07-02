/// Test helpers for `account_actions`: terse builders for linked records, a
/// default [StudentActionConfig], and recording fake connector transports so
/// `apply` can be driven without a network — a dry run asserts **zero** writes
/// and a real apply asserts the exact call plus the returned mutated record.
library;

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime _fixedDate = DateTime.utc(2020, 1, 1);

const Address blankAddress = Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

const Address sampleAddress = Address(
  street: 'Kerkstraat',
  houseNumber: '1',
  postalCode: '9000',
  city: 'Gent',
  country: 'België',
);

/// The default config used by the tests: prefix `SSM`, base domain
/// `school.example` (so student UPNs live under `student.school.example`), a
/// fixed password, and the default uid builder.
StudentActionConfig config({
  String schoolPrefix = 'SSM',
  String azureDomain = 'school.example',
}) =>
    StudentActionConfig(
      schoolPrefix: schoolPrefix,
      azureDomain: azureDomain,
      newAccountPassword: () => 'FakeP4ss!',
    );

wapi.WisaStudent wisaStudent({
  String wisaId = 'W1',
  String firstName = 'Jan',
  String name = 'Peeters',
  String preferredName = '',
  String classGroup = '3A',
  String stemId = '123',
  String nationalId = '',
  String birthPlace = 'Gent',
  Address address = sampleAddress,
}) =>
    wapi.WisaStudent(
      wisaId: WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '00',
      name: name,
      firstName: firstName,
      preferredName: preferredName,
      birthDate: _fixedDate,
      stemId: stemId,
      gender: Gender.male,
      nationalId: nationalId,
      birthPlace: birthPlace,
      nationality: '',
      address: address,
      classChange: _fixedDate,
      schoolId: 1,
    );

ss.SmartschoolAccount ssAccount({
  String uid = 'jan.peeters',
  String accountId = 'W1',
  String mail = 'jan.peeters@student.school.example',
  int stemId = 123,
  String preferredName = '',
  String birthPlace = 'Gent',
  Address address = sampleAddress,
  String status = 'actief',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: stemId,
      role: PersonRole.student,
      givenName: 'Jan',
      surname: 'Peeters',
      extraNames: '',
      initials: '',
      preferredName: preferredName,
      gender: Gender.male,
      birthDate: _fixedDate,
      birthPlace: birthPlace,
      birthCountry: '',
      address: address,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: status,
    );

az.AzureUser azureUser({
  String id = 'az-1',
  String upn = 'jan.peeters@student.school.example',
  String? employeeId = 'W1',
  String displayName = 'Jan Peeters',
  String? companyName = 'SSM',
  String? department = '3A',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: displayName,
      givenName: 'Jan',
      surname: 'Peeters',
      companyName: companyName,
      department: department,
    );

/// Builds a [LinkedAccount] from optional per-system records. Omit a system to
/// simulate it missing (drives the lifecycle-action branch).
LinkedAccount linked({
  wapi.WisaStudent? wisa,
  ss.SmartschoolAccount? smartschool,
  az.AzureUser? azure,
  String id = 'p0',
}) =>
    LinkedAccount(
      id: LinkedAccountId(id),
      role: PersonRole.student,
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      confidence: LinkConfidence.high,
    );

/// A fully-synced student present in all three systems with matching fields —
/// no student action should apply to it.
LinkedAccount fullySynced() => linked(
      wisa: wisaStudent(),
      smartschool: ssAccount(),
      azure: azureUser(),
    );

// ---------------------------------------------------------------------------
// Recording fake transports.
// ---------------------------------------------------------------------------

/// Records every Smartschool SOAP call and replies with a configurable integer
/// result (default `0` = success), so `apply` can run offline.
class RecordingSmartschoolTransport implements ss.SmartschoolSoapTransport {
  /// The `SOAPAction` header of every call, in order (contains the method
  /// name). Empty after a dry run.
  final List<String> soapActions = [];

  /// When set, the integer result to return (non-zero = failure). Applied to
  /// every write.
  final int resultCode;

  RecordingSmartschoolTransport({this.resultCode = 0});

  bool calledMethod(String method) =>
      soapActions.any((a) => a.contains(method));

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    soapActions.add(soapAction);
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope '
        'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><response><return>$resultCode</return></response>'
        '</soap:Body></soap:Envelope>';
  }
}

/// Records every Graph request and replies from an injected [handler] (default:
/// `204 No Content`, Graph's reply to PATCH/DELETE).
class RecordingGraphTransport implements az.GraphTransport {
  final List<az.GraphRequest> requests = [];
  final az.GraphResponse Function(az.GraphRequest request)? handler;

  RecordingGraphTransport({this.handler});

  bool sent(String method, {String? pathContains}) => requests.any(
        (r) =>
            r.method == method &&
            (pathContains == null || r.url.path.contains(pathContains)),
      );

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    if (handler != null) return handler!(request);
    return const az.GraphResponse(statusCode: 204);
  }
}

ss.SmartschoolConnector smartschoolConnector(
  RecordingSmartschoolTransport transport,
) =>
    ss.SmartschoolConnector.fromParts(
      site: 'demo',
      accessCode: 'secret',
      transport: transport,
    );

az.AzureConnector azureConnector(RecordingGraphTransport transport) =>
    az.AzureConnector(
      credentials: az.AzureCredentials(
        clientId: 'c',
        tenantId: 't',
        azureDomain: 'school.example',
        schoolPrefix: 'SSM',
      ),
      authProvider: const az.StaticAuthProvider('token'),
      transport: transport,
    );
