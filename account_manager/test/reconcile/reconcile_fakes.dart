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

  /// The class codes of every `delClass` this transport accepted, in order —
  /// the Smartschool classes a delete action actually removed (#313). The twin
  /// of [RecordingGraph.deletedGroups], and read off the envelope for the same
  /// reason: "a write happened" is not "this record was written".
  final List<String> deletedClasses = <String>[];

  /// The class codes of every `saveUserToClass` this transport accepted, in
  /// order — the Smartschool class each move actually wrote a student into
  /// (#333). Read off the envelope for the same reason [deletedClasses] is:
  /// "a move happened" is not "this class is the one it wrote".
  final List<String> movedToClasses = <String>[];

  /// The group codes of every `saveUserToClassesAndGroups` this transport
  /// accepted, in order — the **non-official** groups an account was actually
  /// added to (#374). Separate from [movedToClasses] because the two are
  /// different writes on different kinds of group, and read off the envelope
  /// for the same reason: "the account was seated" is not "it was seated here".
  final List<String> joinedGroups = <String>[];

  /// The group **names** of every `removeUserFromGroup` this transport
  /// accepted, in order (#374) — names, not codes, because that is what the
  /// API takes here, the one place it does.
  final List<String> leftGroups = <String>[];

  /// The `stamboeknummer` every `saveUser` carried, in order (#338). A
  /// schoolloopbaan keeps one stamnummer **per row** and `saveUser` writes it to
  /// the *last* row, so what matters is not that a save happened but which
  /// number it carried — and whether the class move that creates the new row had
  /// already run. Read off the envelope for the same reason [movedToClasses] is.
  final List<String> savedStamboeknummers = <String>[];

  /// The `schoolYearDate` every `saveClass` carried, in order (#339). The
  /// institute and admin numbers a class write carries are **per school year**,
  /// and an empty value means "the year Smartschool is in today" — so an
  /// operator reading WISA with next year's werkdatum writes next year's numbers
  /// onto the running year unless the write names the year it read from. Read
  /// off the envelope for the same reason [savedStamboeknummers] is: "a class
  /// was saved" is not "it was saved for the right year".
  final List<String> savedClassSchoolYears = <String>[];

  /// When set, a SOAP call whose action this answers with an error **throws**
  /// instead of replying — the wire coming apart (a dropped connection, a
  /// gateway error, XML that does not parse) rather than Smartschool returning
  /// a refusal code (#343). Returning null lets the call answer normally.
  ///
  /// The distinction matters because the two take different branches: a
  /// best-effort step reads a non-zero code and shrugs, while a throw unwinds
  /// into whatever `try` encloses it — which is how a class placement used to
  /// fail the create it followed.
  Object? Function(String soapAction)? throwFor;

  static final RegExp _codeArg = RegExp(r'<code[^>]*>([^<]*)</code>');
  static final RegExp _classArg = RegExp(r'<class[^>]*>([^<]*)</class>');
  static final RegExp _csvListArg = RegExp(r'<csvList[^>]*>([^<]*)</csvList>');
  static final RegExp _stamboekArg =
      RegExp(r'<stamboeknummer[^>]*>([^<]*)</stamboeknummer>');
  static final RegExp _schoolYearArg =
      RegExp(r'<schoolYearDate[^>]*>([^<]*)</schoolYearDate>');

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    soapActions.add(soapAction);
    // Recorded first, then thrown: the call went out, it just never came back.
    // The per-method lists below are "what this transport accepted", and a call
    // that blew up accepted nothing.
    final Object? failure = throwFor?.call(soapAction);
    if (failure != null) throw failure;
    if (soapAction.contains('delClass')) {
      final match = _codeArg.firstMatch(envelope);
      if (match != null) deletedClasses.add(match.group(1)!);
    }
    // `saveUserToClassesAndGroups` is a different write (non-official groups),
    // so match the method exactly rather than by prefix.
    if (soapAction.endsWith('#saveUserToClass')) {
      final match = _classArg.firstMatch(envelope);
      if (match != null) movedToClasses.add(match.group(1)!);
    }
    if (soapAction.endsWith('#saveUserToClassesAndGroups')) {
      final match = _csvListArg.firstMatch(envelope);
      if (match != null) joinedGroups.add(match.group(1)!);
    }
    // `removeUserFromGroup` names its target in the same `class` part the
    // official move uses, but by **name** rather than by code.
    if (soapAction.endsWith('#removeUserFromGroup')) {
      final match = _classArg.firstMatch(envelope);
      if (match != null) leftGroups.add(match.group(1)!);
    }
    // Likewise exact: `saveUserParameter` shares the prefix but carries no
    // stamboeknummer at all.
    if (soapAction.endsWith('#saveUser')) {
      savedStamboeknummers
          .add(_stamboekArg.firstMatch(envelope)?.group(1) ?? '');
    }
    if (soapAction.endsWith('#saveClass')) {
      savedClassSchoolYears
          .add(_schoolYearArg.firstMatch(envelope)?.group(1) ?? '');
    }
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

  /// The object ids of every `DELETE /groups/<id>` this transport accepted, in
  /// order — the Office 365 groups a delete action actually removed (#271).
  /// Deliberately not the member-ref deletes, which end in `/$ref`.
  final List<String> deletedGroups = <String>[];

  /// When set, every `POST /groups` is refused with the
  /// `403 Authorization_RequestDenied` a tenant answers when the sign-in may
  /// not create Microsoft 365 groups — the shape #216 hit on a Graph write the
  /// delegated scopes did not cover, applied to the class-group create (#272).
  bool refuseGroupCreates = false;

  /// When set, every `$batch` sub-request is refused the way Graph refuses a
  /// membership write on a group whose membership it will not manage — the
  /// mail-enabled security group of #331, on which all 38 of a class's changes
  /// bounced at once.
  ///
  /// The exact envelope that tenant returns is Graph's to give; what #330 is
  /// about is that whatever it says reaches the operator. So this picks a
  /// plausible one and the tests assert it is *relayed*, never that it is this
  /// particular code.
  bool refuseMembershipWrites = false;

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
      if (refuseGroupCreates) {
        return const az.GraphResponse(
          statusCode: 403,
          headers: <String, String>{'content-type': 'application/json'},
          body: '{"error":{"code":"Authorization_RequestDenied",'
              '"message":"Insufficient privileges to complete the '
              'operation."}}',
        );
      }
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
              if (refuseMembershipWrites)
                <String, dynamic>{
                  'id': sub['id'],
                  'status': 400,
                  'body': <String, dynamic>{
                    'error': <String, dynamic>{
                      'code': 'Request_BadRequest',
                      'message': 'Adding or removing members is not supported '
                          'for this group.',
                    },
                  },
                }
              else
                <String, dynamic>{'id': sub['id'], 'status': 204},
          ],
        },
        statusCode: 200,
      );
    }
    // A group delete (#271): `DELETE /groups/<id>`, as opposed to the
    // `/groups/<id>/members/<id>/$ref` a membership removal issues.
    if (request.method == 'DELETE') {
      final match = _groupPath.firstMatch(request.url.path);
      if (match != null) deletedGroups.add(match.group(1)!);
    }
    return const az.GraphResponse(statusCode: 204);
  }

  /// `/v1.0/groups/<id>` — the group resource itself, not a sub-collection.
  static final RegExp _groupPath = RegExp(r'/groups/([^/]+)$');

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
            if (u.jobTitle != null) 'jobTitle': u.jobTitle,
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
            if (u.jobTitle != null) 'jobTitle': u.jobTitle,
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

/// A [az.GraphTransport] answering the way the tenant answers for a staff member
/// whose Azure `department` lists our school **second** (`SSM,GBS`) — the
/// ordinary state of the comma list other software maintains (#237).
///
/// The school-scoped bulk `$filter` cannot see such an account
/// (`startswith(department, …)`) and Graph has no `contains` to widen it with,
/// so on an incremental pass the only leg that can carry a change to it into the
/// app is the **delta** walk, which filters in Dart. This wire resumes from the
/// stored token and reports exactly one changed user; the bulk read and the
/// `employeeId` back-fill both answer empty, so a test can prove which leg the
/// account arrived on.
///
/// Wire it into [ReconcileHarness.azureTransport] together with an
/// `azureInitial` carrying the token to resume from.
class SharedDepartmentStaffGraph implements az.GraphTransport {
  SharedDepartmentStaffGraph({
    az.AzureUser? changed,
    this.freshToken = 'AZ-NEXT',
  }) : changed = changed ?? azStaffUser();

  /// The user `/users/delta` reports as changed since the stored token.
  final az.AzureUser changed;

  /// The token this walk leaves behind for the next pass.
  final String freshToken;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every delta token Graph was asked to resume from, in order.
  final List<String> resumeTokens = <String>[];

  /// Every `employeeId in (…)` filter the connector issued — empty on a pass
  /// whose accounts were all accounted for already.
  final List<String> employeeIdLookups = <String>[];

