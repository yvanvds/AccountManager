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
  ///
  /// **Token invariant:** the token on the returned snapshot is always one
  /// minted during *this* sync — from this pass's delta walk, or from
  /// [UserManager.latestDeltaToken] on a full read — never a carried-over older
  /// one. That is what makes [AzureSnapshot.fetchedAt] a truthful age for the
  /// token it ships with, and what keeps a token from silently ageing past
  /// Graph's 30-day limit while every sync appears to succeed.
  Future<AzureSnapshot> sync({
    String? deltaToken,
    AzureSnapshot? previous,
  }) async {
    final groupList = await groups.listGroups(credentials.schoolPrefix);

    if (deltaToken == null) return _fullRead(groupList);

    final UserDelta delta;
    try {
      delta = await users.delta(deltaToken, credentials.schoolPrefix);
    } on GraphException catch (e) {
      if (!_isRejectedDeltaToken(e)) rethrow;
      _log?.addMessage(
        core.Origin.azure,
        'Azure: Graph rejected the stored delta token '
        '(${_tokenAge(previous)}) — $e. Discarding it and re-reading all '
        'accounts in full.',
      );
      return _fullRead(groupList);
    }

    // No `@odata.deltaLink` on the final page means this walk produced no
    // resume point. Keeping the old token here (the pre-#213 behaviour) let a
    // token stop advancing while every sync still reported success, until it
    // aged past Graph's 30-day limit and every later pass died on it. Dropping
    // it costs one full read next pass and always leaves a fresh token behind.
    if (delta.deltaToken == null) {
      _log?.addMessage(
        core.Origin.azure,
        'Azure: the delta response carried no deltaLink, so this sync leaves '
        'no resume token — the next sync re-reads all accounts in full.',
      );
    }

    final userList = _applyDelta(previous?.users ?? const [], delta);
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
  Future<AzureSnapshot> _fullRead(List<AzureGroup> groupList) async {
    final token = await users.latestDeltaToken();
    final userList = await users.load(credentials.schoolPrefix);
    return AzureSnapshot(
      fetchedAt: _now(),
      deltaToken: token,
      users: userList,
      groups: groupList,
    );
  }

  /// Whether [e] means "this delta token is no longer usable", the one Graph
  /// failure [sync] recovers from by re-reading in full (#213).
  ///
  /// Two shapes, both of them Graph's own:
  /// - `410 Gone` — the documented `resyncRequired` / `syncStateNotFound`
  ///   "start over" signal for a delta query.
  /// - `400 Bad Request` with `Request_UnsupportedQuery` **and** a message
  ///   naming the delta link, e.g. *"DeltaLink older than 30 days is not
  ///   supported."* The code alone is deliberately not enough: Graph also
  ///   returns it for a genuinely malformed query, which must stay loud rather
  ///   than silently degrade into an expensive full read on every pass.
  static bool _isRejectedDeltaToken(GraphException e) {
    if (e.statusCode == 410) return true;
    if (e.statusCode != 400) return false;
    if (e.code?.toLowerCase() != 'request_unsupportedquery') return false;
    final detail = (e.message ?? e.body).toLowerCase();
    return detail.contains('deltalink') ||
        detail.contains('delta link') ||
        detail.contains('deltatoken') ||
        detail.contains('delta token');
  }

  /// How old the token Graph just rejected was, for the log line — the
  /// diagnostic that separates "Graph expired a genuinely old token" from "the
  /// app kept re-sending a token that had stopped advancing" (#213).
  ///
  /// Reads [AzureSnapshot.fetchedAt] of the snapshot the token came with, which
  /// dates the token itself thanks to the token invariant on [sync].
  static String _tokenAge(AzureSnapshot? previous) {
    final at = previous?.fetchedAt;
    if (at == null) return 'age unknown — no previous snapshot';
    final age = _now().difference(at);
    return 'stored ${_formatAge(age)} ago, at ${at.toIso8601String()}';
  }

  static String _formatAge(Duration age) {
    if (age.isNegative) return 'less than a minute';
    if (age.inDays > 0) return '${age.inDays}d ${age.inHours % 24}h';
    if (age.inHours > 0) return '${age.inHours}h ${age.inMinutes % 60}m';
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
