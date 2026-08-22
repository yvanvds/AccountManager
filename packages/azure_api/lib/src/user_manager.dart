import 'package:account_core/account_core.dart' as core;

import 'graph/graph_client.dart';
import 'graph/graph_request.dart';
import 'models/azure_user.dart';

/// Result of a `/users/delta` walk, split into upserts and removals.
class UserDelta {
  /// Users created or changed since the last sync, already filtered to the
  /// school (by `companyName` / `department`).
  final List<AzureUser> changed;

  /// Azure object ids of users Graph reported as removed (`@removed`). Not
  /// prefix-filtered — the removed payload carries only the id, so the caller
  /// reconciles these against the users it already knows.
  final List<String> removedIds;

  /// Token to resume the next incremental sync from.
  final String? deltaToken;

  const UserDelta({
    required this.changed,
    required this.removedIds,
    this.deltaToken,
  });
}

/// Thrown when Graph refuses a password write (`403`), instead of letting the
/// bare [GraphException] reach the operator (#216).
///
/// Writing `passwordProfile` is privileged well beyond an ordinary user write,
/// and a refusal is nearly always one of two fixable directory-side causes
/// rather than a bug: the sign-in lacks the
/// `User-PasswordProfile.ReadWrite.All` delegated permission (admin-consented
/// on the app registration, and only present on tokens issued *after* that
/// consent), or the signed-in operator holds no role allowed to reset this
/// target's password — User Administrator for ordinary users, Privileged
/// Authentication Administrator when the target is itself an administrator.
///
/// [toString] names both, so the reason survives into the log; the UI layer
/// phrases it for the operator.
class AzurePasswordPermissionException implements Exception {
  const AzurePasswordPermissionException(this.target, this.cause);

  /// The object id or UPN whose password write was refused.
  final String target;

  /// The refusal Graph sent back (`403`, usually `Authorization_RequestDenied`).
  final GraphException cause;

  /// Graph's own error code, when it sent one.
  String? get code => cause.code;

  @override
  String toString() =>
      'Not allowed to set the password of $target. The sign-in needs the '
      'User-PasswordProfile.ReadWrite.All Graph permission (admin-consented, '
      'and re-consented since the last token), and the signed-in operator '
      'needs a role that may reset this account (User Administrator, or '
      'Privileged Authentication Administrator for an administrator). '
      'Graph said: $cause';
}

/// Reads and writes Azure AD users via Microsoft Graph.
///
/// Mirrors the legacy `UserManager.cs` surface, but never downloads the whole
/// tenant: [load] uses `$filter` + `$select`, and [delta] uses `/users/delta`
/// (PAIN-2). Legacy reference (read-only):
/// `legacy-wpf/AccountApi/Azure/UserManager.cs`.
class UserManager {
  final GraphClient _graph;
  final core.ILog? _log;

  UserManager(this._graph, {core.ILog? log}) : _log = log;

  static final String _select = AzureUser.graphSelectFields.join(',');

  /// Emit a progress log line for every this-many accounts pulled (issue #177).
  static const int _progressEvery = 100;

  /// Headers required for advanced directory queries (`$count`,
  /// `startswith`, `$filter` with `or`). Graph rejects these without
  /// `ConsistencyLevel: eventual`.
  static const Map<String, String> _advancedQueryHeaders = {
    'ConsistencyLevel': 'eventual',
  };

  /// Server-side `$filter` selecting the school's users: students carry the
  /// prefix in `companyName`; staff carry it somewhere in `department`.
  ///
  /// Staff `department` is maintained by other software as a comma-separated
  /// list of every school prefix the teacher is active at (`GBS,SSM`), so
  /// `startswith` matches only when we happen to be listed first.
  ///
  /// **This leg cannot be widened** (#268). Graph offers `eq`, `startswith`,
  /// `in` and `ne` on these properties and no `contains` at all; `endswith` is
  /// limited to `mail` / `otherMails` / `userPrincipalName`, and `$search`
  /// tokenizes only `displayName` / `description`. So there is no server-side
  /// query for "our prefix somewhere in the list", and the alternative is a
  /// full-tenant read — the very thing PAIN-2 exists to avoid. The ruling is
  /// therefore: keep this narrow fast path, and complete it with the two legs
  /// that are **not** limited to what OData can ask:
  ///
  /// - the `employeeId` back-fill (#231), which adopts every staff member WISA
  ///   lists that this filter did not turn up — on the full *and* the
  ///   incremental path; and
  /// - [_belongsToSchool], which every leg that filters in Dart uses, and which
  ///   applies the real comma-list rule — the linker's own, shared from
  ///   `account_core` (#279).
  ///
  /// [loadClientFiltered] remains the fallback for an installation that needs
  /// the bulk read itself to see them, at the cost of a full-tenant read.
  static String filterFor(String schoolPrefix) {
    final p = _escapeODataString(schoolPrefix);
    return "companyName eq '$p' or startswith(department,'$p')";
  }

