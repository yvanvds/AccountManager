/// Shared offline fixtures for the reconcile widget and integration tests:
/// record/snapshot builders, recording transports (so a real action `apply`
/// runs with zero network), and a [ReconcileHarness] that assembles the real
/// State layer over scripted syncers.
///
/// The fixture scenario mirrors `account_state`'s `linked_state_test`: one
/// student fully linked across the three systems whose WISA class (3C)
/// differs from her Smartschool membership (2B), so the dispatchers derive
/// exactly one deterministic pending action (`MoveToSmartschoolClassGroup`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/passwords/password_backends.dart';
import 'package:account_manager/src/reconcile/log_buffer.dart';
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_manager/src/reconcile/reconcile_controller.dart';
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime kFixtureDate = DateTime.utc(2026, 7, 1);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

// ---------------------------------------------------------------------------
// Recording fake transports: a real action `apply()` runs offline while the
// test asserts exactly what was written (a dry run must record nothing).
// ---------------------------------------------------------------------------

class RecordingSoap implements ss.SmartschoolSoapTransport {
  final List<String> soapActions = <String>[];

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    soapActions.add(soapAction);
    // Every recorded write succeeds (return code 0).
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope '
        'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><response><return>0</return></response>'
        '</soap:Body></soap:Envelope>';
  }
}

class RecordingGraph implements az.GraphTransport {
  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// The bodies of every `POST /users` this transport accepted, in order — the
  /// accounts a create action actually asked Graph to make (#230).
  final List<Map<String, dynamic>> createdUsers = <Map<String, dynamic>>[];

  /// The bodies of every `POST /groups` this transport accepted, in order — the
  /// Office 365 class groups a create action actually asked Graph to make
  /// (#228).
  final List<Map<String, dynamic>> createdGroups = <Map<String, dynamic>>[];

  /// Every `$batch` sub-request this transport accepted, as `<METHOD> <url>` —
  /// the membership writes a class-group roster sync performs (#228/#245).
  final List<String> batchedWrites = <String>[];

  int _created = 0;