  /// How many `$filter`-scoped bulk reads ran — none, on an incremental pass.
  int bulkReads = 0;

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    final String path = request.url.path;
    if (path.contains('/members') || path.contains('groups')) {
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    if (path.contains('users/delta')) {
      final String token = request.url.queryParameters[r'$deltatoken'] ?? '';
      if (token != 'latest') resumeTokens.add(token);
      return _ok(<String, dynamic>{
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken='
                '$freshToken',
        // A `$deltatoken=latest` prime carries no data by definition; a resume
        // carries the one account that changed.
        'value': token == 'latest'
            ? const <Object>[]
            : <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': changed.id,
                  'userPrincipalName': changed.upn,
                  if (changed.employeeId != null)
                    'employeeId': changed.employeeId,
                  'displayName': changed.displayName,
                  'givenName': changed.givenName,
                  'surname': changed.surname,
                  if (changed.companyName != null)
                    'companyName': changed.companyName,
                  if (changed.department != null)
                    'department': changed.department,
                  if (changed.jobTitle != null) 'jobTitle': changed.jobTitle,
                  'accountEnabled': changed.accountEnabled,
                },
              ],
      });
    }
    final String filter = request.url.queryParameters[r'$filter'] ?? '';
    if (filter.startsWith('employeeId in')) {
      employeeIdLookups.add(filter);
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    bulkReads++;
    return _ok(<String, dynamic>{'value': const <Object>[]});
  }

  static az.GraphResponse _ok(Map<String, dynamic> body) => az.GraphResponse(
        statusCode: 200,
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

/// A [az.GraphTransport] answering a resumed `/users/delta` the way Graph
/// answers it after somebody edited an account **by hand** in the Office 365 /
/// Entra portal (#288): the row carries the object id and the properties that
/// changed, and nothing else.
///
/// That sparseness is Graph's documented contract for a changed instance, and it
/// is what made every hand-edit invisible. Read as a whole user, such a row
/// names no school, so the connector's client-side prefix test threw it away —
/// permanently, because the walk that dropped it still advanced the token. The
/// operator pressed **Controleer op drift**, read `0 gewijzigd`, and only a
/// restart (re-seeding from the shared cold store) ever showed the edit.
///
/// The bulk read and the `employeeId` back-fill both answer empty, so a test can
/// prove the delta walk really was the only leg that could have delivered it.
///
/// Wire it into [ReconcileHarness.azureTransport] together with an
/// `azureInitial` carrying the token to resume from and the record the row
/// edits.
class HandEditedUserGraph implements az.GraphTransport {
  HandEditedUserGraph({required this.row, this.freshToken = 'AZ-NEXT'});

  /// The one sparse row the resumed walk reports — `{id, <changed props>}`.
  final Map<String, dynamic> row;

  /// The token this walk leaves behind for the next pass.
  final String freshToken;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every delta token Graph was asked to resume from, in order.
  final List<String> resumeTokens = <String>[];

  /// Every `employeeId in (…)` filter the connector issued.
  final List<String> employeeIdLookups = <String>[];

  /// How many `$filter`-scoped bulk reads ran — none, on an incremental pass.
  int bulkReads = 0;

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    final String path = request.url.path;
    if (path.contains('/members') || path.contains('groups')) {
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    if (path.contains('users/delta')) {
      final String token = request.url.queryParameters[r'$deltatoken'] ?? '';
      if (token != 'latest') resumeTokens.add(token);
      return _ok(<String, dynamic>{
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken='
                '$freshToken',
        'value':
            token == 'latest' ? const <Object>[] : <Map<String, dynamic>>[row],
      });
    }
    final String filter = request.url.queryParameters[r'$filter'] ?? '';
    if (filter.startsWith('employeeId in')) {
      employeeIdLookups.add(filter);
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    bulkReads++;
    return _ok(<String, dynamic>{'value': const <Object>[]});
  }

  static az.GraphResponse _ok(Map<String, dynamic> body) => az.GraphResponse(
        statusCode: 200,
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

/// A [az.GraphTransport] answering a resumed `/users/delta` the way Graph
/// answers it after another school's software claimed an account of ours
/// (#317): a sparse row whose `companyName`/`department` now names somebody
/// else.
///
/// Merged onto the record the app holds, such a row reads as an account that is
/// no longer ours — and the walk used to drop it, silently. Because the delta is
/// applied as an upsert, dropping meant the app's own copy (which still carries
/// *our* prefix) survived untouched, on this pass and on every later one: the
/// same row is dropped again for the same reason, forever. That is the state in
/// which the app goes on proposing writes against an account another school now
/// owns.
///
/// [backfill] is what a targeted `employeeId in (…)` lookup answers with, so a
/// test can drive the other leg of the same pass: a student WISA still places
/// here is re-adopted (#224) with the record straight off Graph, and the two
/// legs have to agree rather than fight. The `$filter`-scoped bulk read answers
/// empty and is counted, so a test can prove the pass really was the incremental
/// one.
///
/// Wire it into [ReconcileHarness.azureTransport] together with an
/// `azureInitial` carrying the token to resume from and the accounts as the app
/// still remembers them.
class SchoolMovedUserGraph implements az.GraphTransport {
  SchoolMovedUserGraph({
    required this.rows,
    this.backfill = const <Map<String, dynamic>>[],
    this.freshToken = 'AZ-NEXT',
  });

  /// The sparse rows the resumed walk reports — `{id, <changed props>}`.
  final List<Map<String, dynamic>> rows;

  /// The full records a targeted `employeeId` lookup turns up.
  final List<Map<String, dynamic>> backfill;

  /// The token this walk leaves behind for the next pass.
  final String freshToken;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every delta token Graph was asked to resume from, in order.
  final List<String> resumeTokens = <String>[];

  /// Every `employeeId in (…)` filter the connector issued, in order.
  final List<String> employeeIdLookups = <String>[];

  /// How many `$filter`-scoped bulk reads ran — none, on an incremental pass.
  int bulkReads = 0;

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    final String path = request.url.path;
    if (path.contains('/members') || path.contains('groups')) {
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    if (path.contains('users/delta')) {
      final String token = request.url.queryParameters[r'$deltatoken'] ?? '';
      if (token != 'latest') resumeTokens.add(token);
      return _ok(<String, dynamic>{
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken='
                '$freshToken',
        'value': token == 'latest' ? const <Object>[] : rows,
      });
    }
    final String filter = request.url.queryParameters[r'$filter'] ?? '';
    if (filter.startsWith('employeeId in')) {
      employeeIdLookups.add(filter);
      return _ok(<String, dynamic>{'value': backfill});
    }
    bulkReads++;
    return _ok(<String, dynamic>{'value': const <Object>[]});
  }

  static az.GraphResponse _ok(Map<String, dynamic> body) => az.GraphResponse(
        statusCode: 200,
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

/// A [az.GraphTransport] answering the way the tenant answers when the app's
/// stored copy of an account has drifted **past what any delta can report**
/// (#315/#316).
///
/// Graph holds the account as it stands now — that is [user], and the
/// `$filter`-scoped bulk read returns it. A resumed `/users/delta` reports
/// **nothing**: the edit predates the token the session holds, which is the
/// whole point. So an incremental pass, however many times it is run, can only
/// ever confirm the stale copy the app already has, while a re-read repairs it
/// in one.
///
/// Wire it into [ReconcileHarness.azureTransport] together with an
/// `azureInitial` carrying the token to resume from and the account as the app
/// wrongly remembers it.
class DriftedUserGraph implements az.GraphTransport {
  DriftedUserGraph({az.AzureUser? user, this.freshToken = 'AZ-NEXT'})
      : user = user ?? azUser();

  /// The account exactly as Graph holds it — what a full read returns.
  final az.AzureUser user;

  /// The token a pass leaves behind, whichever leg it took.
  final String freshToken;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every delta token Graph was asked to resume from, in order — empty on a
  /// pass that re-read instead.
  final List<String> resumeTokens = <String>[];

  /// Every `employeeId in (…)` filter the connector issued.
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
      final String token = request.url.queryParameters[r'$deltatoken'] ?? '';
      if (token != 'latest') resumeTokens.add(token);
      // Nothing changed *since the token*, which is not the same thing as
      // nothing being wrong.
      return _ok(<String, dynamic>{
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken='
                '$freshToken',
        'value': const <Object>[],
      });
    }
    final String filter = request.url.queryParameters[r'$filter'] ?? '';
    if (filter.startsWith('employeeId in')) {
      employeeIdLookups.add(filter);
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    bulkReads++;
    return _ok(<String, dynamic>{
      'value': <Map<String, dynamic>>[_row(user)],
    });
  }

  static Map<String, dynamic> _row(az.AzureUser u) => <String, dynamic>{
        'id': u.id,
        'userPrincipalName': u.upn,
        if (u.employeeId != null) 'employeeId': u.employeeId,
        'displayName': u.displayName,
        'givenName': u.givenName,
        'surname': u.surname,
        if (u.companyName != null) 'companyName': u.companyName,
        if (u.department != null) 'department': u.department,
        if (u.jobTitle != null) 'jobTitle': u.jobTitle,
        'accountEnabled': u.accountEnabled,
      };

  static az.GraphResponse _ok(Map<String, dynamic> body) => az.GraphResponse(
        statusCode: 200,
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

/// A [az.GraphTransport] answering the way the tenant answers on the pass that
/// has to notice a staff member **left** WISA (#269).
///
/// [azStaffUser]'s Office 365 account is still there, with our prefix second in
/// the comma list other software maintains (`SSM,GBS`, #237). WISA no longer
/// lists her, so the `employeeId` back-fill's WISA-derived set (#231) no longer
/// names her either — and this wire is the pass where that used to be fatal:
///
/// - the stored delta token is past Graph's 30-day window, so the resume is
///   **refused** and the pass recovers with a full read (#213). That recovery is
///   unavoidable — every token expires eventually — and it is what discards the
///   previous user list;
/// - the recovered `$filter`-scoped bulk read returns **nothing** for her:
///   `startswith(department,'GBS')` cannot see a list that leads with `SSM`, and
///   Graph has no `contains` to widen it with (#268);
/// - only a targeted `employeeId in (…)` lookup turns her up.
///
/// So exactly one leg can carry the account into the snapshot, and a test can
/// prove it was taken. Wire it into [ReconcileHarness.azureTransport] with an
/// `azureInitial` holding the dead token and the account as the previous pass
/// left it — the memory that names the id to ask about.
class DepartedStaffGraph implements az.GraphTransport {
  DepartedStaffGraph({
    az.AzureUser? account,
    this.freshToken = 'AZ-FRESH',
  }) : account = account ?? azStaffUser();

  /// The account that outlived the WISA row, exactly as Graph still holds it.
  final az.AzureUser account;

  /// The token the recovered full read primes for the next pass.
  final String freshToken;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every delta token Graph was asked to resume from, in order — so a test can
  /// prove the refused one really was sent, and not re-sent afterwards.
  final List<String> resumeTokens = <String>[];

  /// Every `employeeId in (…)` filter the connector issued, in order.
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
      final String token = request.url.queryParameters[r'$deltatoken'] ?? '';
      if (token == 'latest') return _deltaLink();
      resumeTokens.add(token);
      // A token this transport itself handed out is honoured, so a test can
      // show the recovery restored incremental syncing rather than pinning the
      // app to a full read forever.
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
    final String filter = request.url.queryParameters[r'$filter'] ?? '';
    if (filter.startsWith('employeeId in')) {
      employeeIdLookups.add(filter);
      return _ok(<String, dynamic>{
        'value': filter.contains("'${account.employeeId}'")
            ? <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': account.id,
                  'userPrincipalName': account.upn,
                  if (account.employeeId != null)
                    'employeeId': account.employeeId,
                  'displayName': account.displayName,
                  'givenName': account.givenName,
                  'surname': account.surname,
                  if (account.companyName != null)
                    'companyName': account.companyName,
                  if (account.department != null)
                    'department': account.department,
                  if (account.jobTitle != null) 'jobTitle': account.jobTitle,
                  'accountEnabled': account.accountEnabled,
                },
              ]
            : const <Object>[],
      });
    }
    // The school-scoped bulk read, blind to her — the whole problem.
    bulkReads++;
    return _ok(<String, dynamic>{'value': const <Object>[]});
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

/// A [az.GraphTransport] answering the way the tenant answers for the Office 365
/// class group of #280: it still holds the address `GBS-<class>` as its
/// `mailNickname`, but somebody renamed its **display name** by hand, so
/// `GroupManager.listGroups` — `startswith(displayName,'GBS')` and nothing else
/// — cannot see it on any pull we make.
///
/// That is the whole bug. The linker keeps proposing `CreateAzureClassGroup`,
/// and every apply dies on the create's own pre-create guard (`mailNickname eq`
/// finds the group Graph is hiding from the pull), telling the operator to sync
/// again — which provably cannot help. Only a targeted `mailNickname in (…)`
/// read finds it, so exactly one leg can carry the group into the snapshot and a
/// test can prove it was taken.
///
/// The students are served from the ordinary school-scoped bulk read: nothing is
/// wrong with *them*, and the class needs its roster linked for the adoption to
/// be observable as a membership diff.
///
/// Wire it into [ReconcileHarness.azureTransport] to drive the **production**
/// Azure pull, the only place the back-fill lives.
class RenamedClassGroupGraph implements az.GraphTransport {
  RenamedClassGroupGraph({
    this.className = '5WW1',
    this.groupId = 'az-renamed',
    this.renamedTo = 'Klas van juf An',
    this.deltaToken = 'AZ-TOKEN',
    this.visibleUsers = const <az.AzureUser>[],
    this.memberIds = const <String>[],
  });

  /// The bare class the hidden group belongs to — its address is `GBS-<this>`.
  final String className;
  final String groupId;

  /// What somebody renamed the group to. Deliberately outside the `GBS-`
  /// namespace: that is what makes it invisible to the prefix-scoped list.
  final String renamedTo;
  final String deltaToken;

  /// The students the school-scoped bulk read returns, exactly as usual.
  final List<az.AzureUser> visibleUsers;

  /// The group's members, as Graph holds them.
  final List<String> memberIds;

  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  /// Every `mailNickname in (…)` filter the connector issued, in order — so a
  /// test can prove it asked only about the addresses it could not account for.
  final List<String> nicknameLookups = <String>[];

  /// Every `startswith(displayName,…)` group list the connector issued.
  int groupListReads = 0;

  /// The bodies of every `POST /groups` — a create that must never happen.
  final List<Map<String, dynamic>> createdGroups = <Map<String, dynamic>>[];

  String get mailNickname => 'GBS-$className';

  Map<String, dynamic> get _groupRow => <String, dynamic>{
        'id': groupId,
        'displayName': renamedTo,
        'securityEnabled': false,
        'mail': '$mailNickname@student.school.example',
        'mailNickname': mailNickname,
      };

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    final String path = request.url.path;
    final String filter = request.url.queryParameters[r'$filter'] ?? '';

    if (request.method == 'POST' && path.endsWith('/groups')) {
      createdGroups.add(
        Map<String, dynamic>.from(jsonDecode(request.body ?? '{}') as Map),
      );
      return _ok(<String, dynamic>{'id': 'az-should-not-happen'});
    }
    if (path.contains('/members')) {
      return _ok(<String, dynamic>{
        'value': <Map<String, dynamic>>[
          for (final id in memberIds) <String, dynamic>{'id': id},
        ],
      });
    }
    if (path.endsWith('/groups')) {
      if (filter.startsWith('mailNickname in')) {
        nicknameLookups.add(filter);
        return _ok(<String, dynamic>{
          'value': filter.contains("'$mailNickname'")
              ? <Map<String, dynamic>>[_groupRow]
              : const <Object>[],
        });
      }
      // The prefix-scoped list — blind to the renamed group, which is the bug.
      groupListReads++;
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
    if (filter.startsWith('employeeId in')) {
      return _ok(<String, dynamic>{'value': const <Object>[]});
    }
    return _ok(<String, dynamic>{
      'value': <Map<String, dynamic>>[
        for (final az.AzureUser u in visibleUsers)
          <String, dynamic>{
            'id': u.id,
            'userPrincipalName': u.upn,
            if (u.employeeId != null) 'employeeId': u.employeeId,
            'displayName': u.displayName,
            'givenName': u.givenName,
            'surname': u.surname,
            if (u.companyName != null) 'companyName': u.companyName,
            if (u.jobTitle != null) 'jobTitle': u.jobTitle,
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
    this.classGroupRows = const <String>['3C,00,Derde jaar C,a1,111'],
    this.studentRows = const <String>[
      '3C,,Doe,Jane,,1/7/2010,1,,V,,,,Straat,1,,2000,Antwerpen,1/9/2025',
    ],
  });

  /// The schools `SMAGetInst` reports, as `(id, name, code)`.
  final List<(int, String, String)> schools;

  /// The `SyncKlas` data rows, minus the header — one raw CSV line each, in the
  /// column order of [_classGroupHeader]. Every school is served the same rows,
  /// which is all a single-school fixture needs. Override to give a class the
  /// shape the pull has to reason about: an administrative `00` row plus the
  /// named `KLASGROEP` rows it is split into (#362).
  final List<String> classGroupRows;

  /// The `SmaSyncLln` data rows, minus the header — one raw CSV line each, in
  /// the column order of [_studentHeader]. Column 2 is the student's own
  /// `KLASGROEP`, so a sub-grouped fixture has to fill it in.
  final List<String> studentRows;

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
          <String>[_classGroupHeader, ...classGroupRows].join('\n'),
        wapi.WisaQuery.syncStudents =>
          <String>[_studentHeader, ...studentRows].join('\n'),
        wapi.WisaQuery.syncStaff => 'CODE,WISAID,FAMILIENAAM,VOORNAAM',
        _ => '',
      };

  static const String _classGroupHeader =
      'KLAS,KLASGROEP,OMSCHRIJVING,ADMINGROEP,INSTELLINGSNUMMER';

  static const String _studentHeader =
      'KLAS,KLASGROEP,NAAM,VOORNAAM,ROEPNAAM,GEBOORTEDATUM,WISAID,'
      'STAMBOEKNUMMER,GESLACHT,RIJKSREGISTERNR,GEBOORTEPLAATS,NATIONALITEIT,'
      'STRAAT,STRAATNR,BUSNR,POSTCODE,WOONPLAATS,KLASWIJZIGING';

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
    Set<String>? failAzure,
    this.denyAzure = const <String>{},
  }) : failAzure = failAzure ?? <String>{};

  /// Smartschool usernames whose push should fail.
  final Set<String> failSmartschool;

  /// Azure mails/UPNs whose push should fail (models "no Azure account").
  ///
  /// Mutable, because the [ReconcileHarness] builds its own recorder: a fixture
  /// modelling Graph's `Request_ResourceNotFound` on a drifted address (#372)
  /// adds the address after the harness exists.
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

  /// Every Azure push: `(mailOrUpnOrObjectId, password)`.
  ///
  /// Since #372 the Passwords screen pushes by Graph **object id** whenever a
  /// linked snapshot resolved the account, and by address only as the fallback
  /// for a session that has not linked. Both land here, so a test asserts on the
  /// key that was used — which is the whole point of the fix.
  final List<(String, String)> azurePushes = <(String, String)>[];

  /// Which of those pushes went through [setAzurePasswordById] — the object-id
  /// route — rather than the address lookup.
  final List<String> azureIdPushes = <String>[];

  /// When set, every push parks here before it runs — the seam that freezes a
  /// generate/reset mid-flight so a test can observe the modal progress dialog
  /// counting up (#369), the password twin of [ReconcileHarness.applyGate].
  ///
  /// Mutable rather than a constructor argument because the harness builds its
  /// own recorder, exactly as [failAzure] is added to after the fact.
  Future<void> Function()? gate;

  @override
  Future<bool> setSmartschoolPassword(
    String uid,
    core.AccountType slot,
    String password,
  ) async {
    await _wait();
    if (failSmartschool.contains(uid)) return false;
    smartschoolPushes.add((uid, slot, password));
    return true;
  }

  @override
  Future<bool> setAzurePasswordById(String objectId, String password) async {
    azureIdPushes.add(objectId);
    return _push(objectId, password);
  }

  @override
  Future<bool> setAzurePassword(String mailOrUpn, String password) async =>
      _push(mailOrUpn, password);

  Future<void> _wait() async {
    final Future<void> Function()? hold = gate;
    if (hold != null) await hold();
  }

  Future<bool> _push(String key, String password) async {
    await _wait();
    final mailOrUpn = key;
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
  // The institute number of the enrolment WISA reports *as of the werkdatum* —
  // next school year's, once the werkdatum is moved forward (#338). Blank by
  // default, matching the Smartschool fixture, so no stamboeknummer action fires
  // unless a test is about one.
  String stemId = '',
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: classSubGroup,
      name: name,
      firstName: firstName,
      preferredName: '',
      birthDate: kFixtureDate,
      stemId: stemId,
      gender: core.Gender.female,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: address,
      classChange: kFixtureDate,
      schoolId: schoolId,
    );

/// A WISA school, optionally flagged [virtual] (the flag `markVirtualSchools`
/// stamps before the pull, whose class groups the linker refuses to seed, #209).
///
/// A school carries no ownership flag (#286): which schools we manage is the
/// harness's `ourSchoolIds` — the persisted Settings path, and the only one.
///
/// [name] and [code] are the two halves WISA answers with (#208) and the only
/// source a view may name a school from (#204). The default stands in for a
/// school nobody has fetched the halves of, which is what most fixtures want; a
/// fixture that renders a school name on screen gives it the real pair.
wapi.WisaSchool wisaSchool(
  int id, {
  bool virtual = false,
  String? name,
  String code = '',
}) =>
    wapi.WisaSchool(
      id: id,
      name: name ?? 'School $id',
      code: code,
      isVirtual: virtual,
    );

/// The managed-school set a fixture's reconcile stack scopes by: the live
/// settings document's WISA-scholen list when it configures one, otherwise the
/// set the harness was constructed with.
///
/// Since #286 an unconfigured document answers with an **empty** set rather than
/// null, so emptiness is what the fallback tests for — otherwise a fixture that
/// pins `ourSchoolIds` directly, without curating school profiles, would silently
/// lose its managed set.
Set<int>? _managedSchoolsOr(AppSettings settings, Set<int>? pinned) {
  final configured = managedSchoolIdsOf(settings);
  return configured.isEmpty ? pinned : configured;
}

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
/// [schoolIds] are the group schools the `SmaSyncPer` pull found them in
/// (#340) — what tells one of our own personeel from the rest of the
/// scholengroep's. Defaults to school 1, the fixture school every harness
/// manages, so an existing fixture keeps listing its staff member.
wapi.WisaStaff wisaStaff({
  String code = 'SMIT',
  String wisaId = '42',
  String firstName = 'Anna',
  String lastName = 'Smit',
  Set<int> schoolIds = const {1},
}) =>
    wapi.WisaStaff(
      code: core.WisaStaffCode(code),
      wisaId: core.WisaId(wisaId),
      firstName: firstName,
      lastName: lastName,
      schoolIds: schoolIds,
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
  // The stamboeknummer Smartschool holds on the account today — the value its
  // last schoolloopbaan row carries (#338).
  int stemId = 0,
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: stemId,
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
  // The school stamped on a student account. The harness prefix by default, so
  // the account is in step; a fixture about a *stale* copy of it (#315/#316)
  // names another school here.
  String companyName = 'GBS',
  // The other half of the Office 365 licensing rule (#358). In step by default
  // for the same reason `companyName` is; a fixture about the unlicensed account
  // passes null (the blank field this port's own creates left behind) or
  // `LeerlingBas` (the pupil who moved up from a basisschool).
  String? jobTitle = 'LeerlingSec',
  // The class the Office 365 profile advertises (#359), which the app keeps
  // equal to the WISA class. Defaults to [wisaStudent]'s own default class, so a
  // record built from these fixtures is in step and raises no repair; a fixture
  // whose student sits in another class passes it, and one about the *stale*
  // copy the issue is named for passes last year's class or null.
  String? department = '3C',
  // When Entra made the account, and when somebody last signed into it (#363).
  // Unknown by default — nothing outside the duplicate-identity report reads
  // them, and `null` is what an account pulled before #363's `$select` (or one
  // whose sign-in read was refused) really carries.
  DateTime? createdAt,
  DateTime? lastSignIn,
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: displayName,
      givenName: givenName,
      surname: surname,
      companyName: companyName,
      jobTitle: jobTitle,
      department: department,
      createdAt: createdAt,
      lastSignIn: lastSignIn,
    );

/// An Azure **staff** account. Staff carry no `companyName`; their school lives
/// in `department`, which other software maintains as the comma-separated list
/// of every school they are active at (#237) — so the default lists ours
/// *second*, the ordinary state that the connector's server-side `$filter`
/// (`startswith`) cannot see (#268).
///
/// The defaults line up with [wisaStaff] and [ssStaffAccount], so a record built
/// from all three is fully in sync and raises no action of its own.
///
/// [companyName] is null by default because that is what a staff account should
/// carry — the field is the *student* half of INV-22. A fixture about the
/// account that carries **both** stamps (#386) sets it to the school prefix,
/// which nothing in the tenant forbids: `companyName` says which school an
/// account belongs to, never what its holder is (#358).
az.AzureUser azStaffUser({
  String id = 'az-staff',
  String upn = 'anna.smit@school.example',
  String? employeeId = '42',
  String displayName = 'Smit Anna',
  String givenName = 'Anna',
  String surname = 'Smit',
  String department = 'SSM,GBS',
  String? companyName,
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: displayName,
      givenName: givenName,
      surname: surname,
      department: department,
      companyName: companyName,
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
  DateTime? workDate,
}) =>
    wapi.WisaSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
      students: students ?? [wisaStudent()],
      staff: staff,
      classGroups: classGroups,
      schools: schools,
      // The date the roster is *as of* (#247). Left unstamped by default, as a
      // hand-built fixture is; a test about which school year the shared state
      // describes (#287) sets it, and the controller then folds it into the
      // per-system freshness the next session reads back.
      workDate: workDate,
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

/// The three-system fixture for the Passwords screen reading the **linked
/// snapshot** instead of the Smartschool group tree (#372).
///
/// The same "Leerlingen"/"Personeel" shape as [passwordsSnap], seeded so that a
/// real sync + `link()` reproduces each of the issue's three defects at once:
///
/// - **Emely** is one of the 42 live students whose Smartschool `mail` carries a
///   collision suffix her Azure UPN does not (`emely.buvens1@` vs
///   `emely.buvens@`). The `upn ≡ mail` bridge misses her; `employeeId ≡ wisaId`
///   links her fine. Handing Graph her Smartschool address answers
///   `Request_ResourceNotFound`, which is what [failAzure] models here.
/// - **Nora** is in WISA and Smartschool but has no Azure account at all: the
///   row has to *say so* rather than quietly produce nothing.
/// - **Piet** is a staff member this app has just created through
///   `AddStaffToSmartschool`: an account in **no Smartschool group**, so the
///   group walk cannot see him though the linker holds him.
ReconcileHarness passwordsLinkedHarness() {
  final harness = ReconcileHarness(
    wisa: wisaSnap(
      students: [
        wisaStudent(
            wisaId: '4', classGroup: '3C', firstName: 'Emely', name: 'Buvens'),
        wisaStudent(
            wisaId: '5', classGroup: '3C', firstName: 'Nora', name: 'Nolens'),
      ],
      staff: [
        wisaStaff(
            code: 'PNIE', wisaId: '77', firstName: 'Piet', lastName: 'Nieuw'),
      ],
      schools: [wisaSchool(1)],
      classGroups: [wisaClassGroup('3C')],
    ),
    smartschool: ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: passwordsSnap().groups,
      accounts: <ss.SmartschoolAccount>[
        ssAccount(
          uid: 'emely',
          accountId: '4',
          mail: 'emely.buvens1@student.school.example',
          givenName: 'Emely',
          surname: 'Buvens',
        ),
        ssAccount(
          uid: 'nora',
          accountId: '5',
          mail: 'nora.nolens@student.school.example',
          givenName: 'Nora',
          surname: 'Nolens',
        ),
        ssStaffAccount(
          uid: 'piet.nieuw',
          accountId: 'PNIE',
          mail: 'piet.nieuw@school.example',
          givenName: 'Piet',
          surname: 'Nieuw',
        ),
      ],
      memberships: <ss.SmartschoolMembership>[
        member('emely', '3C'),
        member('nora', '3C'),
        // Piet has none: `AddStaffToSmartschool` writes the account and stops.
      ],
    ),
    azure: azSnap(users: [
      azUser(
        id: 'az-emely',
        upn: 'emely.buvens@student.school.example',
        employeeId: '4',
        displayName: 'Buvens Emely',
      ),
      azStaffUser(
        id: 'az-piet',
        upn: 'piet.nieuw@school.example',
        employeeId: '77',
        displayName: 'Nieuw Piet',
      ),
      // No account for Nora.
    ]),
  );
  // Graph as it really answers for Emely: there is no user on the Smartschool
  // address, so the pre-#372 lookup-by-mail push silently set nothing.
  harness.passwordBackends.failAzure
      .add('emely.buvens1@student.school.example');
  return harness;
}

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

/// The deliberate **co-account** pair INV-23 exists for (#323): one person with
/// a normal Smartschool account and an admin one, both carrying the same
/// `accountId` — the operator's convention is the student's WISA id — and the
/// same [mail].
///
/// The default [wisaStudent] and [azUser] carry that same id, so they link to
/// the *first* of the two: the shape is one fully-linked record plus one
/// Smartschool-only co-account, which is what the operator really has. Both
/// records preferred the natural key `wisa:1`, so before #323 the resolver
/// handed them one `LinkedAccountId` and every layer below the linker merged
/// them — the self-contradicting card #319 describes, reached with no
/// constructed resolver at all.
ss.SmartschoolSnapshot coAccountSnap({
  String mail = 'jane.doe@student.school.example',
}) =>
    ssSnap(
      accounts: [
        ssAccount(mail: mail),
        // Named apart so the two cards are distinguishable on screen; the ids
        // and the mail are what the linker keys on and they are identical.
        ssAccount(uid: 'jane-beheer', mail: mail, surname: 'Doe-beheer'),
      ],
    );

/// A reconcile harness over the [coAccountSnap] co-account pair (#323), on the
/// otherwise-default WISA/Azure fixtures so the person is fully linked.
ReconcileHarness coAccountHarness({InMemoryLinkedStore? linkedStore}) =>
    ReconcileHarness(
      smartschool: coAccountSnap(),
      linkedStore: linkedStore,
    );

/// A [core.PersonIdResolver] that hands every natural key the same id — the way
/// a test constructs the INV-24 collision (#319).
///
/// It has to be constructed. #318 removed the one known way two records ended up
/// on one `LinkedAccountId`, and re-breaking that merge to get a collision back
/// is not what the invariant is for: INV-24 is defence in depth against a cause
/// nobody has found yet, and the resolver is the seam where any such cause
/// ultimately expresses itself.
class CollidingResolver implements core.PersonIdResolver {
  CollidingResolver([this.id = 'p-shared']);

  /// The id every key resolves to.
  final String id;

  @override
  core.PersonId resolve(String naturalKey) => core.PersonId(id);
}

/// A reconcile harness whose linker puts two students on **one**
/// `LinkedAccountId` (#319): two ordinary, unrelated WISA students and a
/// [CollidingResolver], so the pass produces two records claiming one id.
///
/// Everything below the linker then behaves as the issue describes — one
/// materialized document carrying the union of both records' candidates — which
/// is exactly what the `DuplicateLinkedId` warning has to make visible.
ReconcileHarness idCollisionHarness({InMemoryLinkedStore? linkedStore}) =>
    ReconcileHarness(
      resolver: CollidingResolver(),
      linkedStore: linkedStore,
      wisa: wisaSnap(students: [
        wisaStudent(wisaId: 'W1', classGroup: '3A'),
        wisaStudent(wisaId: 'W2', classGroup: '3A'),
      ]),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount(uid: 'jane', accountId: 'W1')],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );

/// A reconcile harness over the live #360 shape: **one student, two Office 365
/// accounts** carrying the same `employeeId` (INV-26).
///
/// Modelled on the audited pairs. Both accounts were made by this app months
/// apart, so both carry our `companyName`; the two UPNs differ only in how the
/// given name was normalised — one keeps the internal hyphen, the other strips
/// it. The twin is the **unlicensed** half: it has no `jobTitle` (the field this
/// port only started writing in #358), so it falls outside the dynamic group
/// that grants the student licence and has never held Office. That asymmetry is
/// the point of the fixture — it is the pair of facts an operator picks by, and
/// the app must show them rather than choose.
///
/// The default WISA/Smartschool fixtures link the *first* account, so the shape
/// is one ordinary record whose Azure identity is ambiguous. The twin used to
/// become a second record instead: an Azure-only orphan, which — carrying our
/// `companyName` and no WISA row — reads as a departed student and raises
/// `RemoveStudentFromAzure` on it. Which of the pair that lands on is decided by
/// nothing but snapshot order.
///
/// The two life dates (#363) complete the pathology, and they contradict the
/// licensing ones on purpose. The twin is the **older** account — made before
/// this port started writing `jobTitle` (#358), which is why it has none — and
/// it is the one with recent sign-in activity. So the licensed account is the
/// one nobody uses, and the account the student actually works in is the one
/// that has never held Office. That is the whole reason these two facts had to
/// reach the operator: without them the tile argues confidently for the wrong
/// account.
ReconcileHarness duplicateAzureAccountHarness({
  InMemoryLinkedStore? linkedStore,
}) =>
    ReconcileHarness(
      linkedStore: linkedStore,
      azure: azSnap(users: [
        azUser(
          createdAt: DateTime.utc(2026, 1, 15, 12),
          lastSignIn: DateTime.utc(2026, 2, 2, 12),
        ),
        azUser(
          id: 'az-twin',
          upn: 'jane-doe@student.school.example',
          jobTitle: null,
          department: null,
          createdAt: DateTime.utc(2025, 9, 1, 12),
          lastSignIn: DateTime.utc(2026, 8, 20, 12),
        ),
      ]),
    );

/// A reconcile harness over the #386 shape: **one Office 365 account carrying
/// both halves of INV-22's stamp.**
///
/// Anna Smit is the class titular — WISA staff, a Smartschool teacher account,
/// an Office 365 account — and everything about her is in sync. The one extra
/// field is the whole fixture: her Azure account also carries
/// `companyName: GBS`, the stamp a *pupil* carries. Nothing in the tenant forbids
/// that (`companyName` says which school, never what the holder is, #358), and
/// the two linker passes read different fields of the same account.
///
/// So she used to arrive twice: as the [core.LinkedStaff] the staff pass built
/// from her WISA row, *and* as an Azure-only [core.LinkedAccount] the student
/// pass kept by INV-22's student half — a record with no WISA row and no
/// Smartschool account, which is exactly the shape `RemoveStudentFromAzure`
/// fires on. The app then offered to delete a teacher's Office 365 account.
///
/// Jane Doe is the ordinary pupil beside her — the default fixture student, so
/// she carries the usual stale-display-name repair and has a row of her own the
/// manufactured record has to be told apart from.
ReconcileHarness doubleStampedTeacherHarness() => ReconcileHarness(
      wisa: wisaSnap(staff: [wisaStaff()]),
      smartschool: ssSnap(accounts: [ssAccount(), ssStaffAccount()]),
      azure: azSnap(users: [azUser(), azStaffUser(companyName: 'GBS')]),
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
/// only in a sibling group school (id 2) we don't manage — only school 1 is in
/// the managed set. The dispatcher must raise the Smartschool departure
/// (unregister/delete) while **keeping** Azure (no `RemoveStudentFromAzure`).
ReconcileHarness movedToSiblingHarness() => ReconcileHarness(
      ourSchoolIds: const {1},
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
    );

/// A harness for the managed-schools-only Actions filter (#178). One student is
/// enrolled in school 2 and fully present in *our* Smartschool + Azure. The
/// managed set comes solely from [ourSchoolIds] (the persisted Settings path —
/// the only one since #286). Managing only school 1 leaves
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

/// A harness for the dual-enrolled student (#318). One person — WISA id `1`,
/// the Smartschool account [ssAccount] already carries — enrolled in **two**
/// group schools, of which only school 1 is ours. The shared WISA credentials
/// pull one school at a time and concatenate, so that person arrives as two
/// rows sharing a `wisaId`: the sibling school's `4ECO` first, our own `3BO`
/// second. There is no Azure account yet, so the only work owed is the
/// provisioning.
///
/// Before #318 the second row spawned a *second* record, both keyed
/// `wisa:1` and so handed the same `LinkedAccountId`: one card offering "Maak
/// een nieuw Office 365 account" (the ours record) next to the Smartschool
/// unregister/delete either/or (the sibling record) — a proposal to unregister
/// a student who is enrolled with us right now.
ReconcileHarness dualEnrolledHarness() => ReconcileHarness(
      ourSchoolIds: const {1},
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '4ECO', schoolId: 2),
          wisaStudent(wisaId: '1', classGroup: '3BO', schoolId: 1),
        ],
        classGroups: [wisaClassGroup('3BO')],
        schools: [wisaSchool(1), wisaSchool(2)],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );

/// A harness for the sibling school's class deciding *our* Smartschool move
/// (#332). The dual enrolment of [dualEnrolledHarness], now on a student who is
/// fully in step: one `wisaId`, two rows, only school 1 ours. Our row puts
/// `Lies` in `3MWW1` and Smartschool already has her there, so a correct pass
/// proposes no class move at all. The sibling's row names `3HWa` — a class our
/// school does not have and our Smartschool has never held.
///
/// Before the fix the placement resolver ignored the row the linker had chosen
/// (#318) and looked the student up again by `wisaId` in a first-wins index over
/// the pooled snapshot, so the sibling's row answered: the card offered "Wijzig
/// de klas in Smartschool — class: 3MWW1 → 3HWa", and its "Toepassen op alle"
/// cohort would have carried that write along with a rollover pass.
///
/// [siblingFirst] flips the order the two rows arrive in. The WISA pull runs
/// once per group school and concatenates, so which row lands first is an
/// accident of how the schools are configured — and it must decide nothing.
ReconcileHarness dualEnrolledClassMoveHarness({bool siblingFirst = true}) {
  final ours = wisaStudent(wisaId: '1', classGroup: '3MWW1');
  final sibling = wisaStudent(wisaId: '1', classGroup: '3HWa', schoolId: 2);
  return ReconcileHarness(
    ourSchoolIds: const {1},
    wisa: wisaSnap(
      students: siblingFirst
          ? <wapi.WisaStudent>[sibling, ours]
          : <wapi.WisaStudent>[ours, sibling],
      classGroups: [
        wisaClassGroup('3MWW1', adminCode: 'a1'),
        wisaClassGroup('3HWa', adminCode: 'b1', schoolCode: '222', schoolId: 2),
      ],
      // Both schools carry their real WISA halves, because since #334 the card
      // names the sibling school out loud and it must be named from this list.
      schools: [
        wisaSchool(1, name: 'Instituut Sancta Maria-A', code: 'ISMAA'),
        wisaSchool(2, name: 'Instituut Sancta Maria-B', code: 'ISMAB'),
      ],
    ),
    smartschool: ssSnap(
      groups: [ssGroup('3MWW1', code: '3MWW1_ss', untis: '3MWW1')],
      accounts: [ssAccount()],
      memberships: [member('jane', '3MWW1_ss')],
    ),
    azure: azSnap(users: [azUser(displayName: 'Jane Doe')]),
  );
}

/// A harness for saying the dual enrolment out loud (#334): two students whose
/// cards must read differently, and neither of whom has any work.
///
/// - **Lies Vermeulen** is enrolled in both group schools — one `wisaId`, two
///   rows. Ours puts her in `3MWW1`, where Smartschool already has her; the
///   sibling school 2 holds her in `3HWa`. Her card is in order in all three
///   systems, so the only thing on it to read is the second enrolment: "Ook
///   ingeschreven in Instituut Sancta Maria-B (ISMAB), klas 3HWa".
/// - **Nele Peeters** is the ordinary single-school student, identical in every
///   other way. Her card must render exactly as it did before the line existed.
///
/// Both schools carry their real WISA halves (long name + short code), because
/// the school on the line is named from the WISA school list and never invented
/// from an id (#204/#208). The sibling's row arrives *first*, as it does when
/// that school is configured first: pull order decides nothing (INV-21).
ReconcileHarness dualEnrolmentDisplayHarness() => ReconcileHarness(
      ourSchoolIds: const {1},
      wisa: wisaSnap(
        students: [
          wisaStudent(
            wisaId: '1',
            classGroup: '3HWa',
            schoolId: 2,
            firstName: 'Lies',
            name: 'Vermeulen',
          ),
          wisaStudent(
            wisaId: '1',
            classGroup: '3MWW1',
            firstName: 'Lies',
            name: 'Vermeulen',
          ),
          wisaStudent(
            wisaId: '2',
            classGroup: '3MWW1',
            firstName: 'Nele',
            name: 'Peeters',
          ),
        ],
        classGroups: [
          wisaClassGroup('3MWW1', adminCode: 'a1'),
          wisaClassGroup('3HWa',
              adminCode: 'b1', schoolCode: '222', schoolId: 2),
        ],
        schools: [
          wisaSchool(1, name: 'Instituut Sancta Maria-A', code: 'ISMAA'),
          wisaSchool(2, name: 'Instituut Sancta Maria-B', code: 'ISMAB'),
        ],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3MWW1', code: '3MWW1_ss', untis: '3MWW1')],
        accounts: [
          ssAccount(
            uid: 'lies',
            accountId: '1',
            mail: 'lies.vermeulen@student.school.example',
            givenName: 'Lies',
            surname: 'Vermeulen',
          ),
          ssAccount(
            uid: 'nele',
            accountId: '2',
            mail: 'nele.peeters@student.school.example',
            givenName: 'Nele',
            surname: 'Peeters',
          ),
        ],
        memberships: [member('lies', '3MWW1_ss'), member('nele', '3MWW1_ss')],
      ),
      azure: azSnap(users: [
        azUser(
          id: 'az-lies',
          upn: 'lies.vermeulen@student.school.example',
          employeeId: '1',
          displayName: 'Lies Vermeulen',
        ),
        azUser(
          id: 'az-nele',
          upn: 'nele.peeters@student.school.example',
          employeeId: '2',
          displayName: 'Nele Peeters',
        ),
      ]),
    );

/// A harness for a card that owes **two Azure writes on one account** (#321).
///
/// One student, fully linked and already in step with Smartschool, whose
/// Office 365 account is wrong in two independent ways: its `displayName` is
/// blank (so `ModifyAzureName` raises) and its `companyName` names another
/// school (so `ModifyAzureSchool` does). Applying her card is therefore a pass
/// of two Azure PATCHes against one record — the shape whose second snapshot
/// splice used to revert the first one's, because every action was resolved
/// once, up front, off the pre-apply view.
ReconcileHarness twoAzureWritesHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: '1', classGroup: '3C')],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('3C', adminCode: 'a3')],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss', untis: '3C')],
        accounts: [ssAccount()],
        memberships: [member('jane', '3C_ss')],
      ),
      azure: azSnap(users: [azUser(companyName: 'SBE')]),
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

