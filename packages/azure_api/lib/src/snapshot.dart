import 'dart:collection';

import 'package:account_core/account_core.dart' as core;

import 'models/azure_group.dart';
import 'models/azure_user.dart';

/// Immutable result of one Azure sync.
///
/// Spec: `docs/domain-model.md` §3.8. All exposed lists are
/// [UnmodifiableListView]s — handing the snapshot to the linker is safe.
///
/// - [users] holds the school's users, read with Graph `$filter` + `$select`
///   (or the changed set from `/users/delta`), never the whole tenant.
/// - [groups] holds the prefixed groups with their member ids.
/// - [deltaToken] is the opaque `$deltatoken` from the latest
///   `/users/delta` page. Pass it back to [AzureConnector.sync] for an
///   incremental next sync. `null` after a full read that produced no token.
class AzureSnapshot implements core.Snapshot {
  @override
  final DateTime fetchedAt;

  @override
  core.Origin get origin => core.Origin.azure;

  /// Opaque delta token for the next incremental `/users/delta` sync.
  final String? deltaToken;

  final UnmodifiableListView<AzureUser> users;
  final UnmodifiableListView<AzureGroup> groups;

  AzureSnapshot({
    required this.fetchedAt,
    this.deltaToken,
    required List<AzureUser> users,
    required List<AzureGroup> groups,
  })  : users = UnmodifiableListView(List.of(users)),
        groups = UnmodifiableListView(List.of(groups));

  Map<String, dynamic> toJson() => {
        'fetchedAt': fetchedAt.toIso8601String(),
        if (deltaToken != null) 'deltaToken': deltaToken,
        'users': users.map((u) => u.toJson()).toList(),
        'groups': groups.map((g) => g.toJson()).toList(),
      };

  factory AzureSnapshot.fromJson(Map<String, dynamic> json) => AzureSnapshot(
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
        deltaToken: json['deltaToken'] as String?,
        users: ((json['users'] as List<dynamic>?) ?? const [])
            .map((e) => AzureUser.fromJson(e as Map<String, dynamic>))
            .toList(),
        groups: ((json['groups'] as List<dynamic>?) ?? const [])
            .map((e) => AzureGroup.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