  /// A user PATCH/DELETE answers `204` the way Graph does, but a **create**
  /// reads before it writes: `AddStudentToAzure` first asks
  /// `employeeId in (…)` whether the person already has an account (#224), then
  /// `createPrincipalName` probes `users/<upn>` for each UPN candidate until one
  /// is free. This models an empty tenant — the collection reads come back
  /// empty, the single-user reads `404` — and echoes the created resource the
  /// way Graph does, so the whole create path runs offline (#230).
  ///
  /// Answering those GETs matters: a bare `204` decodes to an empty JSON object,
  /// which `AzureUser.fromGraphJson` happily turns into a user, so every UPN
  /// candidate would read as taken and `createPrincipalName` would spin forever.
  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    if (request.method == 'GET') {
      return _singleUserPath.hasMatch(request.url.path)
          ? const az.GraphResponse(
              statusCode: 404,
              headers: <String, String>{'content-type': 'application/json'},
              body: '{"error":{"code":"Request_ResourceNotFound",'
                  '"message":"Resource does not exist."}}',
            )
          : _ok(<String, dynamic>{'value': const <Object>[]}, statusCode: 200);
    }
    if (request.method == 'POST' && request.url.path.endsWith('/users')) {
      final body = Map<String, dynamic>.from(
        jsonDecode(request.body ?? '{}') as Map,
      );
      createdUsers.add(body);
      return _ok(
        <String, dynamic>{...body, 'id': 'az-created-${++_created}'},
        statusCode: 201,
      );
    }
    // An Office 365 class group create (#228). Like the user create it reads
    // first — `mailNickname eq …` to prove no group answers on that address —
    // which the collection branch above already answers empty.
    if (request.method == 'POST' && request.url.path.endsWith('/groups')) {
      final body = Map<String, dynamic>.from(
        jsonDecode(request.body ?? '{}') as Map,
      );
      createdGroups.add(body);
      return _ok(
        <String, dynamic>{
          ...body,
          'id': 'az-group-${++_created}',
          'mail': '${body['mailNickname']}@student.school.example',
        },
        statusCode: 201,
      );
    }
    // The membership writes ride in a `$batch`, and Graph answers with a
    // per-sub-request status list rather than a bare 204 (#228/#245).
    if (request.method == 'POST' && request.url.path.endsWith(r'/$batch')) {
      final body = Map<String, dynamic>.from(
        jsonDecode(request.body ?? '{}') as Map,
      );
      final subs = (body['requests'] as List).cast<Map<String, dynamic>>();
      for (final sub in subs) {
        batchedWrites.add('${sub['method']} ${sub['url']}');
      }
      return _ok(
        <String, dynamic>{
          'responses': <Map<String, dynamic>>[
            for (final sub in subs)
              <String, dynamic>{'id': sub['id'], 'status': 204},
          ],
        },
        statusCode: 200,
      );
    }
    return const az.GraphResponse(statusCode: 204);
  }

  /// `/v1.0/users/<id-or-upn>` — a read of one user, as opposed to the
  /// collection reads `/v1.0/users` and `/v1.0/users/delta`.
  static final RegExp _singleUserPath = RegExp(r'/users/(?!delta$)[^/]+$');

  static az.GraphResponse _ok(
    Map<String, dynamic> body, {
    required int statusCode,
  }) =>
      az.GraphResponse(
        statusCode: statusCode,
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

/// A [az.GraphTransport] that answers the way Graph does for a school whose
/// stored delta token is no longer usable (#213): resuming `/users/delta` from
/// it comes back
/// `400 Request_UnsupportedQuery — DeltaLink older than 30 days is not
/// supported.`, while the full-read path (`$deltatoken=latest` + the
/// `$filter`-scoped `/users` pull) succeeds and hands back [freshToken].
///
/// The users it serves are the harness's own Azure fixture, so a pass that
/// recovered lands the same linked view as a healthy one.
class StaleDeltaTokenGraph implements az.GraphTransport {
  StaleDeltaTokenGraph({
    this.freshToken = 'FRESH-DELTA-TOKEN',
    List<az.AzureUser>? users,
  }) : users = users ?? <az.AzureUser>[azUser()];

  /// The token the recovered full read primes for the next sync.
  final String freshToken;

  /// What the `$filter`-scoped bulk read returns.
  final List<az.AzureUser> users;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every delta token Graph was asked to resume from, in order — so a test can
  /// prove the dead one is not re-sent after the recovery.
  final List<String> resumeTokens = <String>[];

  /// How many `$filter`-scoped bulk reads ran.
  int bulkReads = 0;

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    final String path = request.url.path;
    if (path.contains('/members') || path.contains('groups')) {
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    if (path.contains('users/delta')) {
      final String? token = request.url.queryParameters[r'$deltatoken'];
      if (token == 'latest') return _deltaLink();
      resumeTokens.add(token ?? '');
      // A token this transport itself handed out is honoured, so a test can
      // prove the recovery really restored incremental syncing.
      if (token == freshToken) return _deltaLink();
      return az.GraphResponse(
        statusCode: 400,
        body: jsonEncode(<String, dynamic>{
          'error': <String, dynamic>{
            'code': 'Request_UnsupportedQuery',
            'message': 'DeltaLink older than 30 days is not supported.',
          },
        }),
      );
    }
    bulkReads++;
    return _ok(<String, dynamic>{
      'value': <Map<String, dynamic>>[
        for (final az.AzureUser u in users)
          <String, dynamic>{
            'id': u.id,
            'userPrincipalName': u.upn,
            if (u.employeeId != null) 'employeeId': u.employeeId,
            'displayName': u.displayName,
            'givenName': u.givenName,
            'surname': u.surname,
            if (u.companyName != null) 'companyName': u.companyName,
            if (u.department != null) 'department': u.department,
            'accountEnabled': u.accountEnabled,
          },
      ],
    });
  }

  /// An empty delta page closed by a deltaLink carrying [freshToken].
  az.GraphResponse _deltaLink() => _ok(<String, dynamic>{
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken='
                '$freshToken',
        'value': const <Object>[],
      });

  static az.GraphResponse _ok(Map<String, dynamic> body) => az.GraphResponse(
        statusCode: 200,
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

/// A [az.GraphTransport] answering the way the tenant answered in #224 (a
/// student) and #231 (a staff member): the school-scoped bulk read finds
/// **nothing** for someone who transferred in from a sibling group school, while
/// a targeted `employeeId in (…)` lookup turns up the Office 365 account they
/// already have.
///
/// That account is exactly what the operator found on Ambre Kalenga Alfio: our
/// `employeeId`, **no** `companyName`, a `department` still naming the school
/// they came from, and a UPN whose given/family-name order that school mangled —
/// so neither leg of the connector's `$filter` matches it and the UPN is no use
/// as a matching key either. A moved staff member's account is in the same
/// state; only the `department` text differs, which is what [department] is for.
///
/// Wire it into [ReconcileHarness.azureTransport] to drive the **production**
/// Azure pull, the only place the back-fill lives.
class TransferredAccountGraph implements az.GraphTransport {
  TransferredAccountGraph({
    this.employeeId = 'W7',
    this.upn = 'alfio.ambre@student.other.example',
    this.displayName = 'Alfio Ambre',
    this.department = 'OTHER-3A',
    this.deltaToken = 'AZ-TOKEN',
    this.visibleUsers = const <az.AzureUser>[],
  });

  /// The WISA id the existing account carries — the one usable matching key.
  /// For a student that is `WisaStudent.wisaId`; for a staff member the
  /// (nullable) `WisaStaff.wisaId`, never their `code`.
  final String employeeId;
  final String upn;
  final String displayName;

  /// The `department` the school they came from left on the account — never
  /// one of ours, which is the whole reason the `$filter` cannot see it.
  final String department;
  final String deltaToken;

  /// What the `$filter`-scoped bulk read returns. Empty by default: the whole
  /// point is that the transferred account is not among them.
  final List<az.AzureUser> visibleUsers;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every `employeeId in (…)` filter the connector issued, in order — so a
  /// test can prove it asked only about the ids it could not account for.
  final List<String> employeeIdLookups = <String>[];

  /// How many `$filter`-scoped bulk reads ran.
  int bulkReads = 0;

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    final String path = request.url.path;
    if (path.contains('/members') || path.contains('groups')) {
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    if (path.contains('users/delta')) {
      return _ok(<String, dynamic>{
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken='
                '$deltaToken',
        'value': const <Object>[],
      });
    }
    final String filter = request.url.queryParameters[r'$filter'] ?? '';
    if (filter.startsWith('employeeId in')) {
      employeeIdLookups.add(filter);
      return _ok(<String, dynamic>{
        'value': filter.contains("'$employeeId'")
            ? <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'az-transferred',
                  'userPrincipalName': upn,
                  'employeeId': employeeId,
                  'displayName': displayName,
                  // No companyName: the other school never stamped one, and
                  // ours was never stamped either.
                  'department': department,
                  'accountEnabled': true,
                },
              ]
            : const <Object>[],
      });
    }
    bulkReads++;
    return _ok(<String, dynamic>{
      'value': <Map<String, dynamic>>[
        for (final az.AzureUser u in visibleUsers)
          <String, dynamic>{
            'id': u.id,
            'userPrincipalName': u.upn,
            if (u.employeeId != null) 'employeeId': u.employeeId,
            if (u.companyName != null) 'companyName': u.companyName,
            'accountEnabled': u.accountEnabled,
          },
      ],
    });
  }

  static az.GraphResponse _ok(Map<String, dynamic> body) => az.GraphResponse(
        statusCode: 200,
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

/// A [wapi.WisaSoapTransport] serving a tiny, complete WISA export for one
/// school, so the **production** WISA pull (a real [wapi.WisaConnector] behind
/// the real `wisaSyncer`) runs offline.
///
/// Every query is answered with a well-formed CSV blob in the base64
/// `GetCSVDataResponse` envelope the connector decodes, and each request's
/// `QueryCode` + `Werkdatum` are recorded — which is the whole point: the
/// werkdatum an operator saves in Instellingen is only observable on the wire,
/// as the `Werkdatum` parameter of the row queries (#238).
///
/// Wire it into [ReconcileHarness.wisaTransport].
class RecordingWisaSoap implements wapi.WisaSoapTransport {
  RecordingWisaSoap({
    this.schools = const <(int, String, String)>[(1, 'School 1', 'S1')],
  });

  /// The schools `SMAGetInst` reports, as `(id, name, code)`.
  final List<(int, String, String)> schools;

  /// Every query issued, as `(queryCode, schoolId, werkdatum)` — the werkdatum
  /// exactly as it went on the wire (`dd/MM/yyyy`).
  final List<(String, String, String)> queries = <(String, String, String)>[];

  /// The distinct werkdatums the row queries (class groups / students / staff)
  /// were issued with, in order of first use. `SMAGetInst` carries none.
  List<String> get werkdatums => <String>{
        for (final q in queries)
          if (q.$3.isNotEmpty) q.$3,
      }.toList();

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final query = _tag.firstMatch(envelope)?.group(1) ?? '';
    final params = <String, String>{
      for (final m in _param.allMatches(envelope))
        m.group(1)!: m.group(2) ?? '',
    };
    queries.add((query, params['IS_ID'] ?? '', params['Werkdatum'] ?? ''));
    return _envelope(_csvFor(query));
  }

  String _csvFor(String query) => switch (query) {
        wapi.WisaQuery.getSchools => <String>[
            'ID,NAME,DESCRIPTION',
            for (final (id, name, code) in schools) '$id,$name,$code',
          ].join('\n'),
        wapi.WisaQuery.syncClassGroups =>
          'KLAS,KLASGROEP,OMSCHRIJVING,ADMINGROEP,INSTELLINGSNUMMER\n'
              '3C,00,Derde jaar C,a1,111',
        wapi.WisaQuery.syncStudents =>
          'KLAS,KLASGROEP,NAAM,VOORNAAM,ROEPNAAM,GEBOORTEDATUM,WISAID,'
              'STAMBOEKNUMMER,GESLACHT,RIJKSREGISTERNR,GEBOORTEPLAATS,'
              'NATIONALITEIT,STRAAT,STRAATNR,BUSNR,POSTCODE,WOONPLAATS,'
              'KLASWIJZIGING\n'
              '3C,,Doe,Jane,,1/7/2010,1,,V,,,,Straat,1,,2000,Antwerpen,'
              '1/9/2025',
        wapi.WisaQuery.syncStaff => 'CODE,WISAID,FAMILIENAAM,VOORNAAM',
        _ => '',
      };

  static String _envelope(String csv) {
    final encoded = base64.encode(latin1.encode(csv));
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<SOAP-ENV:Envelope '
        'xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">'
        '<SOAP-ENV:Body><NS1:GetCSVDataResponse '
        'xmlns:NS1="urn:WisaAPIService-WisaAPIService">'
        '<Result>$encoded</Result>'
        '</NS1:GetCSVDataResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>';
  }

  static final RegExp _tag = RegExp(r'<QueryCode[^>]*>([^<]*)</QueryCode>');
  static final RegExp _param =
      RegExp(r'<Name>([^<]*)</Name><Value[^>]*>([^<]*)</Value>');
}

/// A [az.GraphTransport] answering the way the tenant answered in #216: the
/// user lookup succeeds, and the `passwordProfile` PATCH that follows is
/// refused with `403 Authorization_RequestDenied`, because the app
/// registration was never granted `User-PasswordProfile.ReadWrite.All` (and
/// `User.ReadWrite.All` does not authorise that property).
///
/// Wire it into [ReconcileHarness.passwordGraph] to drive the **production**
/// password write path — real `ConnectorPasswordBackends` over a real
/// [az.AzureConnector] — so a refusal travels from Graph all the way to what
/// the Passwords screen puts on screen.
class PasswordWriteDeniedGraph implements az.GraphTransport {
  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// The PATCHes Graph refused.
  List<az.GraphRequest> get refusedWrites => <az.GraphRequest>[
        for (final r in requests)
          if (r.method == 'PATCH') r
      ];

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    if (request.method == 'GET') {
      return const az.GraphResponse(
        statusCode: 200,
        headers: <String, String>{'content-type': 'application/json'},
        body: '{"id":"az-anna","userPrincipalName":"anna@school"}',
      );
    }
    return const az.GraphResponse(
      statusCode: 403,
      headers: <String, String>{'content-type': 'application/json'},
      body: '{"error":{"code":"Authorization_RequestDenied",'
          '"message":"Insufficient privileges to complete the operation."}}',
    );
  }
}

/// A recording [PasswordBackends] for the on-demand Passwords screen (#180):
/// captures every live push a generation/reset would make and reports success,
/// so the reworked Passwords screen can be driven end-to-end with zero network.
/// A username in [failSmartschool] / mail in [failAzure] makes that push report
/// failure, exercising the controller's per-target failure handling.
class RecordingPasswordBackends implements PasswordBackends {
  RecordingPasswordBackends({
    this.failSmartschool = const <String>{},
    this.failAzure = const <String>{},
    this.denyAzure = const <String>{},
  });

  /// Smartschool usernames whose push should fail.
  final Set<String> failSmartschool;

  /// Azure mails/UPNs whose push should fail (models "no Azure account").
  final Set<String> failAzure;

  /// Azure mails/UPNs the directory *refuses* to write (#216): Graph answers
  /// `403 Authorization_RequestDenied` because the sign-in lacks
  /// `User-PasswordProfile.ReadWrite.All` or the operator holds no
  /// password-reset role. Distinct from [failAzure]: the account exists, the
  /// rights do not, and the operator must be told which.
  final Set<String> denyAzure;

  /// Every Smartschool push: `(uid, slot, password)`.
  final List<(String, core.AccountType, String)> smartschoolPushes =
      <(String, core.AccountType, String)>[];

  /// Every Azure push: `(mailOrUpn, password)`.
  final List<(String, String)> azurePushes = <(String, String)>[];

  @override
  Future<bool> setSmartschoolPassword(
    String uid,
    core.AccountType slot,
    String password,
  ) async {
    if (failSmartschool.contains(uid)) return false;
    smartschoolPushes.add((uid, slot, password));
    return true;
  }

  @override
  Future<bool> setAzurePassword(String mailOrUpn, String password) async {
    if (denyAzure.contains(mailOrUpn)) {
      throw az.AzurePasswordPermissionException(
        mailOrUpn,
        const az.GraphException(
          403,
          '{"error":{"code":"Authorization_RequestDenied",'
          '"message":"Insufficient privileges to complete the operation."}}',
        ),
      );
    }
    if (failAzure.contains(mailOrUpn)) return false;
    azurePushes.add((mailOrUpn, password));
    return true;
  }
}

// ---------------------------------------------------------------------------
// Record + snapshot builders.
// ---------------------------------------------------------------------------

/// A WISA student. [classSubGroup] is the raw `KLASGROEP` column: a real
/// sub-group code for a split class, or the `00` "no sub-groups" sentinel —
/// which must never end up in the student's class name (#221).
wapi.WisaStudent wisaStudent({
  String wisaId = '1',
  String classGroup = '3C',
  String classSubGroup = '',
  int schoolId = 1,
  core.Address address = _addr,
  // Most fixtures browse the tree by node rather than by person, so every
  // student is "Jane Doe" by default; a fixture that has to tell two students
  // apart on screen (#245) names them.
  String firstName = 'Jane',
  String name = 'Doe',
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: classSubGroup,
      name: name,
      firstName: firstName,
      preferredName: '',
      birthDate: kFixtureDate,
      stemId: '',
      gender: core.Gender.female,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: address,
      classChange: kFixtureDate,
      schoolId: schoolId,
    );

/// A WISA school, optionally flagged [ours] (the managed-school signal the
/// linker joins student `schoolId` against, #133/#134) and/or [virtual] (the
/// flag `markVirtualSchools` stamps before the pull, whose class groups the
/// linker refuses to seed, #209).
wapi.WisaSchool wisaSchool(int id, {bool ours = false, bool virtual = false}) =>
    wapi.WisaSchool(
      id: id,
      name: 'School $id',
      code: '',
      isOurs: ours,
      isVirtual: virtual,
    );

/// A WISA class group. [name] is the `fullName` the linker matches on;
/// [schoolId] decides whether the class belongs to a school we manage — a
/// sibling school's class must never reach the action engine (#205).
wapi.WisaClassGroup wisaClassGroup(
  String name, {
  String groupName = '00',
  String description = '',
  String adminCode = '',
  String schoolCode = '123',
  int schoolId = 1,
}) =>
    wapi.WisaClassGroup(
      name: name,
      groupName: groupName,
      description: description,
      adminCode: adminCode,
      schoolCode: schoolCode,
      schoolId: schoolId,
    );

/// A WISA staff record — the personeel counterpart of [wisaStudent]. A staff
/// member present only in WISA (no Smartschool / Azure counterpart) links as a
/// [core.LinkedStaff] and materializes into the synthetic "Personeel" school
/// rollup the Actions Personeel tab drills into (#179).
wapi.WisaStaff wisaStaff({
  String code = 'SMIT',
  String wisaId = '42',
  String firstName = 'Anna',
  String lastName = 'Smit',
}) =>
    wapi.WisaStaff(
      code: core.WisaStaffCode(code),
      wisaId: core.WisaId(wisaId),
      firstName: firstName,
      lastName: lastName,
    );

ss.SmartschoolAccount ssAccount({
  String uid = 'jane',
  String accountId = '1',
  String mail = 'jane.doe@student.school.example',
  String givenName = 'Jane',
  String surname = 'Doe',
  core.Address address = _addr,
  // A staff-role account is what the linker's `_buildStaffRecords` seeds a
  // LinkedStaff from; `fax` carries the zero-padded copy-code, so a fixture that
  // wants no SetStaffCopyCode must set it.
  core.PersonRole role = core.PersonRole.student,
  String fax = '',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: role,
      givenName: givenName,
      surname: surname,
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: address,
      mobilePhone: '',
      homePhone: '',
      fax: fax,
      untisId: '',
      status: 'actief',
    );

/// A Smartschool **staff** account — a teacher-role [ssAccount], the shape the
/// linker seeds a `LinkedStaff` from. The defaults line up with [wisaStaff] so a
/// complete staff record raises no Smartschool action of its own: `accountId` is
/// the WISA staff `code` and `fax` the zero-padded `wisaId`.
ss.SmartschoolAccount ssStaffAccount({
  String uid = 'anna.smit',
  String accountId = 'SMIT',
  String mail = 'anna.smit@school.example',
  String givenName = 'Anna',
  String surname = 'Smit',
  String fax = '0042',
}) =>
    ssAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      givenName: givenName,
      surname: surname,
      role: core.PersonRole.teacher,
      fax: fax,
    );

/// An Azure account. [displayName] is left empty by default, which is what most
/// fixtures want — it makes `ModifyAzureName` evaluate true, so the pass has an
/// action to show. A fixture that needs an account with **nothing** pending
/// (a class the Acties filter must hide, #226) passes the student's WISA
/// `fullName` here so the names already agree.
az.AzureUser azUser({
  String id = 'az1',
  String upn = 'jane.doe@student.school.example',
  String? employeeId = '1',
  String displayName = '',
  String givenName = '',
  String surname = '',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: displayName,
      givenName: givenName,
      surname: surname,
      companyName: 'GBS',
    );

core.Group ssGroup(
  String name, {
  String? code,
  bool official = true,
  core.GroupType type = core.GroupType.classGroup,
  String description = '',
  String? instituteNumber,
  String? untis,
}) =>
    core.Group(
      id: core.GroupId(code ?? name),
      name: name,
      description: description,
      type: type,
      official: official,
      instituteNumber: instituteNumber,
      // Untis defaults to blank — which reads as drift against the class name,
      // so most fixtures get a `ModifySmartschoolData` for free. Pass the name
      // to build a class that is genuinely in sync with WISA.
      untis: untis ?? '',
      origin: core.Origin.smartschool,
    );

ss.SmartschoolMembership member(String uid, String groupCode) =>
    ss.SmartschoolMembership(uid: uid, groupId: core.GroupId(groupCode));

wapi.WisaSnapshot wisaSnap({
  DateTime? fetchedAt,
  List<wapi.WisaStudent>? students,
  List<wapi.WisaStaff> staff = const [],
  List<wapi.WisaSchool> schools = const [],
  List<wapi.WisaClassGroup> classGroups = const [],
}) =>
    wapi.WisaSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
      students: students ?? [wisaStudent()],
      staff: staff,
      classGroups: classGroups,
      schools: schools,
    );

ss.SmartschoolSnapshot ssSnap({
  DateTime? fetchedAt,
  List<core.Group>? groups,
  List<ss.SmartschoolAccount>? accounts,
  List<ss.SmartschoolMembership>? memberships,
}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
      groups: groups ??
          [ssGroup('2B', code: '2B_ss'), ssGroup('3C', code: '3C_ss')],
      accounts: accounts ?? [ssAccount()],
      memberships: memberships ?? [member('jane', '2B_ss')],
    );

/// A Smartschool snapshot shaped for the reworked Passwords screen (#180): a
/// "Leerlingen" root holding one class (3C) with two students, and a
/// "Personeel" group with one staff member. Drives the on-demand generation /
/// reset flows end-to-end.
ss.SmartschoolSnapshot passwordsSnap() => ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: <core.Group>[
        const core.Group(
          id: core.GroupId('leerlingen'),
          name: 'Leerlingen',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
        const core.Group(
          id: core.GroupId('3C'),
          name: '3C',
          description: '',
          type: core.GroupType.classGroup,
          official: true,
          origin: core.Origin.smartschool,
          parentId: core.GroupId('leerlingen'),
        ),
        const core.Group(
          id: core.GroupId('personeel'),
          name: 'Personeel',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
      ],
      accounts: <ss.SmartschoolAccount>[
        ssAccount(uid: 'jane', accountId: '1', mail: 'jane@student.school'),
        ssAccount(uid: 'bob', accountId: '2', mail: 'bob@student.school'),
        ssAccount(uid: 'anna.smit', accountId: '3', mail: 'anna@school'),
      ],
      memberships: <ss.SmartschoolMembership>[
        member('jane', '3C'),
        member('bob', '3C'),
        member('anna.smit', 'personeel'),
      ],
    );

/// A Smartschool snapshot with a "Personeel" group holding three staff members
/// seeded **out of alphabetical order** and across mixed casing (Charlie/alice/
/// Bob) — the fixture for the Passwords personeel default-filter + sort rework
/// (#186). The controller must expose them sorted by the displayed "Voornaam
/// Naam" name (alice, Bob, Charlie) with voornaam as the default filter field.
ss.SmartschoolSnapshot staffOrderSnap() => ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: <core.Group>[
        ssGroup('Personeel', code: 'personeel', type: core.GroupType.group),
      ],
      accounts: <ss.SmartschoolAccount>[
        ssAccount(
            uid: 'charlie',
            accountId: '1',
            givenName: 'Charlie',
            surname: 'Zulu'),
        ssAccount(
            uid: 'alice', accountId: '2', givenName: 'alice', surname: 'Bravo'),
        ssAccount(
            uid: 'bob', accountId: '3', givenName: 'Bob', surname: 'Alpha'),
      ],
      memberships: <ss.SmartschoolMembership>[
        member('charlie', 'personeel'),
        member('alice', 'personeel'),
        member('bob', 'personeel'),
      ],
    );

/// A Smartschool snapshot whose [uids] accounts all share one [mail] — the
/// INV-23 duplicate-mail collision the reconcile screen surfaces (#109). No
/// WISA or Azure counterpart, so the linker keeps every colliding account and
/// raises exactly one [core.ResolveDuplicateMail] warning over them.
ss.SmartschoolSnapshot dupMailSnap({
  List<String> uids = const ['admin', 'user'],
  String mail = 'shared@school.example',
}) =>
    ssSnap(
      groups: const [],
      accounts: [
        for (final u in uids) ssAccount(uid: u, accountId: u, mail: mail),
      ],
      memberships: const [],
    );

/// A reconcile harness over the [dupMailSnap] collision: a WISA-/Azure-empty
/// scenario so the only linked artifact is the shared-mail warning (#109).
ReconcileHarness dupMailHarness({
  List<String> uids = const ['admin', 'user'],
  InMemoryLinkedStore? linkedStore,
  String syncedBy = 'operator@school.example',
}) =>
    ReconcileHarness(
      wisa: wisaSnap(students: const []),
      smartschool: dupMailSnap(uids: uids),
      azure: azSnap(users: const []),
      linkedStore: linkedStore,
      syncedBy: syncedBy,
    );

/// A reconcile harness over [count] WISA-departed, Smartschool-only active
/// accounts (no WISA, no Azure): each raises the mutually-exclusive
/// unregister/delete choice (#110), so the pending list holds [count] entries in
/// one "same situation" subset — a large set to exercise list virtualization
/// (#111).
ReconcileHarness manyDepartedHarness({
  int count = 2000,
  LinkedStore? controllerStore,
}) =>
    ReconcileHarness(
      controllerStore: controllerStore,
      wisa: wisaSnap(students: const []),
      smartschool: ssSnap(
        groups: const [],
        accounts: [
          for (var i = 0; i < count; i++)
            ssAccount(
              uid: 'user$i',
              accountId: '$i',
              mail: 'user$i@student.school.example',
            ),
        ],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );

/// A reconcile harness for the group-wide-leave keep-Azure case (#134): one
/// student still in *our* Smartschool and Azure, but whose WISA record now sits
/// only in a sibling group school (id 2) we don't manage — school 1 is flagged
/// ours. The dispatcher must raise the Smartschool departure (unregister/delete)
/// while **keeping** Azure (no `RemoveStudentFromAzure`).
ReconcileHarness movedToSiblingHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 2)],
        schools: [wisaSchool(1, ours: true), wisaSchool(2)],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser()]),
    );

