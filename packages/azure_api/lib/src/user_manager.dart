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
  /// prefix in `companyName`; staff carry it at the start of `department`.
  ///
  /// `startswith` matches the legacy convention where staff `department` is set
  /// to exactly the prefix. Graph does **not** support `contains` server-side
  /// on these properties, so an installation that buries the prefix mid-string
  /// in `department` must use [loadClientFiltered] instead (documented in the
  /// README).
  static String filterFor(String schoolPrefix) {
    final p = _escapeODataString(schoolPrefix);
    return "companyName eq '$p' or startswith(department,'$p')";
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
      'Azure: loaded ${users.length} users for "$schoolPrefix".',
    );
    return users;
  }

  /// Full read with `$select` only, filtered client-side by [schoolPrefix].
  /// Fallback for tenants where the prefix is not at the start of
  /// `department` (so server-side `startswith` would miss staff). Pulls more
  /// than [load]; use only when [load]'s server-side filter is insufficient.
  Future<List<AzureUser>> loadClientFiltered(String schoolPrefix) async {
    final url = _graph.uri('users', query: {r'$select': _select});
    final rows = await _graph.getCollection(url, onPage: _accountProgress());
    final users = rows
        .map(AzureUser.fromGraphJson)
        .where((u) => _belongsToSchool(u, schoolPrefix))
        .toList();
    _log?.addMessage(
      core.Origin.azure,
      'Azure: loaded ${users.length} users (client-filtered) for '
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
  Future<UserDelta> delta(String deltaToken, String schoolPrefix) {
    final url = _graph.uri('users/delta', query: {r'$deltatoken': deltaToken});
    return _walkDelta(url, schoolPrefix);
  }

  Future<UserDelta> _walkDelta(Uri url, String schoolPrefix) async {
    final result = await _graph.getDelta(url);
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
      'Azure: delta for "$schoolPrefix" — ${changed.length} changed, '
      '${removedIds.length} removed.',
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
      'Azure: created user $userPrincipalName.',
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
    _log?.addMessage(core.Origin.azure, 'Azure: updated user $id.');
  }

  /// Deletes a user by object id or UPN. Mirrors legacy `DeleteUser`.
  Future<void> deleteUser(String idOrUpn) async {
    await _graph.delete(_graph.uri('users/${Uri.encodeComponent(idOrUpn)}'));
    _log?.addMessage(core.Origin.azure, 'Azure: deleted user $idOrUpn.');
  }

  /// Resets an existing user's password (PATCH `users/{id}` with a
  /// `passwordProfile`). Mirrors legacy `Azure.UserManager.SetPassword`, used by
  /// the on-demand Passwords screen (#180) — distinct from [createUser], which
  /// is the only other place a password is written.
  ///
  /// [idOrUpn] is the object id or UPN. [forceChangePasswordNextSignIn] defaults
  /// to `true`, matching the legacy reset (the holder must pick a new password on
  /// next login).
  Future<void> setPassword(
    String idOrUpn,
    String password, {
    bool forceChangePasswordNextSignIn = true,
  }) async {
    await _graph.patchJson(
      _graph.uri('users/${Uri.encodeComponent(idOrUpn)}'),
      <String, dynamic>{
        'passwordProfile': <String, dynamic>{
          'forceChangePasswordNextSignIn': forceChangePasswordNextSignIn,
          'password': password,
        },
      },
    );
    _log?.addMessage(core.Origin.azure, 'Azure: reset password for $idOrUpn.');
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

  bool _belongsToSchool(AzureUser u, String prefix) {
    final p = prefix.toLowerCase();
    final company = u.companyName?.toLowerCase();
    final dept = u.department?.toLowerCase();
    return company == p || (dept != null && dept.startsWith(p));
  }

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