  /// How many `employeeId`s one [loadByEmployeeIds] request asks about. Graph
  /// caps an `in (…)` list well below the URL length limit, so the lookup is
  /// chunked rather than sent as one enormous filter.
  static const int _employeeIdChunk = 15;

  /// Targeted read of the users carrying one of [employeeIds], regardless of
  /// `companyName`/`department` (#224).
  ///
  /// [load] and [delta] are deliberately scoped to the school's own prefix
  /// (PAIN-2), which makes them blind to exactly the account this lookup is
  /// for: a student who transferred in from a sibling school inside the tenant
  /// already has an Office 365 account whose `employeeId` is their WISA id, but
  /// whose `companyName` is unset and whose `department` still names the other
  /// school. Nothing else about such an account is trustworthy — another school
  /// routinely mangles the given/family-name order of a foreign name, so the UPN
  /// is not a usable key. The `employeeId` is.
  ///
  /// The caller passes only the ids it could **not** account for, so the set
  /// stays small and bounded and the PAIN-2 property of the bulk read survives.
  /// Blank ids are dropped, duplicates collapse, and the result is de-duplicated
  /// by Azure object id.
  Future<List<AzureUser>> loadByEmployeeIds(
      Iterable<String> employeeIds) async {
    // A set literal preserves insertion order, so the chunking (and therefore
    // the requests a test asserts on) is deterministic.
    final unique = <String>{
      for (final raw in employeeIds)
        if (raw.trim().isNotEmpty) raw.trim(),
    }.toList();
    if (unique.isEmpty) return const <AzureUser>[];

    final found = <String, AzureUser>{};
    for (var i = 0; i < unique.length; i += _employeeIdChunk) {
      final chunk = unique.sublist(
        i,
        (i + _employeeIdChunk).clamp(0, unique.length),
      );
      final literals =
          chunk.map((id) => "'${_escapeODataString(id)}'").join(',');
      final url = _graph.uri(
        'users',
        query: {
          r'$select': _select,
          r'$count': 'true',
          r'$filter': 'employeeId in ($literals)',
        },
      );
      final rows = await _graph.getCollection(
        url,
        headers: _advancedQueryHeaders,
      );
      for (final row in rows) {
        final user = AzureUser.fromGraphJson(row);
        found[user.id] = user;
      }
    }
    _log?.addMessage(
      core.Origin.azure,
      'Azure: ${unique.length} employeeId(s) rechtstreeks opgezocht — '
      '${found.length} bestaand(e) account(s) gevonden.',
    );
    return found.values.toList();
  }

  /// The single user carrying [employeeId], or `null` when the tenant has none.
  ///
  /// The pre-create guard of #224: `employeeId` is the one key that survives a
  /// transfer between group schools, so an account bearing it already belongs to
  /// this person and a second one must never be created. Graph resolves a UPN
  /// collision by suffixing, so without this check a duplicate create *succeeds*
  /// and is silent.
  Future<AzureUser?> findByEmployeeId(String employeeId) async {
    final matches = await loadByEmployeeIds([employeeId]);
    return matches.isEmpty ? null : matches.first;
  }

  /// Bulk read of the school's users with `$filter` + `$select`, following
  /// pagination. This is the first-sync path; subsequent syncs should use
  /// [delta].
  Future<List<AzureUser>> load(String schoolPrefix) async {
    final url = _graph.uri(
      'users',
      query: {
        r'$select': _select,
        r'$count': 'true',
        r'$filter': filterFor(schoolPrefix),
      },
    );
    final rows = await _graph.getCollection(
      url,
      headers: _advancedQueryHeaders,
      onPage: _accountProgress(),
    );
    final users = rows.map(AzureUser.fromGraphJson).toList();
    _log?.addMessage(
      core.Origin.azure,
      'Azure: ${users.length} gebruikers opgehaald voor "$schoolPrefix".',
    );
    return users;
  }