/// A harness for the managed-schools-only Actions filter (#178). One student is
/// enrolled in school 2 and fully present in *our* Smartschool + Azure. The WISA
/// schools carry **no** `MarkAsOurs` flag, so the managed set comes solely from
/// [ourSchoolIds] (the persisted Settings path). Managing only school 1 leaves
/// the student `groupOnly` — kept out of the school tree (re-bucketed to "Niet
/// toegewezen"); adding school 2 to the managed set surfaces it under School 2.
ReconcileHarness managedSchoolsHarness({required Set<int> ourSchoolIds}) =>
    ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 2)],
        schools: [wisaSchool(1), wisaSchool(2)],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser()]),
      ourSchoolIds: ourSchoolIds,
    );

/// A harness for the school-less Actions drill-down (#210). Two managed schools
/// (1 and 2) each hold students, and their years overlap: school 1 has `1A` and
/// `3C`, school 2 has `1B` and the non-numeric `OKAN`. So a correct overview
/// shows one **merged** "Jaar 1" holding both schools' first years with combined
/// counts, a "Jaar 3", and a single non-numeric bucket — and no school node
/// anywhere, while each classroom keeps the school partition its accounts are
/// stored under.
ReconcileHarness twoSchoolHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          wisaStudent(wisaId: '2', classGroup: '3C'),
          wisaStudent(wisaId: '3', classGroup: '1B', schoolId: 2),
          wisaStudent(wisaId: '4', classGroup: 'OKAN', schoolId: 2),
        ],
        schools: [wisaSchool(1), wisaSchool(2)],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1, 2},
    );