/// A harness for the post-apply overview counts (#236). One managed school with
/// two third-year classes, both correctly placed in Smartschool, so the only
/// **student** work anywhere is Sam's stale Office 365 display name — one
/// applyable action, on 3C, which a real apply genuinely clears (the applier
/// patches the Azure record and re-links, so the refreshed view no longer raises
/// it). 3D carries nothing.
///
/// The two classes also carry group work of their own (Smartschool class data,
/// and the Office 365 groups the empty tenant has neither of). That is the point:
/// applying *the class's* work must drop 3C's badge to nothing while the
/// Klasgroepen node keeps its own count — a re-derivation of what changed, not a
/// blanket reset.
///
/// [applyGate] is awaited before every action, as everywhere else — a test that
/// needs one write refused throws from it on the call it picks.
///
/// [store] / [linkedStore] / [hub] are forwarded so a second session can be
/// resumed over the same shared state and the same realtime fan-out — what the
/// post-apply write-back is *for* (#254).
ReconcileHarness appliedClassWorkHarness({
  Future<void> Function()? applyGate,
  SnapshotStore? store,
  InMemoryLinkedStore? linkedStore,
  InMemorySignalHub? hub,
  String syncedBy = 'operator@school.example',
}) =>
    ReconcileHarness(
      applyGate: applyGate,
      store: store,
      linkedStore: linkedStore,
      hub: hub,
      syncedBy: syncedBy,
      wisa: wisaSnap(
        students: [
          wisaStudent(
              wisaId: '3', classGroup: '3C', firstName: 'Sam', name: 'Sels'),
          wisaStudent(
              wisaId: '4', classGroup: '3D', firstName: 'Tom', name: 'Tas'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup('3C', adminCode: 'a3', schoolCode: '111'),
          wisaClassGroup('3D', adminCode: 'a4', schoolCode: '111'),
        ],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('3C', code: '3C_ss', untis: '3C'),
          ssGroup('3D', code: '3D_ss', untis: '3D'),
        ],
        accounts: [
          ssAccount(
            uid: 'sam',
            accountId: '3',
            mail: 'sam.sels@student.school.example',
            givenName: 'Sam',
            surname: 'Sels',
          ),
          ssAccount(
            uid: 'tom',
            accountId: '4',
            mail: 'tom.tas@student.school.example',
            givenName: 'Tom',
            surname: 'Tas',
          ),
        ],
        memberships: [member('sam', '3C_ss'), member('tom', '3D_ss')],
      ),
      // Sam's display name is left blank (stale) so `ModifyAzureName` fires;
      // Tom's already carries his WISA name, so his class is done. Both profiles
      // name the class WISA holds them in, so #359's class repair adds nothing
      // to a fixture about one applyable action.
      azure: azSnap(users: [
        azUser(
          id: 'az3',
          upn: 'sam.sels@student.school.example',
          employeeId: '3',
        ),
        azUser(
          id: 'az4',
          upn: 'tom.tas@student.school.example',
          employeeId: '4',
          displayName: 'Tom Tas',
          department: '3D',
        ),
      ]),
      ourSchoolIds: const {1},
    );