  /// Full read with `$select` only, filtered client-side by [schoolPrefix]
  /// through [_belongsToSchool] — so it really does see the staff whose
  /// `department` lists us second, which is its whole reason for existing.
  ///
  /// Fallback for tenants where the prefix is not at the start of `department`
  /// (so server-side `startswith` would miss staff). Pulls the whole tenant, far
  /// more than [load]; use only when [load]'s server-side filter plus the
  /// `employeeId` back-fill is insufficient.
  Future<List<AzureUser>> loadClientFiltered(String schoolPrefix) async {
    final url = _graph.uri('users', query: {r'$select': _select});
    final rows = await _graph.getCollection(url, onPage: _accountProgress());
    final users = rows
        .map(AzureUser.fromGraphJson)
        .where((u) => _belongsToSchool(u, schoolPrefix))
        .toList();
    _log?.addMessage(
      core.Origin.azure,
      'Azure: ${users.length} gebruikers opgehaald (lokaal gefilterd) voor '
      '"$schoolPrefix".',
    );
    return users;
  }

  /// First delta read: walks `/users/delta` to build the initial set and
  /// returns the resume token.
  ///
  /// Note this enumerates the **whole** directory (delta query does not honour
  /// the `companyName`/`department` filter), so it does not by itself fix
  /// PAIN-2. The connector primes the first sync with [load] + [latestDeltaToken]
  /// instead; this method exists for callers that explicitly want a
  /// data-bearing initial delta.
  Future<UserDelta> deltaInitial(String schoolPrefix) {
    final url = _graph.uri('users/delta', query: {r'$select': _select});
    return _walkDelta(url, schoolPrefix);
  }

  /// Primes incremental syncs without reading any user data: asks Graph for the
  /// delta token representing "now" via `$deltatoken=latest`. Paired with
  /// [load] on the first sync so the bulk read stays `$filter`-scoped (PAIN-2)
  /// while still establishing a resume point.
  Future<String?> latestDeltaToken() async {
    final url = _graph.uri('users/delta', query: {r'$deltatoken': 'latest'});
    final result = await _graph.getDelta(url);
    return result.deltaToken;
  }

  /// Incremental delta read: resumes from a token returned by a previous
  /// [deltaInitial]/[delta] call. Only changed and removed users come back.
  ///
  /// This is the one read whose caller (`AzureConnector.sync`) comes prepared
  /// for a refusal: a token Graph no longer accepts is recovered from with a
  /// full read (#213). The transport is told so, so it logs that reply as a
  /// detail rather than as an error the operator should act on (#229). Every
  /// other failure — including a resume that fails for any other reason — stays
  /// an error.
  Future<UserDelta> delta(String deltaToken, String schoolPrefix) {
    final url = _graph.uri('users/delta', query: {r'$deltatoken': deltaToken});
    return _walkDelta(
      url,
      schoolPrefix,
      expected: (e) => e.isRejectedDeltaToken,
    );
  }

  Future<UserDelta> _walkDelta(
    Uri url,
    String schoolPrefix, {
    GraphFailurePredicate? expected,
  }) async {
    final result = await _graph.getDelta(url, expected: expected);
    final changed = <AzureUser>[];
    final removedIds = <String>[];
    for (final row in result.values) {
      if (AzureUser.isRemoved(row)) {
        final id = row['id'] as String?;
        if (id != null) removedIds.add(id);
        continue;
      }
      final user = AzureUser.fromGraphJson(row);
      if (_belongsToSchool(user, schoolPrefix)) changed.add(user);
    }
    _log?.addMessage(
      core.Origin.azure,
      'Azure: delta voor "$schoolPrefix" — ${changed.length} gewijzigd, '
      '${removedIds.length} verwijderd.',
    );
    return UserDelta(
      changed: changed,
      removedIds: removedIds,
      deltaToken: result.deltaToken,
    );
  }

