import 'package:account_core/account_core.dart' as core;

import 'auth/auth_provider.dart';
import 'auth/credentials.dart';
import 'graph/graph_client.dart';
import 'graph/graph_transport.dart';
import 'group_manager.dart';
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
  })  : _transport = transport,
        _ownsTransport = ownsTransport;

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
    );
  }

  /// Reads the school's users and groups into a fresh [AzureSnapshot].
  ///
  /// - [deltaToken] `null` → first/full sync: `$filter`+`$select` bulk read
  ///   ([UserManager.load]) plus a primed delta token for next time.
  /// - [deltaToken] set → incremental: applies `/users/delta` changes and
  ///   removals on top of [previous] (required for a complete user list; when
  ///   omitted, only the changed users are returned).
  Future<AzureSnapshot> sync({
    String? deltaToken,
    AzureSnapshot? previous,
  }) async {
    final groupList = await groups.listGroups(credentials.schoolPrefix);

    if (deltaToken == null) {
      final token = await users.latestDeltaToken();
      final userList = await users.load(credentials.schoolPrefix);
      return AzureSnapshot(
        fetchedAt: _now(),
        deltaToken: token,
        users: userList,
        groups: groupList,
      );
    }

    final delta = await users.delta(deltaToken, credentials.schoolPrefix);
    final userList = _applyDelta(previous?.users ?? const [], delta);
    return AzureSnapshot(
      fetchedAt: _now(),
      deltaToken: delta.deltaToken ?? deltaToken,
      users: userList,
      groups: groupList,
    );
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