/// A harness for the classroom-scoped bulk apply (#252). One managed school,
/// two third-year classes, and the **same** student situation in both: every
/// student's Office 365 display name is stale, so each raises a lone
/// `ModifyAzureName` and they all fall into one decision cohort.
///
/// 3C holds two of them (Sam and Sara) — enough for the same-situation bulk
/// header to render at all, since it only appears above a subset of more than
/// one — while 3D holds a third (Tom) in the identical situation. So an
/// "Alles toepassen (2)" pressed inside 3C must write exactly Sam and Sara and
/// leave Tom pending: before the fix the header resolved its situation key back
/// through the whole linked view and wrote all three, none of which the
/// operator drilled into.
///
/// Both classes are otherwise in sync with WISA (matching `untis` codes), so
/// the only work anywhere in the student family is those three names.
ReconcileHarness crossClassSituationHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(
              wisaId: '1', classGroup: '3C', firstName: 'Sam', name: 'Sels'),
          wisaStudent(
              wisaId: '2', classGroup: '3C', firstName: 'Sara', name: 'Segers'),
          wisaStudent(
              wisaId: '3', classGroup: '3D', firstName: 'Tom', name: 'Tas'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup('3C', adminCode: 'a3', schoolCode: '111'),
          wisaClassGroup('3D', adminCode: 'a4', schoolCode: '111'),
        ],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('3C', code: '3C_ss', untis: '3C'),
          ssGroup('3D', code: '3D_ss', untis: '3D'),
        ],
        accounts: [
          ssAccount(
            uid: 'sam',
            accountId: '1',
            mail: 'sam.sels@student.school.example',
            givenName: 'Sam',
            surname: 'Sels',
          ),
          ssAccount(
            uid: 'sara',
            accountId: '2',
            mail: 'sara.segers@student.school.example',
            givenName: 'Sara',
            surname: 'Segers',
          ),
          ssAccount(
            uid: 'tom',
            accountId: '3',
            mail: 'tom.tas@student.school.example',
            givenName: 'Tom',
            surname: 'Tas',
          ),
        ],
        memberships: [
          member('sam', '3C_ss'),
          member('sara', '3C_ss'),
          member('tom', '3D_ss'),
        ],
      ),
      // Every display name left blank, so all three raise `ModifyAzureName` —
      // one situation spanning two classes.
      azure: azSnap(users: [
        azUser(
          id: kSam3C,
          upn: 'sam.sels@student.school.example',
          employeeId: '1',
        ),
        azUser(
          id: kSara3C,
          upn: 'sara.segers@student.school.example',
          employeeId: '2',
        ),
        azUser(
          id: kTom3D,
          upn: 'tom.tas@student.school.example',
          employeeId: '3',
          department: '3D',
        ),
      ]),
      ourSchoolIds: const {1},
    );

