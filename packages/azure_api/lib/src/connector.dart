import 'package:account_core/account_core.dart' as core;

import 'auth/auth_provider.dart';
import 'auth/credentials.dart';
import 'graph/graph_client.dart';
import 'graph/graph_request.dart';
import 'graph/graph_transport.dart';
import 'group_manager.dart';
import 'models/azure_group.dart';
import 'models/azure_user.dart';
import 'snapshot.dart';
import 'user_manager.dart';

/// Entry point for the Azure AD / Office 365 connector.
///
/// Wires the [AzureAuthProvider], the swappable [GraphTransport], and the
/// [UserManager]/[GroupManager] together, and builds an [AzureSnapshot] with
/// [sync]. The PAIN-2 fix lives here: the first sync does a `$filter`-scoped
/// bulk read and primes a delta token; later syncs apply only the changed set
/// from `/users/delta`.
///
/// Spec: `docs/domain-model.md` §3.6, §3.8, §6.1, §8. Legacy reference
/// (read-only): `legacy-wpf/AccountApi/Azure/`.
class AzureConnector {
  final AzureCredentials credentials;
  final GraphTransport _transport;
  final bool _ownsTransport;
  final core.ILog? _log;

  /// User reads and writes.
  final UserManager users;

  /// Group reads and membership writes.
  final GroupManager groups;

  AzureConnector._({
    required this.credentials,
    required GraphTransport transport,
    required bool ownsTransport,
    required this.users,
    required this.groups,
    core.ILog? log,
  })  : _transport = transport,
        _ownsTransport = ownsTransport,
        _log = log;

  factory AzureConnector({
    required AzureCredentials credentials,
    required AzureAuthProvider authProvider,
    GraphTransport? transport,
    Uri? baseUrl,
    core.ILog? log,
  }) {
    final ownsTransport = transport == null;
    final effectiveTransport = transport ?? HttpGraphTransport();
    final graph = GraphClient(
      transport: effectiveTransport,
      auth: authProvider,
      baseUrl: baseUrl,
      log: log,
    );
    return AzureConnector._(
      credentials: credentials,
      transport: effectiveTransport,
      ownsTransport: ownsTransport,
      users: UserManager(graph, log: log),
      groups: GroupManager(graph, log: log),
      log: log,
    );
  }

  /// Reads the school's users and groups into a fresh [AzureSnapshot].
  ///
  /// - [deltaToken] `null` → first/full sync: `$filter`+`$select` bulk read
  ///   ([UserManager.load]) plus a primed delta token for next time.
  /// - [deltaToken] set → incremental: applies `/users/delta` changes and
  ///   removals on top of [previous] (required for a complete user list; when
  ///   omitted, only the changed users are returned).
  ///
  /// A delta token Graph refuses is never fatal (#213): the token is discarded,
  /// the rejection is logged with the token's age, and the pass falls back to a
  /// full read that primes a fresh token. The operator gets a complete snapshot
  /// instead of an aborted pass that would re-send the same dead token forever.
  /// Because the recovery is complete, nothing about it is logged as an error —
  /// [UserManager.delta] tells the transport this refusal is expected, so a pass
  /// that recovered does not read as a broken one (#229).
  ///
  /// **Token invariant:** the token on the returned snapshot is always one
  /// minted during *this* sync — from this pass's delta walk, or from
  /// [UserManager.latestDeltaToken] on a full read — never a carried-over older
  /// one. That is what makes [AzureSnapshot.fetchedAt] a truthful age for the
  /// token it ships with, and what keeps a token from silently ageing past
  /// Graph's 30-day limit while every sync appears to succeed.
  ///
  /// [expectedEmployeeIds] are the WISA ids this pass expects to find accounts
  /// for. Any that the prefix-scoped read did not turn up are looked up
  /// directly by `employeeId` and merged in ([_adoptByEmployeeId], #224), so a
  /// student who transferred in from a sibling group school — whose account
  /// carries neither our `companyName` nor our `department` — is seen instead of
  /// being proposed for a second, duplicate account.
  ///
  /// [schoolPrefix] overrides [AzureCredentials.schoolPrefix] for this one pull
  /// (#246). The prefix is operator-editable in Instellingen while the app runs,
  /// but the credentials are baked into the connector at bootstrap — so the
  /// caller passes the prefix as it stands *now* and the credentials' copy is
  /// only the default. Both managers already take it as a parameter, so nothing
  /// below this line had to change.
  Future<AzureSnapshot> sync({
    String? deltaToken,
    AzureSnapshot? previous,
    Iterable<String> expectedEmployeeIds = const <String>[],
    String? schoolPrefix,
  }) async {
    final prefix = schoolPrefix ?? credentials.schoolPrefix;
    final groupList = await groups.listGroups(prefix);

    if (deltaToken == null) {
      return _fullRead(groupList, expectedEmployeeIds, prefix);
    }

    final UserDelta delta;
    try {
      delta = await users.delta(deltaToken, prefix);
    } on GraphException catch (e) {
      if (!e.isRejectedDeltaToken) rethrow;
      _log?.addMessage(
        core.Origin.azure,
        'Azure: Graph weigerde het bewaarde deltatoken '
        '(${_tokenAge(previous)}) — $e. Het wordt weggegooid en alle accounts '
        'worden opnieuw volledig opgehaald.',
      );
      return _fullRead(groupList, expectedEmployeeIds, prefix);
    }

    // No `@odata.deltaLink` on the final page means this walk produced no
    // resume point. Keeping the old token here (the pre-#213 behaviour) let a
    // token stop advancing while every sync still reported success, until it
    // aged past Graph's 30-day limit and every later pass died on it. Dropping
    // it costs one full read next pass and always leaves a fresh token behind.
    if (delta.deltaToken == null) {
      _log?.addMessage(
        core.Origin.azure,
        'Azure: het delta-antwoord bevatte geen deltaLink, dus deze '
        'synchronisatie laat geen hervattingstoken achter — de volgende '
        'synchronisatie haalt alle accounts opnieuw volledig op.',
      );
    }

    final userList = await _adoptByEmployeeId(
      _applyDelta(previous?.users ?? const [], delta),
      expectedEmployeeIds,
    );
    return AzureSnapshot(
      fetchedAt: _now(),
      deltaToken: delta.deltaToken,
      users: userList,
      groups: groupList,
    );
  }

