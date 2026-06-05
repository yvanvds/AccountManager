import 'dart:collection';

import 'package:account_core/account_core.dart' as core;

/// An Azure AD group, as read from Microsoft Graph.
///
/// Implements [core.AzureGroup] (`id`, `displayName`) so the linker can refer
/// to it without depending on this package (`docs/domain-model.md` §4).
///
/// Members are stored as Azure object-id strings — the only thing the linker
/// and membership writes need. The legacy `Group.cs` wrapped full
/// `DirectoryObject`s; the port keeps just the ids.
///
/// Immutable. Legacy reference (read-only):
/// `legacy-wpf/AccountApi/Azure/Group.cs`.
class AzureGroup implements core.AzureGroup {
  @override
  final String id;

  @override
  final String displayName;

  /// Whether this is a security group (vs. a Microsoft 365 group). Mirrors the
  /// legacy `SecurityEnabled` flag used by `FindGroupByName`.
  final bool securityEnabled;

  /// Azure object ids of the group's members.
  final UnmodifiableListView<String> memberIds;

  AzureGroup({
    required this.id,
    required this.displayName,
    this.securityEnabled = false,
    List<String> memberIds = const [],
  }) : memberIds = UnmodifiableListView(List.of(memberIds));

  /// Fields the connector requests from Graph (`$select`) when listing groups.
  static const List<String> graphSelectFields = [
    'id',
    'displayName',
    'securityEnabled',
  ];

  /// Whether [userId] is a member, by Azure object id.
  bool hasMember(String userId) => memberIds.contains(userId);

  /// Parses a Graph `group` resource. Members are not part of the group
  /// resource; [members] is supplied separately (from `/groups/{id}/members`).
  factory AzureGroup.fromGraphJson(
    Map<String, dynamic> json, {
    List<String> members = const [],
  }) =>
      AzureGroup(
        id: (json['id'] as String?) ?? '',
        displayName: (json['displayName'] as String?) ?? '',
        securityEnabled: (json['securityEnabled'] as bool?) ?? false,
        memberIds: members,
      );

  /// Returns a copy with [memberIds] replaced. Used to apply membership writes
  /// locally after a successful Graph call.
  AzureGroup withMembers(List<String> members) => AzureGroup(
        id: id,
        displayName: displayName,
        securityEnabled: securityEnabled,
        memberIds: members,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'securityEnabled': securityEnabled,
        'memberIds': memberIds.toList(),
      };

  factory AzureGroup.fromJson(Map<String, dynamic> json) => AzureGroup(
        id: json['id'] as String,
        displayName: (json['displayName'] as String?) ?? '',
        securityEnabled: (json['securityEnabled'] as bool?) ?? false,
        memberIds:
            ((json['memberIds'] as List<dynamic>?) ?? const []).cast<String>(),
      );

  @override
  bool operator ==(Object other) =>
      other is AzureGroup &&
      other.id == id &&
      other.displayName == displayName &&
      other.securityEnabled == securityEnabled &&
      _listEquals(other.memberIds, memberIds);

  @override
  int get hashCode => Object.hash(
        id,
        displayName,
        securityEnabled,
        Object.hashAll(memberIds),
      );

  @override
  String toString() =>
      'AzureGroup($displayName, id: $id, members: ${memberIds.length})';
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