/// A harness for the managed-school class-group scope (#205). WISA hands the
/// session class groups from two schools, and the sibling school's arrive
/// *first* in the pull: `1A` and `9Z` of school 2 (which we do not manage),
/// then our own `1A` of school 1. Each class holds a student, so before the fix
/// every one of them raised `AddToSmartschool` — a proposal to create another
/// school's class in *our* Smartschool — and the sibling `1A` even shadowed
/// ours, so the proposal described the wrong school's class. Only school 1 is
/// managed, from the persisted Settings set.
ReconcileHarness foreignClassGroupHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          wisaStudent(wisaId: '2', classGroup: '9Z', schoolId: 2),
        ],
        schools: [wisaSchool(1), wisaSchool(2)],
        classGroups: [
          wisaClassGroup(
            '1A',
            description: 'Klas van een andere school',
            schoolCode: '222',
            schoolId: 2,
          ),
          wisaClassGroup(
            '9Z',
            description: 'Ook van een andere school',
            schoolCode: '222',
            schoolId: 2,
          ),
          wisaClassGroup(
            '1A',
            description: 'Onze eerste klas',
            schoolCode: '111',
            schoolId: 1,
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
    );

/// A harness for the Office 365 class groups of #228. Our school 1 runs a
/// sub-grouped class `2F` (`2F ECO` + `2F MAW`, the shape of a 1ste-graad class)
/// and a plain class `1A`, all fully provisioned in Smartschool so the only work
/// left is on the Azure side.
///
/// Azure already holds `GBS-1A` with its student, so `1A` is done; `2F` has no
/// group at all. Four linked class-group records, **one** missing Office 365
/// group, so exactly one create proposal must reach the operator — named after
/// the parent class, never after a sub-group.
///
/// [withStaleGroup] adds `GBS-9Z`, the group of a class that no longer exists,
/// which must be reported for manual cleanup and never deleted.
ReconcileHarness azureClassGroupHarness({bool withStaleGroup = false}) =>
    ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          wisaStudent(wisaId: '2', classGroup: '2F', classSubGroup: 'ECO'),
          wisaStudent(wisaId: '3', classGroup: '2F', classSubGroup: 'MAW'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup('1A', description: 'Eerste jaar A'),
          wisaClassGroup('2F',
              groupName: 'ECO', adminCode: 'a', description: 'Tweede jaar F'),
          wisaClassGroup('2F',
              groupName: 'MAW', adminCode: 'b', description: 'Tweede jaar F'),
        ],
      ),
      smartschool: ssSnap(
        // In sync with their WISA counterparts, so the only work this fixture
        // raises is on the Office 365 side.
        groups: [
          ssGroup('1A',
              description: 'Eerste jaar A',
              instituteNumber: '123',
              untis: '1A'),
          ssGroup('2F ECO',
              description: 'Tweede jaar F',
              instituteNumber: '123',
              untis: '2F ECO'),
          ssGroup('2F MAW',
              description: 'Tweede jaar F',
              instituteNumber: '123',
              untis: '2F MAW'),
        ],
        accounts: [
          ssAccount(
              uid: 'jane', accountId: '1', mail: 'a1@student.school.example'),
          ssAccount(
              uid: 'joe', accountId: '2', mail: 'a2@student.school.example'),
          ssAccount(
              uid: 'jim', accountId: '3', mail: 'a3@student.school.example'),
        ],
        memberships: [
          member('jane', '1A'),
          member('joe', '2F ECO'),
          member('jim', '2F MAW'),
        ],
      ),
      azure: azSnap(
        users: [
          azUser(
              id: 'az1',
              upn: 'a1@student.school.example',
              employeeId: '1',
              displayName: 'Jane Doe'),
          azUser(
              id: 'az2',
              upn: 'a2@student.school.example',
              employeeId: '2',
              displayName: 'Jane Doe'),
          azUser(
              id: 'az3',
              upn: 'a3@student.school.example',
              employeeId: '3',
              displayName: 'Jane Doe'),
        ],
        groups: [
          azClassGroup('1A', memberIds: const ['az1']),
          if (withStaleGroup) azClassGroup('9Z'),
        ],
      ),
      ourSchoolIds: const {1},
    );

/// A harness for the **per-student** view of Office 365 class-group membership
/// (#245). Both classes already have their group, and both classes are in sync
/// between WISA and Smartschool, so the only work anywhere is the Azure roster:
///
/// - Jane's class is `1A` and `GBS-1A` exists, but she is not in it;
/// - Sam moved to `1B`, so he is missing from `GBS-1B` **and** still sitting in
///   `GBS-1A` — the "wrong class group" shape.
///
/// The class rows in Klasgroepen therefore carry the two applyable roster syncs,
/// and each student's own card carries the informational reading of the same
/// fact.
ReconcileHarness azureClassMembershipHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          wisaStudent(
            wisaId: '2',
            classGroup: '1B',
            firstName: 'Sam',
            name: 'Sels',
          ),
        ],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup('1A', description: 'Eerste jaar A'),
          wisaClassGroup('1B', description: 'Eerste jaar B'),
        ],
      ),
      smartschool: ssSnap(
        // In sync with WISA, so no class raises Smartschool work of its own.
        groups: [
          ssGroup('1A',
              description: 'Eerste jaar A',
              instituteNumber: '123',
              untis: '1A'),
          ssGroup('1B',
              description: 'Eerste jaar B',
              instituteNumber: '123',
              untis: '1B'),
        ],
        accounts: [
          ssAccount(
              uid: 'jane',
              accountId: '1',
              mail: 'jane.doe@student.school.example'),
          ssAccount(
            uid: 'sam',
            accountId: '2',
            mail: 'sam.sels@student.school.example',
            givenName: 'Sam',
            surname: 'Sels',
          ),
        ],
        // Smartschool already has both students in their WISA class, so no
        // `MoveToSmartschoolClassGroup` competes with the Azure reading.
        memberships: [member('jane', '1A'), member('sam', '1B')],
      ),
      azure: azSnap(
        users: [
          azUser(
            id: 'az1',
            upn: 'jane.doe@student.school.example',
            employeeId: '1',
            displayName: 'Jane Doe',
          ),
          azUser(
            id: 'az2',
            upn: 'sam.sels@student.school.example',
            employeeId: '2',
            displayName: 'Sam Sels',
          ),
        ],
        groups: [
          // Sam is in Jane's group; Jane is in nobody's.
          azClassGroup('1A', memberIds: const ['az2']),
          azClassGroup('1B'),
        ],
      ),
      ourSchoolIds: const {1},
    );

/// A harness for the virtual-school class-group exclusion (#209). Two managed
/// schools: our own school 1, and school 99 — the "Virtuele school" — which the
/// operator marks **both** beheerd and virtueel, exactly as the real config
/// does. That is why the #205 ownership filter alone never kept its classes out.
///
/// The virtual school contributes a populated class (`1V`, holding its own
/// student) and an empty one (`9V`), so before the fix the Klasgroepen list
/// carried an applyable "create this class in Smartschool" proposal *and* the
/// empty-class notice for classes nobody will ever use. Our own `1A` is
/// populated and must survive untouched, and the virtual school's student must
/// keep flowing and stay placed by their own `classGroup` string.
ReconcileHarness virtualClassGroupHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          wisaStudent(wisaId: '2', classGroup: '1V', schoolId: 99),
        ],
        schools: [
          wisaSchool(1, ours: true),
          wisaSchool(99, ours: true, virtual: true),
        ],
        classGroups: [
          wisaClassGroup(
            '1V',
            description: 'Virtuele klas',
            schoolCode: '999',
            schoolId: 99,
          ),
          wisaClassGroup(
            '9V',
            description: 'Lege virtuele klas',
            schoolCode: '999',
            schoolId: 99,
          ),
          wisaClassGroup(
            '1A',
            description: 'Onze eerste klas',
            schoolCode: '111',
            schoolId: 1,
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1, 99},
    );

/// A harness for the cross-school `containsStudents` pool (#222). Our school 1
/// has an **empty** `1A`; the sibling school 2 — which we do not manage, but
/// whose rows the shared WISA credentials pull anyway — has its own `1A` with a
/// student in it, and its class arrives *first* in the pull.
///
/// Only our own `1A` is linked (#205), so the Klasgroepen list holds exactly one
/// class. It must carry the informational "this WISA class has no students yet"
/// notice: before the fix the sibling school's student was pooled under the bare
/// name `1A`, so our empty class read as populated and was offered as the
/// applyable "Voeg deze klas toe aan Smartschool" — the action that also enrols
/// students into the class it creates.
ReconcileHarness siblingPopulatedClassHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: '2', classGroup: '1A', schoolId: 2)],
        schools: [wisaSchool(1), wisaSchool(2)],
        classGroups: [
          wisaClassGroup(
            '1A',
            description: 'Klas van een andere school',
            schoolCode: '222',
            schoolId: 2,
          ),
          wisaClassGroup(
            '1A',
            description: 'Onze lege eerste klas',
            schoolCode: '111',
            schoolId: 1,
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
    );

/// A harness for the class Smartschool already has (#225). Our school 1 has the
/// populated class `2G`; Smartschool holds `2G` too — under `2de Jaar`, beside
/// the classes it *did* flag official, and with the subgroup `2G LAT` hanging
/// under it — but the `2G` node itself is not flagged as an official class.
///
/// The official-class link skips it, correctly and (before #225) silently, so
/// the WISA class read as one nobody had created yet: the Klasgroepen list
/// offered "Voeg deze klas toe aan Smartschool", the applyable action that
/// would have asked Smartschool for a second class named `2G`. The subgroup, an
/// official class of its own with no WISA counterpart, keeps its own
/// Smartschool-only notice — that one is correct.
ReconcileHarness nonOfficialSmartschoolClassHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: '1', classGroup: '2G')],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup(
            '2G',
            description: '2e lj A Klassieke talen',
            schoolCode: '111',
            schoolId: 1,
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('2de Jaar',
              code: '2dejaar', official: false, type: core.GroupType.group),
          ssGroup('2G', code: 'G2G', official: false),
          ssGroup('2G LAT', code: 'C2GLAT'),
        ],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
    );