  /// The full user read — `$filter`+`$select` bulk pull plus a freshly primed
  /// delta token — over the [groupList] this pass already read.
  ///
  /// The token is primed *before* the bulk read so anything that changes while
  /// the (long) read runs is picked up by the next delta rather than lost.
  Future<AzureSnapshot> _fullRead(
    List<AzureGroup> groupList,
    Iterable<String> expectedEmployeeIds,
    String schoolPrefix,
  ) async {
    final token = await users.latestDeltaToken();
    final userList = await _adoptByEmployeeId(
      await users.load(schoolPrefix),
      expectedEmployeeIds,
    );
    return AzureSnapshot(
      fetchedAt: _now(),
      deltaToken: token,
      users: userList,
      groups: groupList,
    );
  }

  /// Completes [current] with the accounts the prefix-scoped read cannot see
  /// (#224): for every id in [expectedEmployeeIds] that no user in [current]
  /// carries, one targeted `employeeId` lookup, merged in by object id.
  ///
  /// This is the whole fix for the transferred-student duplicate. The `$filter`
  /// that keeps the bulk read bounded (PAIN-2) — `companyName eq` /
  /// `startswith(department, …)` against the school prefix — matches nothing on
  /// an account a sibling school left behind, and `_walkDelta` applies the same
  /// test client-side, so an incremental pass is equally blind. The linker
  /// already has the `employeeId → wisaId` bridge; it just never got the row.
  /// Only the ids that went unaccounted for are asked about, so the set stays
  /// small.
  ///
  /// A Graph failure here is **not** fatal: this step enriches a snapshot that
  /// is otherwise complete, and losing the whole pass over it would be worse
  /// than missing the adoption for one sync. The failure is logged as an error,
  /// and `AddStudentToAzure` still refuses to create over an existing
  /// `employeeId` at apply time, so a missed adoption cannot become a duplicate.
  Future<List<AzureUser>> _adoptByEmployeeId(
    List<AzureUser> current,
    Iterable<String> expectedEmployeeIds,
  ) async {
    final known = <String>{
      for (final u in current)
        if ((u.employeeId ?? '').trim().isNotEmpty)
          u.employeeId!.trim().toLowerCase(),
    };
    final missing = <String>{
      for (final id in expectedEmployeeIds)
        if (id.trim().isNotEmpty && !known.contains(id.trim().toLowerCase()))
          id.trim(),
    };
    if (missing.isEmpty) return current;

    final List<AzureUser> adopted;
    try {
      adopted = await users.loadByEmployeeIds(missing);
    } on Object catch (e) {
      _log?.addError(
        core.Origin.azure,
        'Azure: kon ${missing.length} niet-gekoppelde employeeId(s) niet '
        'opzoeken — $e. Bestaande accounts daarvoor blijven deze keer '
        'onzichtbaar.',
      );
      return current;
    }
    if (adopted.isEmpty) return current;

    final byId = {for (final u in current) u.id: u};
    var added = 0;
    for (final u in adopted) {
      if (byId.containsKey(u.id)) continue;
      byId[u.id] = u;
      added++;
    }
    if (added == 0) return current;
    _log?.addMessage(
      core.Origin.azure,
      'Azure: $added bestaand(e) account(s) overgenomen die via employeeId '
      'gevonden zijn maar niet aan de schoolfilter voldoen (overgestapte '
      'leerlingen).',
    );
    return byId.values.toList();
  }

  /// How old the token Graph just rejected was, for the log line — the
  /// diagnostic that separates "Graph expired a genuinely old token" from "the
  /// app kept re-sending a token that had stopped advancing" (#213).
  ///
  /// Reads [AzureSnapshot.fetchedAt] of the snapshot the token came with, which
  /// dates the token itself thanks to the token invariant on [sync].
  static String _tokenAge(AzureSnapshot? previous) {
    final at = previous?.fetchedAt;
    if (at == null) return 'ouderdom onbekend — geen vorige snapshot';
    final age = _now().difference(at);
    return 'bewaard ${_formatAge(age)} geleden, op ${at.toIso8601String()}';
  }

  static String _formatAge(Duration age) {
    if (age.isNegative) return 'minder dan een minuut';
    if (age.inDays > 0) return '${age.inDays}d ${age.inHours % 24}u';
    if (age.inHours > 0) return '${age.inHours}u ${age.inMinutes % 60}m';
    return '${age.inMinutes}m';
  }

  /// Upserts [delta.changed] and drops [delta.removedIds] over [base], keeping
  /// the result keyed by Azure object id.
  static List<AzureUser> _applyDelta(List<AzureUser> base, UserDelta delta) {
    final byId = {for (final u in base) u.id: u};
    for (final id in delta.removedIds) {
      byId.remove(id);
    }
    for (final u in delta.changed) {
      byId[u.id] = u;
    }
    return byId.values.toList();
  }

  /// Releases the HTTP transport when the connector created it. A transport
  /// the caller injected is the caller's to close.
  void close() {
    final transport = _transport;
    if (_ownsTransport && transport is HttpGraphTransport) {
      transport.close();
    }
  }

  static DateTime _now() => DateTime.now();
}