/// The Azure object ids of [crossClassSituationHarness]'s three students — what
/// a test matches the recorded Graph writes against to prove which accounts a
/// classroom-scoped bulk apply actually touched (#252).
const String kSam3C = 'az-sam-3c';
const String kSara3C = 'az-sara-3c';
const String kTom3D = 'az-tom-3d';

/// A harness for the September rollover (#292). Three students moved up into
/// `4A` while Smartschool still has all three sitting in last year's `3C`, so
/// every one of them raises the very same decision — `MoveToSmartschoolClassGroup`.
///
/// One of them, Sam, *also* has a stale Office 365 display name. That is the
/// whole fixture: a second, unrelated decision on one of the three cards.
/// Grouping on the family plus the sorted set of every decision on a card put
/// Sam in a subset of his own, so the bulk header for the class change covered
/// two students instead of three — and the one it did cover, it covered together
/// with whatever else was on their cards.
///
/// The rollover is when this matters. Every student in the school changes class
/// at once, alongside whatever else drifted on their record over the summer, so
/// the operation the app most needs to do in one pass is the one the old
/// grouping fragmented hardest.
///
/// [applyGate] is awaited before every action, as in [appliedClassWorkHarness]
/// — a test that needs one write of a two-decision pass refused throws from it
/// on the call it picks (#299).
ReconcileHarness rolloverHarness({Future<void> Function()? applyGate}) =>
    ReconcileHarness(
      applyGate: applyGate,
      wisa: wisaSnap(
        students: [
          wisaStudent(
              wisaId: '1', classGroup: '4A', firstName: 'Sam', name: 'Sels'),
          wisaStudent(
              wisaId: '2', classGroup: '4A', firstName: 'Sara', name: 'Segers'),
          wisaStudent(
              wisaId: '3', classGroup: '4A', firstName: 'Tom', name: 'Tas'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup('4A', adminCode: 'a4', schoolCode: '111'),
          wisaClassGroup('3C', adminCode: 'a3', schoolCode: '111'),
        ],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('4A', code: '4A_ss', untis: '4A'),
          ssGroup('3C', code: '3C_ss', untis: '3C'),
        ],
        accounts: [
          ssAccount(
            uid: 'sam',
            accountId: '1',
            mail: 'sam.sels@student.school.example',
            givenName: 'Sam',
            surname: 'Sels',
          ),
          ssAccount(
            uid: 'sara',
            accountId: '2',
            mail: 'sara.segers@student.school.example',
            givenName: 'Sara',
            surname: 'Segers',
          ),
          ssAccount(
            uid: 'tom',
            accountId: '3',
            mail: 'tom.tas@student.school.example',
            givenName: 'Tom',
            surname: 'Tas',
          ),
        ],
        // Still in last year's class — the move every one of them needs.
        memberships: [
          member('sam', '3C_ss'),
          member('sara', '3C_ss'),
          member('tom', '3C_ss'),
        ],
      ),
      // Only Sam's display name is stale, so only Sam carries a second decision.
      azure: azSnap(users: [
        // Their Office 365 profiles already name `4A`, so the only thing the
        // rollover owes here is the Smartschool move (plus Sam's stale name).
        // The class repair of #359 has a rollover of its own and is not what
        // this fixture is about.
        azUser(
          id: kSamRollover,
          upn: 'sam.sels@student.school.example',
          employeeId: '1',
          department: '4A',
        ),
        azUser(
          id: kSaraRollover,
          upn: 'sara.segers@student.school.example',
          employeeId: '2',
          displayName: 'Sara Segers',
          department: '4A',
        ),
        azUser(
          id: kTomRollover,
          upn: 'tom.tas@student.school.example',
          employeeId: '3',
          displayName: 'Tom Tas',
          department: '4A',
        ),
      ]),
      ourSchoolIds: const {1},
    );

/// The Azure object ids of [rolloverHarness]'s three students. A test proves a
/// per-decision bulk apply left the *other* decisions alone by finding no Graph
/// write against [kSamRollover].
const String kSamRollover = 'az-sam-4a';
const String kSaraRollover = 'az-sara-4a';
const String kTomRollover = 'az-tom-4a';

/// A harness for the ours-classes guard on the class move (#333): the same
/// September rollover as [rolloverHarness], with one student whose WISA row
/// names a class **our own school does not have**.
///
/// The three students are the three cases the guard has to tell apart, and all
/// three sit in last year's `3C` in Smartschool:
/// - **Sam → `4A`** — ours, and Smartschool already has the class. The ordinary
///   rollover move.
/// - **Sara → `4B`** — ours in WISA, but Smartschool has no `4B` yet, because
///   creating it is another action on another card. She must still be proposed:
///   gating the move on the Smartschool tree instead of on our WISA inventory
///   would suppress the very moves the action exists for, every September.
/// - **Tom → `3HWa`** — a class only the sibling group school (2, unmanaged)
///   has. Nothing here is dual enrolment, so #332's fix does not reach it: his
///   is a single row, ours, naming a foreign class the way a WISA quirk or a
///   hand-edited rule would. He must raise no move at all.
///
/// `3HWa` is deliberately present in the Smartschool tree, so `resolveClass`
/// finds it and the write would go through: the only thing standing between a
/// foreign class name and a live Smartschool account is the WISA guard.
ReconcileHarness foreignClassMoveHarness() => ReconcileHarness(
      ourSchoolIds: const {1},
      wisa: wisaSnap(
        students: [
          wisaStudent(
              wisaId: '1', classGroup: '4A', firstName: 'Sam', name: 'Sels'),
          wisaStudent(
              wisaId: '2', classGroup: '4B', firstName: 'Sara', name: 'Segers'),
          wisaStudent(
              wisaId: '3', classGroup: '3HWa', firstName: 'Tom', name: 'Tas'),
        ],
        schools: [wisaSchool(1), wisaSchool(2)],
        classGroups: [
          wisaClassGroup('4A', adminCode: 'a4', schoolCode: '111'),
          wisaClassGroup('4B', adminCode: 'b4', schoolCode: '111'),
          wisaClassGroup('3C', adminCode: 'a3', schoolCode: '111'),
          // The foreign class: it exists, but in a school we do not manage.
          wisaClassGroup('3HWa',
              adminCode: 'h3', schoolCode: '222', schoolId: 2),
        ],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('4A', code: '4A_ss', untis: '4A'),
          ssGroup('3C', code: '3C_ss', untis: '3C'),
          // …and our Smartschool holds it too, so nothing but the WISA guard
          // can stop a write into it.
          ssGroup('3HWa', code: '3HWa_ss', untis: '3HWa'),
          // No `4B`: Sara's new class has yet to be created.
        ],
        accounts: [
          ssAccount(
            uid: 'sam',
            accountId: '1',
            mail: 'sam.sels@student.school.example',
            givenName: 'Sam',
            surname: 'Sels',
          ),
          ssAccount(
            uid: 'sara',
            accountId: '2',
            mail: 'sara.segers@student.school.example',
            givenName: 'Sara',
            surname: 'Segers',
          ),
          ssAccount(
            uid: 'tom',
            accountId: '3',
            mail: 'tom.tas@student.school.example',
            givenName: 'Tom',
            surname: 'Tas',
          ),
        ],
        memberships: [
          member('sam', '3C_ss'),
          member('sara', '3C_ss'),
          member('tom', '3C_ss'),
        ],
      ),
      // Every Office 365 account is in step — including the class each profile
      // names (#359) — so the class move is the only decision any of these
      // cards can carry. Tom's names the foreign class his WISA row does, which
      // the same ours-classes guard leaves alone rather than writing on.
      azure: azSnap(users: [
        azUser(
          id: kSamRollover,
          upn: 'sam.sels@student.school.example',
          employeeId: '1',
          displayName: 'Sam Sels',
          department: '4A',
        ),
        azUser(
          id: kSaraRollover,
          upn: 'sara.segers@student.school.example',
          employeeId: '2',
          displayName: 'Sara Segers',
          department: '4B',
        ),
        azUser(
          id: kTomRollover,
          upn: 'tom.tas@student.school.example',
          employeeId: '3',
          displayName: 'Tom Tas',
        ),
      ]),
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
/// [withStaleGroup] adds `GBS-9Z`, the group of a class that no longer exists —
/// the row that carries the "laat staan / verwijder" either/or of #271.
///
/// [withNonClassGroups] adds the prefixed groups that are **not** classes and so
/// belong in no class inventory: `GBS - GOK`, `GBS-OKAN`,
/// `GBS - Leerlingenraad`, `GBS - Frans - 3D`. Every one of them was a
/// Klasgroepen row before #271, carrying a ✓ and no action anybody could take.
ReconcileHarness azureClassGroupHarness({
  bool withStaleGroup = false,
  bool withNonClassGroups = false,
}) =>
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
          // Each profile names its holder's WISA class — the **bare** class, as
          // the create writes it and #359 keeps it, never the sub-grouped
          // `2F ECO` the Smartschool placement widens to.
          azUser(
              id: 'az1',
              upn: 'a1@student.school.example',
              employeeId: '1',
              displayName: 'Jane Doe',
              department: '1A'),
          azUser(
              id: 'az2',
              upn: 'a2@student.school.example',
              employeeId: '2',
              displayName: 'Jane Doe',
              department: '2F'),
          azUser(
              id: 'az3',
              upn: 'a3@student.school.example',
              employeeId: '3',
              displayName: 'Jane Doe',
              department: '2F'),
        ],
        groups: [
          azClassGroup('1A', memberIds: const ['az1']),
          if (withStaleGroup) azClassGroup('9Z'),
          if (withNonClassGroups) ...<az.AzureGroup>[
            azNonClassGroup('GBS - GOK'),
            azNonClassGroup('GBS-OKAN'),
            azNonClassGroup('GBS - Leerlingenraad'),
            azNonClassGroup('GBS - Frans - 3D'),
          ],
        ],
      ),
      ourSchoolIds: const {1},
    );