/// A harness for the start-of-year "new class" choice (#244). Our school 1 runs
/// two brand-new classes, `1A` and `1B`, each holding a student and neither
/// known to Smartschool — the shape that raised "Voeg deze klas toe aan
/// Smartschool" and "Negeer deze klas bij het importeren uit WISA" as two
/// independent to-dos on the same class. Both landed in the selection, so one
/// **Apply to all** created every new class of the year and then wrote a
/// `DontImportClass` rule on each name it had just created: the groups survived
/// in Smartschool, but the classes dropped out of the next WISA snapshot and
/// were no longer managed.
///
/// Two classes on purpose — that is what puts them in one "same situation"
/// subset and lights up the bulk **Apply to all** the report describes.
/// Smartschool holds only the `Leerlingen` root the classes hang under, named
/// by [ReconcileHarness.classTree], so the create actually lands.
ReconcileHarness newClassChoiceHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          wisaStudent(wisaId: '2', classGroup: '1B'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup(
            '1A',
            description: 'Onze eerste klas',
            schoolCode: '111',
            schoolId: 1,
          ),
          wisaClassGroup(
            '1B',
            description: 'Onze tweede klas',
            schoolCode: '111',
            schoolId: 1,
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup(
            'Leerlingen',
            code: 'SCHOOL',
            official: false,
            type: core.GroupType.group,
          ),
        ],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
      classTree: const SmartschoolClassTree(path: 'SCHOOL'),
    );

/// A harness for the "new staff member" choice (#248) — the staff twin of
/// [newClassChoiceHarness]. Two freshly hired teachers exist in WISA only, so
/// each raises `AddStaffToAzure` (which since #240 chains the Smartschool
/// create) **and** `DontImportStaffFromWisa` on the same target.
///
/// Neither declared an `alternativeGroup`, so both landed in the selection and
/// one click provisioned the teacher *and* wrote a `DontImportUserFromWisa` rule
/// on the very code it had just provisioned. The rule set is persisted and
/// re-applied on every WISA pull, so the next sync dropped the staff member the
/// operator had just given two accounts.
///
/// Two staff members on purpose — that is what puts them in one "same
/// situation" subset and lights up the bulk **Apply to all**.
ReconcileHarness newStaffChoiceHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: const [],
        staff: [
          wisaStaff(),
          wisaStaff(
            code: 'JANS',
            wisaId: '43',
            firstName: 'Bram',
            lastName: 'Jansen',
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );

/// A harness for the `00` sub-group sentinel (#221). Two managed schools that
/// each have their own `1C`, and each of those is a **single-group** class: one
/// `SyncKlas` row with `KLASGROEP = 00` and — because `ADMINGROEP` is only
/// unique within a school — a *different* `ADMINGROEP` from the other school's.
///
/// Both students are already in the Smartschool class `1C` their WISA record
/// names, so a correct pass proposes nothing. Before the fix the two schools'
/// admin codes pooled under the bare name `1C`, the class read as sub-grouped,
/// and each student's `KLASGROEP` was appended verbatim — so every student of
/// both classes was offered "Wijzig de klas in Smartschool: 1C → 1C 00", a move
/// into a class that exists nowhere.
ReconcileHarness subGroupSentinelHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1C', classSubGroup: '00'),
          wisaStudent(
            wisaId: '2',
            classGroup: '1C',
            classSubGroup: '00',
            schoolId: 2,
          ),
        ],
        schools: [wisaSchool(1), wisaSchool(2)],
        classGroups: [
          wisaClassGroup('1C', adminCode: 'a1', schoolCode: '111'),
          wisaClassGroup(
            '1C',
            adminCode: 'a2',
            schoolCode: '222',
            schoolId: 2,
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('1C', code: '1C_ss')],
        accounts: [
          ssAccount(),
          ssAccount(
            uid: 'jan',
            accountId: '2',
            mail: 'jan.peeters@student.school.example',
            givenName: 'Jan',
            surname: 'Peeters',
          ),
        ],
        memberships: [member('jane', '1C_ss'), member('jan', '1C_ss')],
      ),
      azure: azSnap(users: [
        azUser(),
        azUser(
          id: 'az2',
          upn: 'jan.peeters@student.school.example',
          employeeId: '2',
        ),
      ]),
      ourSchoolIds: const {1, 2},
    );

/// A harness for the school-label drill-down (#204). One student enrolled in
/// school 25 and fully present in *our* Smartschool + Azure, in a session whose
/// WISA snapshot carries **no** schools at all — the cold-snapshot case that
/// made every school node degrade to `School 25`. The school's identity comes
/// solely from the operator's persisted Settings profile (short code + long
/// name), so the Actions drill-down must still name it exactly as the Settings
/// grid does.
ReconcileHarness namedSchoolHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 25)],
        schools: const [],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser()]),
      ourSchoolIds: const {25},
      schoolProfiles: const [
        WisaSchoolProfile(
          schoolId: 25,
          code: 'ISMAA',
          name: 'Instituut Sancta Maria-A',
          ours: true,
        ),
      ],
    );

// ---------------------------------------------------------------------------
// Passive-session materialized-view fixtures for the Actions filter tests
// (#187): hand-built account docs so one classroom can hold a controlled mix of
// accounts with and without applyable actions and with distinct names, then
// seeded straight into an [InMemoryLinkedStore] a passive session reads back.
// ---------------------------------------------------------------------------

/// One [MaterializedAccount] for a passive-session classroom, placed in
/// [school]/[gradeYear]/[classroom]. [withAction] decides whether it carries an
/// applyable candidate — i.e. whether [MaterializedAccount.hasPending] is true,
/// the "has actions" predicate the toggle filters on.
MaterializedAccount matAccount({
  required String id,
  required String label,
  String school = '1',
  String schoolLabel = 'School 1',
  String gradeYear = '3',
  String classroom = '3C',
  bool isStaff = false,
  bool withAction = false,
}) =>
    MaterializedAccount(
      id: core.LinkedAccountId(id),
      school: school,
      schoolLabel: schoolLabel,
      gradeYear: gradeYear,
      classroom: classroom,
      role: isStaff ? core.PersonRole.teacher : core.PersonRole.student,
      isStaff: isStaff,
      confidence: core.LinkConfidence.high,
      label: label,
      inWisa: true,
      inSmartschool: true,
      inAzure: true,
      candidates: withAction
          ? <CandidateAction>[
              CandidateAction(
                family: isStaff ? 'staff' : 'student',
                kind: 'MoveToSmartschoolClassGroup',
                system: core.Origin.smartschool,
                summary: 'Wijzig de klas in Smartschool',
              ),
            ]
          : const <CandidateAction>[],
    );

/// A staff [MaterializedAccount] in the synthetic "Personeel" school/class the
/// Personeel tab drills into (all staff share one bucket).
MaterializedAccount matStaff({
  required String id,
  required String label,
  bool withAction = false,
}) =>
    matAccount(
      id: id,
      label: label,
      school: staffPartition,
      schoolLabel: 'Personeel',
      gradeYear: 'Personeel',
      classroom: 'Personeel',
      isStaff: true,
      withAction: withAction,
    );

/// An [InMemoryLinkedStore] seeded with [accounts] and their derived rollups —
/// the shared materialized view a passive Actions session reads with no pull and
/// no `link()` (#187).
Future<InMemoryLinkedStore> seededLinkedStore(
  List<MaterializedAccount> accounts, {
  String syncedBy = 'operator@school.example',
}) async {
  final store = InMemoryLinkedStore();
  await store.writeMaterialized(
    MaterializedView(
      generation: 1,
      accounts: accounts,
      rollups: buildRollups(accounts),
    ),
    syncedBy: syncedBy,
    at: kFixtureDate,
  );
  return store;
}

az.AzureSnapshot azSnap({
  DateTime? fetchedAt,
  List<az.AzureUser>? users,
  List<az.AzureGroup> groups = const [],
  String? deltaToken,
}) =>
    az.AzureSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
      deltaToken: deltaToken,
      users: users ?? [azUser()],
      groups: groups,
    );

/// An Office 365 **class** group as this app creates one (#228): a mail-enabled
/// unified group whose display name and mail nickname are both `GBS-<class>`.
az.AzureGroup azClassGroup(
  String className, {
  List<String> memberIds = const [],
}) =>
    az.AzureGroup(
      id: 'az-GBS-$className',
      displayName: 'GBS-$className',
      mail: 'GBS-$className@student.school.example',
      mailNickname: 'GBS-$className',
      memberIds: memberIds,
    );

/// Deterministic in-memory resolver (mirrors the linker's test fixture).
class SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = <String, String>{};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

/// An in-memory [SnapshotStore] shared across two "sessions" of a test, so a
/// second [ReconcileHarness] can seed from what the first persisted (#107). The
/// Cosmos+Blob overflow behaviour is covered by `account_state`'s unit tests;
/// here only the seed/reuse/drift wiring matters.
class InMemorySnapshotStore implements SnapshotStore {
  final Map<core.Origin, StoredSnapshot> _byOrigin = {};

  /// Which systems currently have a stored snapshot — for test assertions.
  Iterable<core.Origin> get storedSystems => _byOrigin.keys;

  StoredSnapshot? peek(core.Origin system) => _byOrigin[system];

