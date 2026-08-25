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

  /// Every `employeeId` this pull returned on **more than one** account, mapped
  /// to those accounts in snapshot order (INV-26, #360).
  ///
  /// `employeeId` carries the WISA id and every join downstream treats it as the
  /// one strong bridge to a person — yet it is not unique in this tenant, so a
  /// map keyed by it silently keeps one row and loses the rest. This is the one
  /// place that answers the question before anything has keyed by it:
  /// [UserManager.loadByEmployeeIds] already returns every match (it
  /// de-duplicates by object id, not by employeeId), so the collision is
  /// observable on the pull and only vanishes further down.
  ///
  /// Keys are normalized per INV-12 (trimmed, lower-cased) so they compare
  /// equal to the linker's own; blank and absent ids are skipped, since "no id"
  /// is not an identity two accounts can share. Ids appear in first-seen order,
  /// so the result is a deterministic function of [users]' order (INV-20).
  /// Empty — the normal case — means every id answers with at most one account.
  Map<String, List<AzureUser>> get duplicateEmployeeIds {
    final byId = <String, List<AzureUser>>{};
    for (final user in users) {
      final key = user.employeeId?.trim().toLowerCase();
      if (key == null || key.isEmpty) continue;
      (byId[key] ??= <AzureUser>[]).add(user);
    }
    byId.removeWhere((_, accounts) => accounts.length < 2);
    return Map<String, List<AzureUser>>.unmodifiable(byId);
  }

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