/// A harness for the class group Graph will not manage the membership of
/// (#331) — the reported bug, in the smallest shape that reproduces it.
///
/// Our school 1 runs one class, `1A`, correct in WISA and Smartschool, with two
/// students. Office 365 holds `GBS-1A` as a **mail-enabled security group**
/// carrying only the first of them, so the roster genuinely differs — and every
/// add Graph is asked to make on such a group is refused. Before #331 the class
/// card offered "werk het ledenbestand bij", the apply failed wholesale, and the
/// identical proposal was back on the next pass.
///
/// [manageable] flips the same fixture to an ordinary Microsoft 365 group: same
/// name, same address, same roster diff, and the write is proposed again. It is
/// the control that shows the group's *shape* is the only thing deciding.
ReconcileHarness unmanageableClassGroupHarness({bool manageable = false}) =>
    ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          // Named, so the account row can be told from Jane's on screen.
          wisaStudent(
              wisaId: '2', classGroup: '1A', firstName: 'Joe', name: 'Sels'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('1A', description: 'Eerste jaar A')],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('1A',
              description: 'Eerste jaar A',
              instituteNumber: '123',
              untis: '1A'),
        ],
        accounts: [
          ssAccount(
              uid: 'jane', accountId: '1', mail: 'a1@student.school.example'),
          ssAccount(
              uid: 'joe',
              accountId: '2',
              mail: 'a2@student.school.example',
              givenName: 'Joe',
              surname: 'Sels'),
        ],
        memberships: [member('jane', '1A'), member('joe', '1A')],
      ),
      azure: azSnap(
        users: [
          // Both profiles name their WISA class, so the group's shape is the
          // only thing this fixture is about (#359).
          azUser(
              id: 'az1',
              upn: 'a1@student.school.example',
              employeeId: '1',
              displayName: 'Jane Doe',
              department: '1A'),
          azUser(
              id: 'az2',
              upn: 'a2@student.school.example',
              employeeId: '2',
              displayName: 'Joe Sels',
              department: '1A'),
        ],
        groups: [
          if (manageable)
            azClassGroup('1A', memberIds: const ['az1'])
          else
            azMailEnabledSecurityClassGroup('1A', memberIds: const ['az1']),
        ],
      ),
      ourSchoolIds: const {1},
    );

/// A harness for the stale Office 365 class groups of #271. Our school 1 runs
/// exactly one class, `1A`, correct in all three systems — and Office 365 still
/// holds `GBS-9Z` and `GBS-8Y`, the groups of two classes that stopped running.
///
/// Two of them, deliberately: one stale group is a row, **two** are a "same
/// situation" bulk subset, which is where a destructive action would do its
/// worst. The delete is not bulk-sanctioned (#293), so since #326 the header
/// offers no bulk pass at all, and it is only ever the pick an operator made on
/// one row — which since #327 is the row's single proposal rather than one
/// radio of two.
///
/// The four prefixed non-class groups are here too — they must not appear in the
/// inventory at all, let alone in that subset.
///
/// `GBS-9Z` still holds the 21 members its class left behind (#305): the card
/// names that number, and a stale group with an empty roster cannot show
/// whether it *states* it or claims it is being cleared.
///
/// [idlessStaleGroup] strips `GBS-9Z` of its Azure object id, which is the one
/// stale group `DeleteAzureClassGroup` cannot act on: with no id to address a
/// `DELETE /groups/` to, the row falls back to the lone informational
/// `AzureClassGroupWithoutClass` notice (#327).
ReconcileHarness staleClassGroupHarness({bool idlessStaleGroup = false}) =>
    ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: '1', classGroup: '1A')],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('1A', description: 'Eerste jaar A')],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('1A',
              description: 'Eerste jaar A',
              instituteNumber: '123',
              untis: '1A'),
        ],
        accounts: [
          ssAccount(
              uid: 'jane', accountId: '1', mail: 'a1@student.school.example'),
        ],
        memberships: [member('jane', '1A')],
      ),
      azure: azSnap(
        users: [
          azUser(
              id: 'az1',
              upn: 'a1@student.school.example',
              employeeId: '1',
              displayName: 'Jane Doe'),
        ],
        groups: [
          azClassGroup('1A', memberIds: const ['az1']),
          azClassGroup('9Z',
              id: idlessStaleGroup ? '' : null,
              memberIds: List<String>.generate(21, (int i) => 'az-oud-$i')),
          azClassGroup('8Y'),
          azNonClassGroup('GBS - GOK'),
          azNonClassGroup('GBS-OKAN'),
          azNonClassGroup('GBS - Leerlingenraad'),
          azNonClassGroup('GBS - Frans - 3D'),
        ],
      ),
      ourSchoolIds: const {1},
    );

/// A harness for the stale Office 365 class groups the port used to say nothing
/// about (#312) — the same situation [staleClassGroupHarness] sets up, but with
/// neither leftover group shaped the way *this* port creates one.
///
/// Our school 1 runs exactly one class, `1A`, correct in all three systems.
/// Office 365 still holds two groups of classes that stopped running:
///
/// - `GBS-9Z`, a plain security group with no address and its 21 members still
///   in it — the shape the legacy WPF app made every class group in;
/// - `Klas van juf An`, renamed by hand in the portal, still answering on the
///   address `GBS-8Y@…`.
///
/// The linker orphans both — the `<PREFIX>-` namespace plus a class-shaped
/// remainder is its whole rule — yet the action engine used to demand a
/// mail-enabled group whose nickname equalled its display name, so both rows
/// reached Klasgroepen carrying a grey ✓ and nothing anybody could do.
ReconcileHarness legacyStaleClassGroupHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: '1', classGroup: '1A')],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('1A', description: 'Eerste jaar A')],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('1A',
              description: 'Eerste jaar A',
              instituteNumber: '123',
              untis: '1A'),
        ],
        accounts: [
          ssAccount(
              uid: 'jane', accountId: '1', mail: 'a1@student.school.example'),
        ],
        memberships: [member('jane', '1A')],
      ),
      azure: azSnap(
        users: [
          azUser(
              id: 'az1',
              upn: 'a1@student.school.example',
              employeeId: '1',
              displayName: 'Jane Doe'),
        ],
        groups: [
          azClassGroup('1A', memberIds: const ['az1']),
          azLegacyClassGroup('9Z',
              memberIds: List<String>.generate(21, (int i) => 'az-oud-$i')),
          azRenamedClassGroup('8Y', displayName: 'Klas van juf An'),
        ],
      ),
      ourSchoolIds: const {1},
    );