  @override
  Future<StoredSnapshot?> load(core.Origin system) async => _byOrigin[system];

  @override
  Future<void> save(
    core.Origin system, {
    required Map<String, dynamic> payload,
    required DateTime fetchedAt,
    required String syncedBy,
    String? deltaToken,
  }) async {
    _byOrigin[system] = StoredSnapshot(
      payload: payload,
      fetchedAt: fetchedAt,
      syncedBy: syncedBy,
      deltaToken: deltaToken,
    );
  }
}

/// A [LinkedStore] whose [writeMaterialized] never completes (a hung Cosmos
/// write) or throws, while every read delegates to an inner [InMemoryLinkedStore]
/// — the persist-stall the reconcile controller must survive (#168).
class StallingLinkedStore implements LinkedStore {
  StallingLinkedStore({InMemoryLinkedStore? inner, this.failWith})
      : _in = inner ?? InMemoryLinkedStore();

  final InMemoryLinkedStore _in;

  /// When set, [writeMaterialized] throws this instead of hanging.
  final Object? failWith;

  /// True once a write was attempted — proves the controller reached persist.
  bool writeAttempted = false;

  @override
  Future<void> writeMaterialized(
    MaterializedView view, {
    required String syncedBy,
    required DateTime at,
    List<AccountDecision> droppedDecisions = const [],
    Map<core.Origin, SystemSyncMeta> systemSyncs = const {},
    void Function(String message)? onProgress,
  }) {
    writeAttempted = true;
    final fail = failWith;
    if (fail != null) return Future<void>.error(fail);
    // Never completes: models a wedged store write the controller must time out.
    return Completer<void>().future;
  }

  @override
  Future<SyncState> readSyncState() => _in.readSyncState();
  @override
  Future<List<Rollup>> readRollups() => _in.readRollups();
  @override
  Future<List<MaterializedAccount>> readClassroom({
    required String school,
    required String classroom,
  }) =>
      _in.readClassroom(school: school, classroom: classroom);
  @override
  Future<List<MaterializedGroup>> readGroups() => _in.readGroups();
  @override
  Future<List<AccountDecision>> readDecisions() => _in.readDecisions();
  @override
  Future<void> putDecision(AccountDecision decision) =>
      _in.putDecision(decision);
  @override
  Future<void> deleteDecision(AccountDecision decision) =>
      _in.deleteDecision(decision);
  @override
  Future<void> recordSystemSync(Map<core.Origin, SystemSyncMeta> systemSyncs) =>
      _in.recordSystemSync(systemSyncs);
  @override
  Future<SyncLease?> readLease(DateTime now) => _in.readLease(now);
  @override
  Future<LeaseOutcome> acquireLease({
    required String owner,
    required DateTime now,
  }) =>
      _in.acquireLease(owner: owner, now: now);
  @override
  Future<LeaseOutcome> renewLease({
    required String owner,
    required DateTime now,
  }) =>
      _in.renewLease(owner: owner, now: now);
  @override
  Future<void> releaseLease({required String owner}) =>
      _in.releaseLease(owner: owner);
}

/// A [CosmosTransport] serving a tiny in-memory Cosmos data plane that answers
/// a stretch of the write burst with **429 TooManyRequests** — the shared-store
/// persist of #196 without an account.
///
/// Enough of the wire is modelled for the real [HttpCosmosClient] and
/// [CosmosLinkedStore] to run against it unchanged (point reads, upserts,
/// atomic creates, deletes, and the `SELECT`s the store issues), so a test can
/// drive the *production* persist path end-to-end and watch a throttled write
/// burst either survive or leave the containers half-written.
class ThrottlingCosmosWire implements CosmosTransport {
  ThrottlingCosmosWire({
    this.throttleFrom = 30,
    this.throttleUntil = 120,
    this.retryAfterMs = 5,
  });

  /// Write attempt (1-based) from which the account starts throttling, and the
  /// one after which it stops. Every attempt — retries included — advances the
  /// counter, so the burst drains the window the way a real recovery does.
  final int throttleFrom;
  final int throttleUntil;

  /// What the 429 puts in `x-ms-retry-after-ms`. Tiny, because the client's
  /// sleep is collapsed to nothing in tests anyway.
  final int retryAfterMs;

  final Map<String, Map<String, Map<String, dynamic>>> _docs = {};

  /// Every document write the client attempted, retries included.
  int writeAttempts = 0;

  /// Accepted document writes per container (retries and 429s excluded) — what
  /// the account was actually asked to store, so a test can tell a pass that
  /// rewrote the world from one that wrote only what changed (#200).
  final Map<String, int> writesByContainer = {};

  int writesTo(String container) => writesByContainer[container] ?? 0;

  /// How many of those were answered with a 429.
  int throttledResponses = 0;

  int _etag = 0;

  /// How many documents the container holds — what the shared state actually
  /// ended up with.
  int docCount(String container) => _docs[container]?.length ?? 0;

  Map<String, Map<String, dynamic>> _c(String name) =>
      _docs.putIfAbsent(name, () => {});

  @override
  Future<CosmosResponse> send(CosmosRequest request) async {
    // A real round trip is async, so writes genuinely overlap and the bounded
    // fan-out is exercised rather than collapsing to a serial loop.
    await Future<void>.delayed(Duration.zero);
    final segments = request.url.pathSegments;
    final container = segments.length > 3 ? segments[3] : '';
    final isQuery = request.headers['x-ms-documentdb-isquery'] == 'true';
    switch (request.method) {
      case 'POST' when isQuery:
        return _query(container, request);
      case 'POST' when segments.length >= 5:
        return _write(container, request);
      case 'POST':
        return const CosmosResponse(statusCode: 201, body: '{}');
      case 'GET' when segments.length >= 6:
        final doc = _c(container)[segments[5]];
        return doc == null
            ? const CosmosResponse(statusCode: 404)
            : CosmosResponse(statusCode: 200, body: jsonEncode(doc));
      case 'GET':
        return const CosmosResponse(statusCode: 200, body: '{}');
      case 'DELETE' when segments.length >= 6:
        final gone = _c(container).remove(segments[5]);
        return CosmosResponse(statusCode: gone == null ? 404 : 204);
    }
    return const CosmosResponse(statusCode: 400);
  }

  CosmosResponse _write(String container, CosmosRequest request) {
    writeAttempts++;
    if (writeAttempts >= throttleFrom && writeAttempts <= throttleUntil) {
      throttledResponses++;
      return CosmosResponse(
        statusCode: 429,
        headers: {'x-ms-retry-after-ms': '$retryAfterMs'},
        body: '{"code":"TooManyRequests","message":"The request rate is too '
            'large. Please retry after sometime."}',
      );
    }
    final decoded = jsonDecode(request.body ?? '{}');
    final doc = Map<String, dynamic>.from(decoded as Map);
    final id = doc['id'] as String;
    final store = _c(container);
    final isUpsert = request.headers['x-ms-documentdb-is-upsert'] == 'true';
    // An atomic create loses to whoever got there first — what the sync lease
    // relies on.
    if (!isUpsert && store.containsKey(id)) {
      return const CosmosResponse(
        statusCode: 409,
        body: '{"code":"Conflict","message":"id already exists"}',
      );
    }
    final etag = 'etag-${++_etag}';
    writesByContainer[container] = writesTo(container) + 1;
    store[id] = {...doc, '_etag': etag};
    return CosmosResponse(
      statusCode: isUpsert ? 200 : 201,
      headers: {'etag': etag},
      body: jsonEncode(store[id]),
    );
  }

  CosmosResponse _query(String container, CosmosRequest request) {
    final body = Map<String, dynamic>.from(
      jsonDecode(request.body ?? '{}') as Map,
    );
    final query = body['query'] as String? ?? '';
    final parameters = <String, Object?>{
      for (final p in (body['parameters'] as List? ?? const []))
        (p as Map)['name'] as String: p['value'],
    };
    final pkHeader = request.headers['x-ms-documentdb-partitionkey'];
    final pk = pkHeader == null
        ? null
        : (jsonDecode(pkHeader) as List).first as String;
    var rows = <Map<String, dynamic>>[
      for (final d in _c(container).values)
        if (pk == null || d['pk'] == pk) Map<String, dynamic>.from(d),
    ];
    if (query.contains('c.classroom = @classroom')) {
      final want = parameters['@classroom'];
      rows = [
        for (final d in rows)
          if (d['classroom'] == want) d
      ];
    }
    if (query.contains('SELECT c.id, c.pk')) {
      // A projection returns the named fields only — including the content hash
      // the store compares against (#200), absent where the document has none.
      rows = [
        for (final d in rows)
          {
            'id': d['id'],
            'pk': d['pk'],
            if (query.contains('c.$contentHashField') &&
                d.containsKey(contentHashField))
              contentHashField: d[contentHashField],
          },
      ];
    }
    return CosmosResponse(
      statusCode: 200,
      body: jsonEncode({'Documents': rows}),
    );
  }
}

/// The *production* shared-store write path over [wire]: a real
/// [CosmosLinkedStore] on a real [HttpCosmosClient], sharing [governor] exactly
/// as `bootstrapReconcile` wires them (#196). The retry sleep is collapsed to
/// nothing so a throttled persist is exercised with no wall-clock waiting.
CosmosLinkedStore cosmosLinkedStoreOver(
  ThrottlingCosmosWire wire, {
  required CosmosThrottleGovernor governor,
}) =>
    CosmosLinkedStore(
      HttpCosmosClient(
        config: const CosmosConfig(
          endpoint: 'https://fake.documents.azure.com:443/',
          database: 'accountmanager',
        ),
        transport: wire,
        tokens: const StaticCosmosTokenProvider('fake-token'),
        governor: governor,
        sleep: (_) async {},
      ),
      governor: governor,
    );

// ---------------------------------------------------------------------------
// The harness: the real State layer over scripted syncers.
// ---------------------------------------------------------------------------

