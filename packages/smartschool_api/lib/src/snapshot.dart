import 'dart:collection';

import 'package:account_core/account_core.dart' as core;

import 'models/smartschool_account.dart';
import 'models/smartschool_membership.dart';

/// Immutable result of one Smartschool sync.
///
/// Spec: `docs/domain-model.md` §3.8. All exposed lists are
/// [UnmodifiableListView]s — handing the snapshot to the linker is safe.
///
/// - [groups] is the flattened group tree as [core.Group] records (edges via
///   `parentId`), with import rules already applied.
/// - [accounts] holds one record per distinct Smartschool `uid`; disabled
///   (`uitgeschakeld`) accounts are filtered out, co-account slots preserved.
/// - [memberships] carries one row per (account, group) pair — multi-
///   membership is preserved, not deduplicated (PAIN-1, INV-30).
class SmartschoolSnapshot implements core.Snapshot {
  @override
  final DateTime fetchedAt;

  @override
  core.Origin get origin => core.Origin.smartschool;

  final UnmodifiableListView<core.Group> groups;
  final UnmodifiableListView<SmartschoolAccount> accounts;
  final UnmodifiableListView<SmartschoolMembership> memberships;

  SmartschoolSnapshot({
    required this.fetchedAt,
    required List<core.Group> groups,
    required List<SmartschoolAccount> accounts,
    required List<SmartschoolMembership> memberships,
  })  : groups = UnmodifiableListView(List.of(groups)),
        accounts = UnmodifiableListView(List.of(accounts)),
        memberships = UnmodifiableListView(List.of(memberships));

  /// Serializes the whole snapshot to a JSON-encodable map. Round-trips with
  /// [SmartschoolSnapshot.fromJson] — the payload form the cold `snapshots`
  /// store persists so a passive session trusts the stored Smartschool state
  /// instead of re-pulling it (#107).
  Map<String, dynamic> toJson() => {
        'fetchedAt': fetchedAt.toIso8601String(),
        'groups': [for (final g in groups) g.toJson()],
        'accounts': [for (final a in accounts) a.toJson()],
        'memberships': [for (final m in memberships) m.toJson()],
      };

  factory SmartschoolSnapshot.fromJson(Map<String, dynamic> json) =>
      SmartschoolSnapshot(
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
        groups: [
          for (final e in (json['groups'] as List<dynamic>? ?? const []))
            core.Group.fromJson(e as Map<String, dynamic>),
        ],
        accounts: [
          for (final e in (json['accounts'] as List<dynamic>? ?? const []))
            SmartschoolAccount.fromJson(e as Map<String, dynamic>),
        ],
        memberships: [
          for (final e in (json['memberships'] as List<dynamic>? ?? const []))
            SmartschoolMembership.fromJson(e as Map<String, dynamic>),
        ],
      );
}