  /// Fetches one user by object id or UPN. Returns `null` on `404`.
  Future<AzureUser?> getUser(String idOrUpn) async {
    final url = _graph.uri(
      'users/${Uri.encodeComponent(idOrUpn)}',
      query: {r'$select': _select},
    );
    try {
      final json = await _graph.getJson(url);
      return AzureUser.fromGraphJson(json);
    } on GraphException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Whether a user with [idOrUpn] exists. Mirrors legacy `DoesUserExist`.
  Future<bool> userExists(String idOrUpn) async =>
      (await getUser(idOrUpn)) != null;

  /// Creates a user. Mirrors legacy `CreateStudent`/`CreateStaffMember` →
  /// `CreateUser`. [mailNickname] defaults to the UPN local part. Returns the
  /// created user projected to [AzureUser].
  Future<AzureUser> createUser({
    required String userPrincipalName,
    required String displayName,
    required String password,
    String givenName = '',
    String surname = '',
    String? employeeId,
    String? department,
    String? companyName,
    String? jobTitle,
    String? mailNickname,
    bool accountEnabled = true,
    bool forceChangePasswordNextSignIn = false,
    String userType = 'Member',
  }) async {
    final nickname = mailNickname ?? userPrincipalName.split('@').first;
    final body = <String, dynamic>{
      'accountEnabled': accountEnabled,
      'displayName': displayName,
      'givenName': givenName,
      'surname': surname,
      'userPrincipalName': userPrincipalName,
      'mailNickname': nickname,
      'userType': userType,
      'passwordProfile': {
        'forceChangePasswordNextSignIn': forceChangePasswordNextSignIn,
        'password': password,
      },
      if (employeeId != null) 'employeeId': employeeId,
      if (department != null) 'department': department,
      if (companyName != null) 'companyName': companyName,
      if (jobTitle != null) 'jobTitle': jobTitle,
    };
    final json = await _graph.postJson(_graph.uri('users'), body);
    _log?.addMessage(
      core.Origin.azure,
      'Azure: gebruiker $userPrincipalName aangemaakt.',
    );
    // The create response echoes the new resource; fall back to the request
    // values for any field Graph omitted from its echo.
    return AzureUser(
      id: (json['id'] as String?) ?? '',
      upn: (json['userPrincipalName'] as String?) ?? userPrincipalName,
      employeeId: employeeId,
      displayName: displayName,
      givenName: givenName,
      surname: surname,
      companyName: companyName,
      department: department,
      accountEnabled: accountEnabled,
    );
  }

  /// Patches the mutable fields of a user. Only non-null arguments are sent.
  /// Pass [id] as the object id or current UPN. Mirrors the legacy
  /// `Update`/`UpdatePrincipalName`/`Change*` surface.
  Future<void> updateUser(
    String id, {
    String? userPrincipalName,
    String? displayName,
    String? givenName,
    String? surname,
    String? companyName,
    String? department,
    String? employeeId,
    bool? accountEnabled,
  }) async {
    final body = <String, dynamic>{
      if (userPrincipalName != null) 'userPrincipalName': userPrincipalName,
      if (displayName != null) 'displayName': displayName,
      if (givenName != null) 'givenName': givenName,
      if (surname != null) 'surname': surname,
      if (companyName != null) 'companyName': companyName,
      if (department != null) 'department': department,
      if (employeeId != null) 'employeeId': employeeId,
      if (accountEnabled != null) 'accountEnabled': accountEnabled,
    };
    if (body.isEmpty) return;
    await _graph.patchJson(
      _graph.uri('users/${Uri.encodeComponent(id)}'),
      body,
    );
    _log?.addMessage(core.Origin.azure, 'Azure: gebruiker $id bijgewerkt.');
  }

  /// Deletes a user by object id or UPN. Mirrors legacy `DeleteUser`.
  Future<void> deleteUser(String idOrUpn) async {
    await _graph.delete(_graph.uri('users/${Uri.encodeComponent(idOrUpn)}'));
    _log?.addMessage(
      core.Origin.azure,
      'Azure: gebruiker $idOrUpn verwijderd.',
    );
  }

  /// Resets an existing user's password (PATCH `users/{id}` with a
  /// `passwordProfile`). Mirrors legacy `Azure.UserManager.SetPassword`, used by
  /// the on-demand Passwords screen (#180) — distinct from [createUser], which
  /// is the only other place a password is written.
  ///
  /// [idOrUpn] is the object id or UPN. [forceChangePasswordNextSignIn] defaults
  /// to `true`, matching the legacy reset (the holder must pick a new password on
  /// next login).
  ///
  /// A `403` — the permission/role gap of #216 — is rethrown as an
  /// [AzurePasswordPermissionException] naming what the directory is missing;
  /// every other Graph failure propagates unchanged as a [GraphException].
  Future<void> setPassword(
    String idOrUpn,
    String password, {
    bool forceChangePasswordNextSignIn = true,
  }) async {
    try {
      await _graph.patchJson(
        _graph.uri('users/${Uri.encodeComponent(idOrUpn)}'),
        <String, dynamic>{
          'passwordProfile': <String, dynamic>{
            'forceChangePasswordNextSignIn': forceChangePasswordNextSignIn,
            'password': password,
          },
        },
      );
    } on GraphException catch (e) {
      if (e.statusCode != 403) rethrow;
      throw AzurePasswordPermissionException(idOrUpn, e);
    }
    _log?.addMessage(
      core.Origin.azure,
      'Azure: wachtwoord van $idOrUpn opnieuw ingesteld.',
    );
  }

  /// Builds a unique UPN from a name, appending a numeric suffix on collision.
  /// Ports the legacy `CreatePrincipalName`: accents stripped, lower-cased,
  /// non-`[a-z0-9_.+-]` removed. Students live under `student.<domain>`, staff
  /// under `<domain>`.
  Future<String> createPrincipalName(
    String firstName,
    String lastName,
    String azureDomain, {
    required bool isStudent,
  }) async {
    final local = '${_normalize(firstName)}.${_normalize(lastName)}';
    final domain = isStudent ? 'student.$azureDomain' : azureDomain;
    var candidate = '$local@$domain';
    var suffix = 1;
    while (await userExists(candidate)) {
      suffix++;
      candidate = '$local$suffix@$domain';
    }
    return candidate;
  }

  /// Builds an `onPage` callback that logs one line each time another
  /// [_progressEvery] accounts have been pulled (issue #177), so a long Azure
  /// bulk read visibly advances in the Log panel. Returns `null` when no log
  /// sink is attached, so paging stays allocation-free in that case.
  void Function(int total)? _accountProgress() {
    final log = _log;
    if (log == null) return null;
    var nextMilestone = _progressEvery;
    return (total) {
      while (total >= nextMilestone) {
        log.addMessage(
          core.Origin.azure,
          'Azure: $nextMilestone accounts opgehaald…',
        );
        nextMilestone += _progressEvery;
      }
    };
  }

  /// Whether [u] belongs to [prefix]'s school under the **domain** rule
  /// (INV-22), which is deliberately wider than [filterFor]: a student is an
  /// exact `companyName` match, a staff member is a `department` that *contains*
  /// the prefix anywhere in the comma-separated list other software maintains
  /// (`SSM,GBS`).
  ///
  /// Every leg that filters here does it in Dart — the [delta] walk and
  /// [loadClientFiltered] — so none of them is bound by what OData can express.
  /// They inherited the `startswith` narrowing anyway until #268, which cost:
  /// an incremental pass silently dropped every change to a staff member listed
  /// second (their stale row survived from the previous snapshot, so nothing
  /// even looked missing), and [loadClientFiltered] could not see them either,
  /// which is the one thing it exists to do.
  ///
  /// This is now a call, not a copy (#279): `core.belongsToSchool` is the single
  /// definition the linker applies too. A read narrower than the linker drops
  /// rows the linker would have kept, and the linker never gets to ask about a
  /// row the read threw away — so the two must not be able to drift apart. Do
  /// not re-inline the test here.
  bool _belongsToSchool(AzureUser u, String prefix) => core.belongsToSchool(
        companyName: u.companyName,
        department: u.department,
        schoolPrefix: prefix,
      );

  /// Lower-cases, strips diacritics, and drops characters Azure rejects in a
  /// UPN local part. Ports the legacy accent table and `[^a-zA-Z_.+-]` filter.
  static String _normalize(String input) {
    final buffer = StringBuffer();
    for (final ch in input.toLowerCase().split('')) {
      final mapped = _accents[ch] ?? ch;
      if (RegExp(r'[a-z0-9_.+-]').hasMatch(mapped)) buffer.write(mapped);
    }
    return buffer.toString();
  }

  static const Map<String, String> _accents = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'ç': 'c',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
  };

  /// Escapes single quotes in an OData string literal by doubling them.
  static String _escapeODataString(String value) => value.replaceAll("'", "''");
}