/// The real [StateApplier] with one seam: an optional [gate] awaited before
/// every action a pass runs (#243).
///
/// A dry-run touches no connector and a scripted apply answers on the microtask
/// queue, so an entire pass otherwise completes inside a single `tester.pump()`
/// — leaving no frame in which the modal progress dialog exists to be asserted
/// on. Parking on the gate freezes the pass exactly where the operator sees it:
/// mid-flight, on a named account and a named action.
///
/// With no gate wired this is the plain applier, so the harness builds it
/// unconditionally rather than duplicating the (long) construction twice.
class GatedApplier extends StateApplier {
  GatedApplier({
    required this.gate,
    required super.app,
    required super.connectors,
    required super.resolver,
    required super.wisaRules,
    required super.studentConfig,
    required super.staffConfig,
    super.classTree,
    super.passwordQueue,
    super.ourSchoolIds,
  });

  /// Awaited before each action; `null` for the ordinary harness.
  final Future<void> Function()? gate;

  Future<void> _park() async {
    final g = gate;
    if (g != null) await g();
  }

  @override
  Future<ApplyResult> applyStudent(
    actions.StudentAction action, {
    actions.ApplyOptions options = const actions.ApplyOptions(),
  }) async {
    await _park();
    return super.applyStudent(action, options: options);
  }

  @override
  Future<ApplyResult> applyStaff(
    actions.StaffAction action, {
    actions.ApplyOptions options = const actions.ApplyOptions(),
  }) async {
    await _park();
    return super.applyStaff(action, options: options);
  }

  @override
  Future<ApplyResult> applyGroup(
    actions.GroupAction action, {
    actions.ApplyOptions options = const actions.ApplyOptions(),
  }) async {
    await _park();
    return super.applyGroup(action, options: options);
  }
}

/// One assembled reconcile stack against fakes: scripted per-system syncers
/// (with call counters), a [StateApplier] wired to recording connectors, and
/// the [ReconcileController] under test.
class ReconcileHarness {
  ReconcileHarness({
    wapi.WisaSnapshot? wisa,
    ss.SmartschoolSnapshot? smartschool,
    az.AzureSnapshot? azure,
    this.store,
    InMemoryLinkedStore? linkedStore,
    this.controllerStore,
    this.persistTimeout,
    this.hub,
    SignalPublisher? publisher,
    SignalSubscriber? subscriber,
    wapi.WisaSnapshot? wisaInitial,
    ss.SmartschoolSnapshot? ssInitial,
    az.AzureSnapshot? azureInitial,
    this.azureGate,
    this.applyGate,
    this.azureTransport,
    this.smartschoolTransport,
    this.smartschoolRules = const <ss.SmartschoolImportRule>[],
    this.classTree = const SmartschoolClassTree(),
    this.wisaTransport,
    this.passwordGraph,
    this.syncedBy = 'operator@school.example',
    Set<int>? ourSchoolIds,
    List<WisaSchoolProfile> schoolProfiles = const <WisaSchoolProfile>[],
    this.settingsStore,
    LiveSettings? liveSettings,
  })  : wisaResult = (wisa ?? wisaSnap()),
        ssResult = (smartschool ?? ssSnap()),
        azResult = (azure ?? azSnap()),
        liveSettings = liveSettings ?? LiveSettings(),
        linkedStore = linkedStore ?? InMemoryLinkedStore() {
    log = LogBuffer(clock: () => kFixtureDate);
    final wisaRules = WisaImportRules();

    // The scripted per-system pulls (with call counters). When a [store] is
    // wired, each is wrapped so a successful pull persists — mirroring how
    // bootstrap composes persistence over the real syncers (#107).
    //
    // The WISA pull. Scripted by default; wiring a [wisaTransport] swaps in the
    // *production* pull instead — a real [wapi.WisaConnector] behind the real
    // [wisaSyncer], reading the werkdatum pair and virtual marks live from
    // [liveSettings] exactly as `bootstrapReconcile` composes them. That is the
    // only way a test can save a werkdatum in Instellingen and then see which
    // one the next Synchroniseer actually asked WISA for (#238).
    final wisaWire = wisaTransport;
    Syncer<wapi.WisaSnapshot> wisaSync;
    if (wisaWire != null) {
      final inner = wisaSyncer(
        wapi.WisaConnector.fromParts(
          server: 'wisa.example',
          port: 9000,
          database: 'wisadb',
          username: 'operator',
          password: 'geheim',
          transport: wisaWire,
          log: log,
        ),
        settings: this.liveSettings,
        rules: wisaRules,
        // The same LogBuffer the connector writes into, so the werkdatum line
        // the pass announces (#239) lands in the harness log beside the
        // per-school lines — and beside what `RecordingWisaSoap` saw go out.
        log: log,
        clock: () => kFixtureDate,
      );
      wisaSync = (previous) async {
        wisaSyncs++;
        final error = wisaError;
        if (error != null) throw error;
        return inner(previous);
      };
    } else {
      wisaSync = (_) async {
        wisaSyncs++;
        final error = wisaError;
        if (error != null) throw error;
        return wisaResult;
      };
    }
    // The Smartschool pull. Scripted by default; wiring a
    // [smartschoolTransport] swaps in the *production* pull instead — a real
    // [ss.SmartschoolConnector] over that SOAP wire, applying
    // [smartschoolRules] and logging into this harness's LogBuffer exactly as
    // `bootstrapReconcile` composes it (`ssConnector.sync(rules:
    // settings.smartschoolRules)`). That is the only way a test can drive the
    // operator's own import rules through the pass they trigger, and see what
    // the Log panel then tells them (#241).
    final ssTransport = smartschoolTransport;
    Syncer<ss.SmartschoolSnapshot> ssSync;
    if (ssTransport != null) {
      final connector = ss.SmartschoolConnector.fromParts(
        site: 'demo',
        accessCode: 'secret',
        transport: ssTransport,
        log: log,
      );
      ssSync = (_) async {
        ssSyncs++;
        return connector.sync(rules: smartschoolRules);
      };
    } else {
      ssSync = (_) async {
        ssSyncs++;
        return ssResult;
      };
    }
    // The Azure pull. By default it is scripted like the other two; wiring an
    // [azureTransport] swaps in the *production* pull instead — a real
    // [az.AzureConnector] behind the real [azureSyncer], logging into this
    // harness's LogBuffer exactly as `bootstrapReconcile` composes them. That
    // is the only way a test can drive Graph's own answers (a rejected delta
    // token, #213) through the pass the operator triggers.
    final azureTransport = this.azureTransport;
    Syncer<az.AzureSnapshot> azSync;
    if (azureTransport != null) {
      final inner = azureSyncer(
        az.AzureConnector(
          credentials: az.AzureCredentials(
            clientId: 'c',
            tenantId: 't',
            azureDomain: 'school.example',
            schoolPrefix: 'GBS',
          ),
          authProvider: const az.StaticAuthProvider('token'),
          transport: azureTransport,
          log: log,
        ),
        // Exactly as `bootstrapReconcile` composes it (#224 students, #231
        // staff): the ids this pass expects Azure accounts for come from both
        // populations of the WISA snapshot the same ApplicationState pulled
        // moments earlier.
        expectedEmployeeIds: () => <String>{
          ...managedStudentEmployeeIds(
            app.wisa.snapshot,
            ourSchoolIds: ourSchoolIds,
          ),
          ...managedStaffEmployeeIds(app.wisa.snapshot),
        },
      );
      azSync = (previous) async {
        azSyncs++;
        return inner(previous);
      };
    } else {
      azSync = (_) async {
        azSyncs++;
        // When a test wires a gate, the Azure pull parks here until released,
        // so a widget test can hold a sync mid-flight and observe the busy
        // progress bar the earlier stages have already advanced (#176).
        final gate = azureGate;
        if (gate != null) await gate.future;
        return azResult;
      };
    }

    final s = store;
    if (s != null) {
      wisaSync = persistingSyncer<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        store: s,
        syncedBy: syncedBy,
        payloadOf: (snap) => snap.toJson(),
        inner: wisaSync,
      );
      ssSync = persistingSyncer<ss.SmartschoolSnapshot>(
        system: core.Origin.smartschool,
        store: s,
        syncedBy: syncedBy,
        payloadOf: (snap) => snap.toJson(),
        inner: ssSync,
      );
      azSync = persistingSyncer<az.AzureSnapshot>(
        system: core.Origin.azure,
        store: s,
        syncedBy: syncedBy,
        payloadOf: (snap) => snap.toJson(),
        deltaTokenOf: (snap) => snap.deltaToken,
        inner: azSync,
      );
    }