/// A harness for the Smartschool classes WISA does not have (#313) — the
/// mirror image of [staleClassGroupHarness], on the system the app can actually
/// delete a class in.
///
/// Our school 1 runs exactly one class, `1A`, correct in all three systems.
/// Smartschool additionally carries two official classes that stopped running,
/// each under the code the operator would have to hunt for by hand:
///
/// - `9Z` (`C9Z`), and
/// - `8Y` (`C8Y`).
///
/// Two of them, deliberately: one leftover is a row, **two** are a "same
/// situation" bulk subset, and that is where a destructive default would do its
/// worst. Before #313 each row's whole content was "Verwijder ze manueel als ze
/// niet meer nodig is" — an instruction to go elsewhere, and a screenful of them
/// at a September changeover.
///
/// [codelessLeftover] strips `9Z` of its class code, which is the one leftover
/// `DeleteSmartschoolClass` cannot act on: with nothing to address a `delClass`
/// to, the row falls back to the lone informational `DoNotImportFromSmartschool`
/// notice (#328).
ReconcileHarness smartschoolLeftoverClassHarness({
  bool codelessLeftover = false,
}) =>
    ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: '1', classGroup: '1A')],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('1A', description: 'Eerste jaar A')],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('1A',
              description: 'Eerste jaar A',
              instituteNumber: '123',
              untis: '1A'),
          ssGroup('9Z',
              code: codelessLeftover ? ' ' : 'C9Z',
              description: 'Zesde jaar Z',
              instituteNumber: '123',
              untis: '9Z'),
          ssGroup('8Y',
              code: 'C8Y',
              description: 'Achtste jaar Y',
              instituteNumber: '123',
              untis: '8Y'),
        ],
        accounts: [
          ssAccount(
              uid: 'jane', accountId: '1', mail: 'a1@student.school.example'),
        ],
        memberships: [member('jane', '1A')],
      ),
      azure: azSnap(
        users: [
          azUser(
              id: 'az1',
              upn: 'a1@student.school.example',
              employeeId: '1',
              displayName: 'Jane Doe'),
        ],
        groups: [
          azClassGroup('1A', memberIds: const ['az1'])
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
///
/// Wiring [store] / [linkedStore] persists what it syncs, so a second session
/// can [ReconcileHarness.resume] over the same shared view and read those cards
/// passively (#255).
ReconcileHarness azureClassMembershipHarness({
  SnapshotStore? store,
  InMemoryLinkedStore? linkedStore,
}) =>
    ReconcileHarness(
      store: store,
      linkedStore: linkedStore,
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
            department: '1A',
          ),
          azUser(
            id: 'az2',
            upn: 'sam.sels@student.school.example',
            employeeId: '2',
            displayName: 'Sam Sels',
            // Both profiles name the class WISA holds them in, so the roster is
            // the only thing out of step — the class *field* repair of #359 is
            // a different fixture's subject.
            department: '1B',
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

/// A harness for the class group a **departed** student is still sitting in
/// (#385). One class, `1A`, whose Office 365 group `GBS-1A` holds three members:
///
/// - **Jane**, still in 1A — she belongs there, and the roster agrees;
/// - **Tom**, gone from WISA altogether. Nothing is left of him but the Office
///   365 account, which per the no-alumni rule makes his linked record an
///   incomplete, Azure-only one flagged for deletion — and `companyName` is what
///   still says he was one of ours (INV-22). He was in 1A last year and nothing
///   ever took him out of the group;
/// - **Anna Smit**, the class titular. Complete in all three systems and stamped
///   the way staff are — the prefix in the comma-separated `department`, never in
///   the student `companyName` — so she is out of every removal's reach.
///
/// WISA and Smartschool agree about the class itself, so the Office 365 roster is
/// the only work anywhere in the fixture: the class row proposes exactly one
/// removal, Tom's own card names the group he is still in, and Anna is named by
/// neither.
ReconcileHarness departedStudentClassGroupHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: '1', classGroup: '1A')],
        staff: [wisaStaff()],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('1A', description: 'Eerste jaar A')],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('1A',
              description: 'Eerste jaar A',
              instituteNumber: '123',
              untis: '1A'),
        ],
        accounts: [
          ssAccount(
              uid: 'jane',
              accountId: '1',
              mail: 'jane.doe@student.school.example'),
          ssStaffAccount(),
        ],
        memberships: [member('jane', '1A')],
      ),
      azure: azSnap(
        users: [
          azUser(
            id: 'az1',
            upn: 'jane.doe@student.school.example',
            employeeId: '1',
            displayName: 'Jane Doe',
            department: '1A',
          ),
          // No WISA row and no Smartschool account: an Azure-only leaver. The
          // `department` still names the class he sat in, which is exactly how
          // stale that stamp gets once nobody maintains it.
          azUser(
            id: 'az-tom',
            upn: 'tom.sels@student.school.example',
            employeeId: '9',
            displayName: 'Tom Sels',
            department: '1A',
          ),
          azStaffUser(id: 'az-anna'),
        ],
        groups: [
          azClassGroup('1A', memberIds: const ['az1', 'az-tom', 'az-anna']),
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
          wisaSchool(1),
          wisaSchool(99, virtual: true),
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

/// A harness for #272: one brand-new WISA class that owes **two** writes.
///
/// `5WW1` is the class the report is about. Smartschool does not have it, so it
/// raises the #244 create-or-ignore either/or with the create pre-selected; and
/// Office 365 has no `GBS-5WW1` group, so it raises [CreateAzureClassGroup]
/// beside that pair as a decision of its own. One card, two selected options,
/// two systems — and applying it must land in both.
///
/// Its two students already hold Office 365 accounts, which is what a class
/// formed out of existing pupils looks like in September and what makes the
/// create chain its roster write (#245): `CreateAzureClassGroup` leaves an empty
/// group, so the one click has to perform the membership write too.
///
/// Smartschool holds only the `Leerlingen` root the class hangs under, named by
/// [ReconcileHarness.classTree], so the Smartschool half genuinely lands rather
/// than failing for want of a parent.
ReconcileHarness newClassNeedingBothWritesHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(
              wisaId: '1', classGroup: '5WW1', firstName: 'An', name: 'Aerts'),
          wisaStudent(
              wisaId: '2', classGroup: '5WW1', firstName: 'Bo', name: 'Bell'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [
          wisaClassGroup(
            '5WW1',
            description: '5e jaar Wetenschappen-Wiskunde',
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
        accounts: [
          ssAccount(
            uid: 'an.aerts',
            accountId: '1',
            mail: 'an.aerts@student.school.example',
            givenName: 'An',
            surname: 'Aerts',
          ),
          ssAccount(
            uid: 'bo.bell',
            accountId: '2',
            mail: 'bo.bell@student.school.example',
            givenName: 'Bo',
            surname: 'Bell',
          ),
        ],
        memberships: const [],
      ),
      // Both students already have their Office 365 account, names and all, so
      // the only Azure work anywhere is the class group and its roster.
      azure: azSnap(users: [
        azUser(
          id: 'az-an',
          upn: 'an.aerts@student.school.example',
          employeeId: '1',
          displayName: 'Aerts An',
        ),
        azUser(
          id: 'az-bo',
          upn: 'bo.bell@student.school.example',
          employeeId: '2',
          displayName: 'Bell Bo',
        ),
      ]),
      ourSchoolIds: const {1},
      classTree: const SmartschoolClassTree(path: 'SCHOOL'),
    );

/// A harness for the class group Graph hides from us (#280). Our school 1 runs
/// one class, `5WW1`, with two students — correct in WISA, correct in
/// Smartschool, and with both Office 365 accounts already in place.
///
/// Office 365 also already holds the class's group, answering on
/// `GBS-5WW1@student.school.example`, but its display name was renamed by hand,
/// so the prefix-scoped `listGroups` never returns it. The app therefore
/// proposed creating the group, and every apply died on the create's pre-create
/// guard with advice ("synchroniseer Azure opnieuw") that could not come true.
///
/// The Azure pull runs for real over [RenamedClassGroupGraph], because the
/// nickname back-fill only exists in the production syncer — a scripted snapshot
/// would beg the question.
///
/// The group holds **one** of the two students, so a successful adoption is
/// visible as a roster proposal rather than as silence.
///
/// Read the wire back as
/// `harness.azureTransport! as RenamedClassGroupGraph` to assert on what the
/// pass actually asked Graph.
ReconcileHarness renamedClassGroupHarness() {
  final graph = RenamedClassGroupGraph(
    className: '5WW1',
    visibleUsers: [
      azUser(
        id: 'az-an',
        upn: 'an.aerts@student.school.example',
        employeeId: '1',
        displayName: 'Aerts An',
      ),
      azUser(
        id: 'az-bo',
        upn: 'bo.bell@student.school.example',
        employeeId: '2',
        displayName: 'Bell Bo',
      ),
    ],
    memberIds: const ['az-an'],
  );
  return ReconcileHarness(
    wisa: wisaSnap(
      students: [
        wisaStudent(
            wisaId: '1', classGroup: '5WW1', firstName: 'An', name: 'Aerts'),
        wisaStudent(
            wisaId: '2', classGroup: '5WW1', firstName: 'Bo', name: 'Bell'),
      ],
      schools: [wisaSchool(1)],
      classGroups: [
        wisaClassGroup(
          '5WW1',
          description: '5e jaar Wetenschappen-Wiskunde',
          schoolCode: '111',
          schoolId: 1,
        ),
      ],
    ),
    // In sync, so the only work this fixture raises is on the Office 365 side.
    smartschool: ssSnap(
      groups: [
        ssGroup('5WW1',
            description: '5e jaar Wetenschappen-Wiskunde',
            instituteNumber: '111',
            untis: '5WW1'),
      ],
      accounts: [
        ssAccount(
          uid: 'an.aerts',
          accountId: '1',
          mail: 'an.aerts@student.school.example',
          givenName: 'An',
          surname: 'Aerts',
        ),
        ssAccount(
          uid: 'bo.bell',
          accountId: '2',
          mail: 'bo.bell@student.school.example',
          givenName: 'Bo',
          surname: 'Bell',
        ),
      ],
      memberships: [member('an.aerts', '5WW1'), member('bo.bell', '5WW1')],
    ),
    azureTransport: graph,
    ourSchoolIds: const {1},
  );
}

/// A harness for the namesake-class either/or (#250) — the shape the #225
/// notice leaves behind, alongside a genuinely new class so both readings are on
/// screen at once.
///
/// Our school 1 runs four classes, each holding a student. Smartschool already
/// carries `2G` and `2H`, but on groups that are **not flagged official**, so the
/// class link passes them over and each lands as a
/// [core.LinkedGroup.smartschoolNamesake]: the operator is told to make the
/// group official by hand (#225). `1A` and `1B` are genuinely absent downstream
/// and are the ordinary create-or-ignore choice of #244.
///
/// The bug this reproduces: both create actions refuse a namesake class, so
/// `classImportAlternative` was left holding only `DoNotImportFromWisa` — a
/// choice of one, hence always selected. **Alles toepassen** then wrote a
/// `DontImportClass` rule on `2G` and `2H`, dropping from the next WISA snapshot
/// the very classes the notice beside them had just said to repair in
/// Smartschool, while the Smartschool groups stayed behind unmanaged.
///
/// Two of each on purpose: two namesake classes put them in a "same situation"
/// subset of their own with its own bulk header — which is where the pooling
/// half of the issue shows, since they must not share the new classes' subset —
/// and two new classes give that other subset a header too, proving the fix did
/// not simply silence the list: their creates still run.
ReconcileHarness namesakeClassChoiceHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1A'),
          wisaStudent(wisaId: '2', classGroup: '1B'),
          wisaStudent(wisaId: '3', classGroup: '2G'),
          wisaStudent(wisaId: '4', classGroup: '2H'),
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
          wisaClassGroup(
            '2G',
            description: '2e lj A Klassieke talen',
            schoolCode: '111',
            schoolId: 1,
          ),
          wisaClassGroup(
            '2H',
            description: '2e lj A Handel',
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
          ssGroup('2G', code: 'G2G', official: false),
          ssGroup('2H', code: 'G2H', official: false),
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

/// The pair of mutually-exclusive candidates a WISA-departed student's account
/// doc carries (#110), as the materializer writes them since #251: both halves
/// applyable, sharing one `alternativeGroup`, the unregister pre-selected. One
/// decision, two readings — the shape whose badge used to read 2.
List<CandidateAction> departureChoice() => const <CandidateAction>[
      CandidateAction(
        family: 'student',
        kind: 'UnregisterStudentFromSmartschool',
        system: core.Origin.smartschool,
        summary: 'Schrijf de leerling uit in Smartschool',
        alternativeGroup: actions.smartschoolDepartureAlternative,
        isDefaultAlternative: true,
      ),
      CandidateAction(
        family: 'student',
        kind: 'DeleteStudentFromSmartschool',
        system: core.Origin.smartschool,
        summary: 'Verwijder dit account uit Smartschool',
        alternativeGroup: actions.smartschoolDepartureAlternative,
      ),
    ];

/// The lone **informational** candidate a student's account doc carries when
/// they sit in the wrong Office 365 class group (#245): the class-level roster
/// sync performs the one write, so the per-account row only diagnoses
/// (`canApply == false`) and the badge beside it counts zero. The shape a
/// passive card has to mark "(manueel)" (#255).
List<CandidateAction> wrongAzureClassGroupNotice() => const <CandidateAction>[
      CandidateAction(
        family: 'student',
        kind: 'AzureClassGroupMembership',
        system: core.Origin.azure,
        summary: 'Zit in de verkeerde Office 365-klasgroep: GBS-1A in plaats '
            'van GBS-1B. Werk het ledenbestand van beide klassen bij.',
        canApply: false,
      ),
    ];

/// One [MaterializedAccount] for a passive-session classroom, placed in
/// [school]/[gradeYear]/[classroom]. [withAction] decides whether it carries an
/// applyable candidate — i.e. whether [MaterializedAccount.hasPending] is true,
/// the "has actions" predicate the toggle filters on. [candidates] overrides it
/// outright for a doc that needs a specific candidate set (e.g. the either/or of
/// [departureChoice] or the notice of [wrongAzureClassGroupNotice]).
MaterializedAccount matAccount({
  required String id,
  required String label,
  String school = '1',
  String schoolLabel = 'School 1',
  String gradeYear = '3',
  String classroom = '3C',
  bool isStaff = false,
  bool withAction = false,
  List<CandidateAction>? candidates,
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
      candidates: candidates ??
          (withAction
              ? <CandidateAction>[
                  CandidateAction(
                    family: isStaff ? 'staff' : 'student',
                    kind: 'MoveToSmartschoolClassGroup',
                    system: core.Origin.smartschool,
                    summary: 'Wijzig de klas in Smartschool',
                  ),
                ]
              : const <CandidateAction>[]),
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
  Map<core.Origin, SystemSyncMeta> systemSyncs =
      const <core.Origin, SystemSyncMeta>{},
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
    // The per-system stamps another operator's sync left behind (#108), the
    // WISA one of which also names the werkdatum the roster is as of (#247).
    // Empty by default: most fixtures only need the view itself.
    systemSyncs: systemSyncs,
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
  String? id,
}) =>
    az.AzureGroup(
      id: id ?? 'az-GBS-$className',
      displayName: 'GBS-$className',
      mail: 'GBS-$className@student.school.example',
      mailNickname: 'GBS-$className',
      mailEnabled: true,
      groupTypes: const ['Unified'],
      memberIds: memberIds,
    );

/// An Office 365 class group somebody made by hand as a **mail-enabled security
/// group** (#331) — `SSM-1A` in the live tenant, the one shape among the
/// school's 372 prefixed groups whose membership Graph refuses to write.
///
/// Identical to [azClassGroup] in everything the operator sees: same name, same
/// nickname, same address. Only `securityEnabled` beside an empty `groupTypes`
/// tells them apart, which is why a roster sync was proposed on it every pass
/// and all 38 changes came back refused.
az.AzureGroup azMailEnabledSecurityClassGroup(
  String className, {
  List<String> memberIds = const [],
}) =>
    az.AzureGroup(
      id: 'az-GBS-$className',
      displayName: 'GBS-$className',
      mail: 'GBS-$className@student.school.example',
      mailNickname: 'GBS-$className',
      mailEnabled: true,
      securityEnabled: true,
      memberIds: memberIds,
    );

/// An Office 365 class group as the **legacy WPF app** created one (#312): a
/// plain security group, `GBS-<class>` in both display name and nickname, and
/// no address at all.
///
/// This is what the live tenant is full of — `SSM-3ECO`, `SSM-3MRP`, `SSM-3MWW`
/// are each `securityEnabled: true, mail: null` — and `isUnified` is false for
/// every one of them, which is what used to silence the stale-group either/or
/// on exactly the rows that needed it most.
az.AzureGroup azLegacyClassGroup(
  String className, {
  List<String> memberIds = const [],
}) =>
    az.AzureGroup(
      id: 'az-GBS-$className',
      displayName: 'GBS-$className',
      mailNickname: 'GBS-$className',
      securityEnabled: true,
      memberIds: memberIds,
    );

/// An Office 365 class group somebody **renamed by hand** in the portal (#280):
/// the display name says nothing about the class, and only the address it still
/// answers on identifies it as ours.
az.AzureGroup azRenamedClassGroup(
  String className, {
  required String displayName,
  List<String> memberIds = const [],
}) =>
    az.AzureGroup(
      id: 'az-GBS-$className',
      displayName: displayName,
      mail: 'GBS-$className@student.school.example',
      mailNickname: 'GBS-$className',
      memberIds: memberIds,
    );

/// A prefixed Office 365 group that is **not** a class (#271): a subject,
/// project or council group, named exactly as the school names them — with the
/// spaces around the separator the operator types, which is why a
/// `<PREFIX>-` strip recovers no class name from most of them.
///
/// Shaped like the class groups in every other respect (mail-enabled, nickname
/// equal to the display name), so nothing but the *name* can tell them apart.
az.AzureGroup azNonClassGroup(String displayName) => az.AzureGroup(
      id: 'az-$displayName',
      displayName: displayName,
      mail: '${displayName.replaceAll(' ', '')}@student.school.example',
      mailNickname: displayName,
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

/// A [LinkedStore] whose **writes** never complete (a hung Cosmos write) or
/// throw, while every read delegates to an inner [InMemoryLinkedStore] — the
/// persist-stall the reconcile controller must survive (#168), and since #254
/// the same for the narrow post-apply write-back.
class StallingLinkedStore implements LinkedStore {
  StallingLinkedStore({
    InMemoryLinkedStore? inner,
    this.failWith,
    this.healthyWrites = 0,
  }) : _in = inner ?? InMemoryLinkedStore();

  final InMemoryLinkedStore _in;

  /// When set, a write throws this instead of hanging.
  final Object? failWith;

  /// How many `writeMaterialized` calls land in [_in] normally before the
  /// stall/throw begins — so one session can materialize a healthy generation,
  /// drill into it, and only *then* meet a store that will not take the next
  /// view (#289).
  int healthyWrites;

  /// True once a write was attempted — proves the controller reached persist.
  bool writeAttempted = false;

  /// True once the post-apply write-back was attempted (#254).
  bool appliedWriteAttempted = false;

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
    if (healthyWrites > 0) {
      healthyWrites--;
      return _in.writeMaterialized(
        view,
        syncedBy: syncedBy,
        at: at,
        droppedDecisions: droppedDecisions,
        systemSyncs: systemSyncs,
        onProgress: onProgress,
      );
    }
    return _stall<void>();
  }

  @override
  Future<AppliedWrite> writeApplied(
    AppliedPatch patch, {
    required String appliedBy,
    required DateTime at,
  }) {
    appliedWriteAttempted = true;
    return _stall<AppliedWrite>();
  }

  Future<T> _stall<T>() {
    final fail = failWith;
    if (fail != null) return Future<T>.error(fail);
    // Never completes: models a wedged store write the controller must time out.
    return Completer<T>().future;
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
    required super.settings,
    super.passwordQueue,
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

/// A scripted Smartschool SOAP wire for the import-rule end-to-end (#202/#241):
/// answers `getAllGroupsAndClasses` with a small base64 group tree and reports
/// "no direct accounts" (code 19) for every group, recording the group codes the
/// connector asked about so a test can see the pruned ones were never read.
///
/// Wire it as [ReconcileHarness.smartschoolTransport] to drive the *production*
/// Smartschool pull, which reads the operator's rules from the live settings
/// document at pull time (#246).
///
/// [tree] and [accounts] override the fixture for a test that needs a tree of
/// its own shape — the root-scoping end-to-end (#351) needs a forest with the
/// two managed roots plus a third the pull must not visit, and accounts sitting
/// in it.
class GroupTreeSoap implements ss.SmartschoolSoapTransport {
  GroupTreeSoap({String? tree, Map<String, String>? accounts})
      : tree = tree ?? _tree,
        accounts = accounts ?? const <String, String>{};

  /// The `getAllGroupsAndClasses` payload, before base64 encoding.
  final String tree;

  /// The `getAllAccountsExtended` JSON per group code. A code with no entry
  /// answers "no direct accounts" (Smartschool code 19), which is what every
  /// group did before this seam existed.
  final Map<String, String> accounts;

  /// The group codes `getAllAccountsExtended` was called for, in walk order.
  final List<String> accountCodes = <String>[];

  static const String _tree = '<groups>'
      '<group><name>School</name><type>G</type><code>SCH</code>'
      '<visible>1</visible><children>'
      '<group><name>Organisatie</name><type>G</type><code>ORG</code>'
      '<visible>1</visible><children>'
      '<group><name>Verborgen</name><type>G</type><code>HID</code>'
      '<visible>1</visible></group>'
      '</children></group>'
      '<group><name>Klassen</name><type>G</type><code>KLA</code>'
      '<visible>1</visible><children>'
      '<group><name>1A</name><type>K</type><code>C1A</code>'
      '<visible>1</visible></group>'
      '</children></group>'
      '</children></group></groups>';

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    // The SOAPAction is `<namespace>#<method>`.
    final String method = soapAction.split('#').last;
    if (method == ss.SmartschoolMethod.getAllGroupsAndClasses) {
      return _wrap(
        method,
        base64.encode(utf8.encode(tree)),
        'xsd:base64Binary',
      );
    }
    if (method == ss.SmartschoolMethod.getAllAccountsExtended) {
      final String code =
          RegExp(r'<code[^>]*>([^<]*)</code>').firstMatch(envelope)?.group(1) ??
              '';
      accountCodes.add(code);
      final String? json = accounts[code];
      if (json == null) {
        // Smartschool: no direct accounts.
        return _wrap(method, '19', 'xsd:int');
      }
      return _wrap(method, _escape(json), 'xsd:string');
    }
    return _wrap(method, '0', 'xsd:int');
  }

  /// XML-escapes a `<return>` payload — the account JSON carries `&` and `"`,
  /// which the real service escapes on the wire and `decodeReturn` unescapes.
  String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _wrap(String method, String value, String type) =>
      '<?xml version="1.0" encoding="utf-8"?>'
      '<soap:Envelope '
      'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
      '<soap:Body><${method}Response>'
      '<return xsi:type="$type">$value</return>'
      '</${method}Response></soap:Body></soap:Envelope>';
}

/// The Smartschool class tree the live document configures, or null when it
/// configures none — in which case the harness's own [ReconcileHarness.classTree]
/// fixture stands in (#246).
///
/// Built with the production [classTreeFrom], so a test that saves a tree in
/// Instellingen gets the tree the real bootstrap would derive.
SmartschoolClassTree? _liveClassTree(SmartschoolConnection smartschool) {
  final tree = classTreeFrom(smartschool);
  final unset =
      tree.years.isEmpty && tree.grades.isEmpty && tree.path.trim().isEmpty;
  return unset ? null : tree;
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
    this.azureRefreshAge,
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
    this.modelsSettings = true,
    LiveSettings? liveSettings,
    core.PersonIdResolver? resolver,
  })  : resolver = resolver ?? SeqResolver(),
        wisaResult = (wisa ?? wisaSnap()),
        ssResult = (smartschool ?? ssSnap()),
        azResult = (azure ?? azSnap()),
        liveSettings = liveSettings ?? LiveSettings(),
        linkedStore = linkedStore ?? InMemoryLinkedStore() {
    log = LogBuffer(clock: () => kFixtureDate);
    final wisaRules = WisaImportRules();

    // The controller reads its school profiles from the live document now
    // (#246), so a fixture that curates schools has to put them there — which
    // is what `bootstrapReconcile` does when it publishes the document it just
    // loaded. Seeded only when the caller's own document carries none, so a test
    // driving Instellingen for real always wins.
    if (schoolProfiles.isNotEmpty &&
        this.liveSettings.current.wisaSchools.isEmpty) {
      this.liveSettings.publish(
            this.liveSettings.current.copyWith(wisaSchools: schoolProfiles),
          );
    }

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
      wisaSync = (previous, {bool fullRead = false}) async {
        wisaSyncs++;
        final error = wisaError;
        if (error != null) throw error;
        return inner(previous, fullRead: fullRead);
      };
    } else {
      wisaSync = (_, {bool fullRead = false}) async {
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
      ssSync = (_, {bool fullRead = false}) async {
        ssSyncs++;
        // The live document's rules win when it carries any (#246), exactly as
        // `bootstrapReconcile` reads `live.current.smartschoolRules` at pull
        // time; the [smartschoolRules] fixture stands in otherwise.
        final live = this.liveSettings.current.smartschoolRules;
        return connector.sync(
          rules: live.isEmpty ? smartschoolRules : live,
          // The roots come straight off the document, like the app's own pull
          // (#351) — there is no fixture to stand in, because the document
          // always carries roots: its own defaults until a test saves others.
          roots: this.liveSettings.current.smartschoolRoots,
        );
      };
    } else {
      ssSync = (_, {bool fullRead = false}) async {
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
            ourSchoolIds:
                _managedSchoolsOr(this.liveSettings.current, ourSchoolIds),
          ),
          ...managedStaffEmployeeIds(app.wisa.snapshot),
        },
        // …and the `<PREFIX>-<KLAS>` addresses it expects class groups on
        // (#280), exactly as `bootstrapReconcile` composes them.
        expectedGroupMailNicknames: (prefix) => managedClassGroupMailNicknames(
          app.wisa.snapshot,
          schoolPrefix: prefix,
          ourSchoolIds:
              _managedSchoolsOr(this.liveSettings.current, ourSchoolIds),
        ),
        // The prefix the pull scopes by, read live (#246) — the fixture's 'GBS'
        // until a test saves one in Instellingen.
        schoolPrefix: () {
          final prefix = this.liveSettings.current.schoolPrefix;
          return prefix.isEmpty ? 'GBS' : prefix;
        },
      );
      azSync = (previous, {bool fullRead = false}) async {
        azSyncs++;
        // Forwarded, so a test can press **Controleer op drift** and see the
        // production syncer take the full-read branch it forces (#316).
        return inner(previous, fullRead: fullRead);
      };
    } else {
      azSync = (_, {bool fullRead = false}) async {
        azSyncs++;
        // What the pass asked for, so a test with a scripted Azure pull can
        // still assert that a drift check asks for a re-read (#316).
        azFullReads += fullRead ? 1 : 0;
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
          // The apply-side connector writes into the operator's log too — the
          // app wires one `AzureConnector` for both the pull and the writes
          // (`reconcileBootstrap`), so what a write records is what the Log
          // panel shows. Without this the fixture could not see the connector's
          // own account of a membership batch (#330) at all.
          log: log,
        ),
      ),
      resolver: this.resolver,
      wisaRules: wisaRules,
      passwordQueue: passwordQueue,
      // Every settings-derived input, read from the live document on each link
      // and apply exactly as `bootstrapReconcile` wires it (#246) — so a test
      // can publish a save (or drive Instellingen for real) and see the very
      // next relink honour it. Each value falls back to this harness's own
      // fixture when the live document leaves it unset, mirroring how bootstrap
      // falls back to the dart-define sign-in config; the ~40 fixtures that
      // publish no document therefore behave exactly as before.
      settings: () {
        final s = this.liveSettings.current;
        final prefix = s.schoolPrefix.isEmpty ? 'GBS' : s.schoolPrefix;
        final domain =
            s.azure.domain.isEmpty ? 'school.example' : s.azure.domain;
        return ApplierSettings(
          studentConfig: actions.StudentActionConfig(
            schoolPrefix: prefix,
            azureDomain: domain,
          ),
          staffConfig: actions.StaffActionConfig(
            schoolPrefix: prefix,
            azureDomain: domain,
          ),
          // The Smartschool group tree a freshly created class hangs under.
          // Left unconfigured by default (no parent resolves, as in a bare
          // tenant); a fixture that applies `AddToSmartschool` for real names
          // the root here, and a test that saves one in Instellingen wins.
          classTree: _liveClassTree(s.smartschool) ?? classTree,
          // The operator's managed-school set from Settings (#178), falling back
          // to whatever set this fixture was pinned with when the document
          // configures none.
          ourSchoolIds: _managedSchoolsOr(s, ourSchoolIds),
        );
      },
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
      // The same store the scripted syncers persist through, so an apply pass
      // writes its patched snapshots back exactly as bootstrap wires it (#347).
      snapshotStore: store,
      // The same holder the WISA pull reads, so the drift gate sees a save the
      // moment Instellingen publishes it (#238) — unless this harness models no
      // settings at all (#274), which is the documented null-holder mode.
      liveSettings: modelsSettings ? this.liveSettings : null,
      publisher: publisher ?? signalHub?.publisher(),
      subscriber: subscriber ?? signalHub?.subscriber(),
      persistTimeout: persistTimeout ?? const Duration(minutes: 10),
      azureRefreshAge: azureRefreshAge ?? const Duration(minutes: 30),
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

  /// How old the Azure snapshot in hand may get before a smart sync refreshes
  /// it with an incremental delta resume (#320); defaults to the production 30
  /// minutes when unset.
  ///
  /// Because the harness clock is pinned to [kFixtureDate] and every fixture
  /// snapshot is stamped there, the default leaves the age test false in every
  /// test that does not opt in — a test wanting the refresh either seeds an
  /// `azureInitial` stamped before [kFixtureDate] or collapses this to
  /// [Duration.zero].
  final Duration? azureRefreshAge;

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

  /// The identity resolver the applier links with. Defaults to [SeqResolver],
  /// the deterministic one-id-per-natural-key fixture; a test overrides it to
  /// construct an INV-24 id collision (#319), which no snapshot can produce on
  /// its own once #318 merged the dual-enrolment rows.
  final core.PersonIdResolver resolver;

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

  /// Whether the [ReconcileController] is handed [liveSettings] at all.
  ///
  /// False builds it with **no** holder — the mode `ReconcileController` has
  /// documented since #238 ("null in the harnesses that do not model settings at
  /// all") and which #274 found had never once been exercised: every harness got
  /// a holder whether the caller supplied one or not, so the tests that say
  /// "a harness with no settings holder" only ever proved that an *empty
  /// document* arms nothing. Constructing the controller for real without one
  /// threw a `LateInitializationError`.
  ///
  /// The rest of the stack keeps reading [liveSettings] — the pulls and the
  /// applier need a document to derive from, and an embedder that skips the
  /// controller's gate has one too. Only the gate goes unwired.
  final bool modelsSettings;

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
    LinkedStore? controllerStore,
    Duration? persistTimeout,
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
      controllerStore: controllerStore,
      persistTimeout: persistTimeout,
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

  /// How many of those [azSyncs] were asked for as a **re-read** rather than an
  /// incremental resume (#316) — what **Controleer op drift** forces. Counted on
  /// the scripted pull, so a test that models no Graph at all can still prove
  /// which kind of pass ran.
  int azFullReads = 0;

  /// Models the operator flipping a WISA school **beheerd** in Instellingen —
  /// a saved *Azure pull input* (`azurePullFingerprint`, #259), so the next
  /// **Synchroniseer** re-pulls Azure instead of leaving the snapshot this
  /// session already holds alone.
  ///
  /// Which is one of the two ways a test reaches the **incremental** Azure pass:
  /// **Controleer op drift** re-reads Azure in full by design since #316, so the
  /// smart sync is the pass that resumes the stored delta token. Since #320 an
  /// aged snapshot ([azureRefreshAge]) arms the very same pass without any
  /// settings change; this stays the way to arm it at a fixture-fresh age. The
  /// school is written with the name and code a [wisaSchool] fixture carries, so
  /// the school-profile back-fill (#207) finds nothing to repair afterwards.
  void markSchoolManaged(int schoolId) {
    final profiles = <WisaSchoolProfile>[
      for (final p in liveSettings.current.wisaSchools)
        if (p.schoolId != schoolId) p,
      WisaSchoolProfile(
        schoolId: schoolId,
        name: 'School $schoolId',
        ours: true,
      ),
    ]..sort((a, b) => a.schoolId.compareTo(b.schoolId));
    liveSettings.publish(
      liveSettings.current.copyWith(wisaSchools: profiles),
    );
  }

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