    app = ApplicationState(
      wisa: SystemState<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        initial: wisaInitial,
        syncer: wisaSync,
      ),
      smartschool: SystemState<ss.SmartschoolSnapshot>(
        system: core.Origin.smartschool,
        initial: ssInitial,
        syncer: ssSync,
      ),
      azure: SystemState<az.AzureSnapshot>(
        system: core.Origin.azure,
        initial: azureInitial,
        syncer: azSync,
      ),
    );

    applier = GatedApplier(
      // Null unless a test wants the pass frozen mid-flight (#243); with no
      // gate this is the plain StateApplier the app wires.
      gate: applyGate,
      app: app,
      connectors: actions.Connectors(
        smartschool: ss.SmartschoolConnector.fromParts(
          site: 'demo',
          accessCode: 'secret',
          transport: soap,
        ),
        azure: az.AzureConnector(
          credentials: az.AzureCredentials(
            clientId: 'c',
            tenantId: 't',
            azureDomain: 'school.example',
            schoolPrefix: 'GBS',
          ),
          authProvider: const az.StaticAuthProvider('token'),
          transport: graph,
        ),
      ),
      resolver: SeqResolver(),
      wisaRules: wisaRules,
      // The Smartschool group tree a freshly created class hangs under. Left
      // unconfigured by default (no parent resolves, as in a bare tenant); a
      // fixture that applies `AddToSmartschool` for real names the root here.
      classTree: classTree,
      studentConfig: actions.StudentActionConfig(
        schoolPrefix: 'GBS',
        azureDomain: 'school.example',
      ),
      staffConfig: actions.StaffActionConfig(
        schoolPrefix: 'GBS',
        azureDomain: 'school.example',
      ),
      passwordQueue: passwordQueue,
      // The operator's managed-school set from Settings (#178). When unset, the
      // linker falls back to the WISA snapshot's MarkAsOurs flags, as bootstrap
      // does for a not-yet-configured group.
      ourSchoolIds: ourSchoolIds,
    );

    final signalHub = hub;
    controller = ReconcileController(
      app: app,
      applier: applier,
      log: log,
      store: controllerStore ?? this.linkedStore,
      syncedBy: syncedBy,
      // The operator's curated WISA schools from Settings, which name every
      // school in the Actions drill-down (#204), and the document they live in
      // so a pull can fill their names back in (#207).
      schoolProfiles: schoolProfiles,
      settingsStore: settingsStore,
      // The same holder the WISA pull reads, so the drift gate sees a save the
      // moment Instellingen publishes it (#238).
      liveSettings: this.liveSettings,
      publisher: publisher ?? signalHub?.publisher(),
      subscriber: subscriber ?? signalHub?.subscriber(),
      persistTimeout: persistTimeout ?? const Duration(minutes: 10),
      clock: () => kFixtureDate,
    );
  }

  /// An alternate [LinkedStore] handed to the controller instead of the plain
  /// [linkedStore] — used to inject a stalling/failing `writeMaterialized` for
  /// the persist-resilience tests (#168). Reads still resolve through it, so it
  /// normally wraps an [InMemoryLinkedStore].
  final LinkedStore? controllerStore;

  /// The controller's persist-step timeout (#168); defaults to 10 minutes when
  /// unset, and the stall tests inject a tiny value.
  final Duration? persistTimeout;

  /// The shared materialized-view store (#115): a sync writes the derived
  /// per-account docs + rollups here, and a resumed session reads the overview
  /// back with no pull. Shared across sessions via [resume].
  final InMemoryLinkedStore linkedStore;

  /// The shared cold-snapshot store, when this harness models the persistence
  /// wiring (#107). `null` for the plain in-memory scenarios.
  final SnapshotStore? store;

  /// The settings document this session's pulls repair the WISA school profiles
  /// in (#207). Share the one [InMemorySettingsStore] with a `SettingsHarness`
  /// to model what the real app does — both bootstraps read and write the same
  /// Cosmos document — so a test can sync and then open Settings on the result.
  /// `null` for the scenarios that do not care about settings persistence.
  final SettingsStore? settingsStore;

  /// The shared realtime fan-out (#116): when set, this session's controller
  /// publishes change signals to it and subscribes for others'. Share one hub
  /// across sessions to model operators nudging each other in real time.
  final InMemorySignalHub? hub;

  /// The operator (UPN) this session syncs as — the lease owner and the
  /// per-system sync-metadata author (#108). Vary it to model a second operator
  /// sharing the same [linkedStore].
  final String syncedBy;

  /// When set, the Azure syncer parks on this completer until a test releases
  /// it — a seam to freeze a sync mid-pass (WISA + Smartschool already pulled)
  /// so a widget test can observe the busy progress bar (#176).
  final Completer<void>? azureGate;

  /// When set, every action of a dry-run/apply pass parks here before it runs —
  /// the seam that freezes a pass mid-flight so a test can observe the modal
  /// progress dialog naming the account and action in flight (#243). Unlike
  /// [azureGate] it covers dry-runs too, which touch no connector at all.
  final Future<void> Function()? applyGate;

  /// When set, the Azure pull is the **production** one — a real
  /// [az.AzureConnector] + [azureSyncer] over this transport — instead of the
  /// scripted [azResult]. Lets a test answer as Graph does (e.g. rejecting a
  /// stored delta token, #213) and drive the result through the real pass.
  final az.GraphTransport? azureTransport;

  /// When set, the Smartschool pull is the **production** one — a real
  /// [ss.SmartschoolConnector] over this SOAP wire — instead of the scripted
  /// [ssResult]. The counterpart of [azureTransport], and the only way a test
  /// can answer as Smartschool's group tree does and see what the operator's
  /// own [smartschoolRules] then do to the pull (#241).
  final ss.SmartschoolSoapTransport? smartschoolTransport;

  /// When set, the WISA pull is the **production** one — a real
  /// [wapi.WisaConnector] behind the real [wisaSyncer] — instead of the scripted
  /// [wisaResult]. The third of the connector seams, and the only way a test can
  /// read back which `Werkdatum` a pass actually asked WISA for after the
  /// operator changed it in Instellingen (#238).
  final wapi.WisaSoapTransport? wisaTransport;

  /// The live settings document (#238): what the production WISA pull reads its
  /// werkdatum pair and virtual-school marks from at pull time, and what the
  /// controller's drift gate compares against. Publish into it to model the
  /// operator saving in Instellingen mid-session — the real Settings view does
  /// exactly that, into the very same holder.
  final LiveSettings liveSettings;

  /// The operator's Smartschool import rules, applied by the production pull
  /// [smartschoolTransport] enables — the settings document's
  /// `smartschoolRules`, as `bootstrapReconcile` hands them to the connector.
  /// Ignored by the scripted pull, which returns [ssResult] whole.
  ///
  /// Read at sync time, like [ssResult]: assign between passes to model the
  /// session that bootstraps on rules the operator has just saved in Settings.
  List<ss.SmartschoolImportRule> smartschoolRules;

  /// The Smartschool class-tree live-config the placement resolver reads to
  /// find the group a freshly created official class hangs under — the
  /// `classTreeFrom(settings.smartschool)` the real bootstrap injects.
  /// Unconfigured by default, so no parent resolves and `AddToSmartschool`
  /// fails the way it does against a bare tenant; a fixture that wants the
  /// create to land names the root here.
  final SmartschoolClassTree classTree;

  /// When set, the Passwords screen writes through the **production**
  /// [ConnectorPasswordBackends] over this transport instead of the recording
  /// [passwordBackends] — the only way a test can answer as Graph does when it
  /// refuses a password write (#216) and see what the screen then tells the
  /// operator.
  final az.GraphTransport? passwordGraph;

  /// The production write seam built over [passwordGraph], or `null` when no
  /// test wired one. Built lazily so the harness's log is already assigned.
  late final PasswordBackends? _livePasswordBackends = passwordGraph == null
      ? null
      : ConnectorPasswordBackends(
          smartschool: ss.SmartschoolConnector.fromParts(
            site: 'demo',
            accessCode: 'secret',
            transport: soap,
          ),
          azure: az.AzureConnector(
            credentials: az.AzureCredentials(
              clientId: 'c',
              tenantId: 't',
              azureDomain: 'school.example',
              schoolPrefix: 'GBS',
            ),
            authProvider: const az.StaticAuthProvider('token'),
            transport: passwordGraph!,
            log: log,
          ),
          log: log,
        );

  /// Builds a "second session" seeded from [store] — a fresh controller over
  /// the state another harness already persisted, the way bootstrap seeds each
  /// [SystemState] from the store on app open (#107).
  static Future<ReconcileHarness> resume({
    required SnapshotStore store,
    InMemoryLinkedStore? linkedStore,
    InMemorySignalHub? hub,
    SignalSubscriber? subscriber,
    wapi.WisaSnapshot? wisa,
    ss.SmartschoolSnapshot? smartschool,
    az.AzureSnapshot? azure,
  }) async {
    final wisaSeed = await seedSnapshot<wapi.WisaSnapshot>(
      system: core.Origin.wisa,
      store: store,
      fromPayload: wapi.WisaSnapshot.fromJson,
    );
    final ssSeed = await seedSnapshot<ss.SmartschoolSnapshot>(
      system: core.Origin.smartschool,
      store: store,
      fromPayload: ss.SmartschoolSnapshot.fromJson,
    );
    final azSeed = await seedSnapshot<az.AzureSnapshot>(
      system: core.Origin.azure,
      store: store,
      fromPayload: az.AzureSnapshot.fromJson,
    );
    return ReconcileHarness(
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      store: store,
      linkedStore: linkedStore,
      hub: hub,
      subscriber: subscriber,
      wisaInitial: wisaSeed,
      ssInitial: ssSeed,
      azureInitial: azSeed,
    );
  }

  /// What the next sync of each system returns. Mutate to simulate a change
  /// between syncs; [wisaError] (when set) makes the next WISA sync throw.
  wapi.WisaSnapshot wisaResult;
  ss.SmartschoolSnapshot ssResult;
  az.AzureSnapshot azResult;
  Object? wisaError;

  int wisaSyncs = 0;
  int ssSyncs = 0;
  int azSyncs = 0;

  final RecordingSoap soap = RecordingSoap();
  final RecordingGraph graph = RecordingGraph();

  late final LogBuffer log;
  late final ApplicationState app;
  late final StateApplier applier;
  late final ReconcileController controller;

  /// The shared password-distribution queue (#105): the applier appends to it on
  /// every account-creating apply, and the Passwords view reads and drains it.
  final InMemoryPasswordQueueStore passwordQueue = InMemoryPasswordQueueStore();

  /// The recording live-write seam for the on-demand Passwords screen (#180):
  /// captures every Smartschool/Azure push a generation or reset performs.
  final RecordingPasswordBackends passwordBackends =
      RecordingPasswordBackends();

  /// Every password export the screen wrote (#195), as
  /// `(suggestedName, bytes)`. Recorded instead of written so driving the
  /// export button never drops cleartext password sheets on the test machine.
  final List<(String, List<int>)> passwordWrites = <(String, List<int>)>[];

  /// Every path the screen asked the platform to open after an export (#195).
  final List<String> passwordOpens = <String>[];

  /// When set, the recording opener throws it — the "the viewer would not
  /// launch" case, which must not cost the operator the written file.
  Object? passwordOpenError;

  /// The bundle the screen's bootstrap seam expects.
  ReconcileServices get services => ReconcileServices(
        settings: const AppSettings(),
        liveSettings: liveSettings,
        app: app,
        applier: applier,
        controller: controller,
        log: log,
        passwordQueue: passwordQueue,
        passwordBackends: _livePasswordBackends ?? passwordBackends,
        passwordFileWriter: (name, bytes) async {
          passwordWrites.add((name, List<int>.of(bytes)));
          return 'C:/exports/$name';
        },
        passwordFileOpener: (path) async {
          final error = passwordOpenError;
          if (error != null) throw error;
          passwordOpens.add(path);
        },
      );

  /// A ready-made bootstrap closure for [ReconcileScreen]/[AccountManagerApp].
  Future<ReconcileServices> Function() get bootstrap => () async => services;
}
