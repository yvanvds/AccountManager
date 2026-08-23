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

  /// Whether the group has a mailbox or mail address of its own. One half of
  /// the pair that tells the four group shapes apart (#331) — see [isUnified].
  ///
  /// **Not the same question as `mail != null`**, which is why it is read from
  /// Graph rather than inferred: an Exchange-mastered group answers on an
  /// address *and* is a security group, a combination the address alone cannot
  /// express.
  final bool mailEnabled;

  /// Graph's `groupTypes`, the **only** reliable signal that a group is a
  /// Microsoft 365 ("unified") one: it holds `Unified` for those and is empty
  /// for every other shape (#331).
  final UnmodifiableListView<String> groupTypes;

  /// The group's SMTP address, e.g. `GBS-2A@student.school.example`. Any
  /// [mailEnabled] group carries one — a Microsoft 365 group, a distribution
  /// list, or a mail-enabled security group; `null` for a plain security group
  /// such as the legacy staff groups (#228). It is therefore *not* a signal of
  /// which shape the group is, which is what #331 had to fix: read
  /// [isUnified] / [canManageMembership] for that.
  @override
  final String? mail;

  /// The group's mail alias — the local part of [mail]. Carried beside
  /// [displayName] so a class group can be told apart from a same-named group
  /// answering on a different address (#228).
  @override
  final String? mailNickname;

  /// Azure object ids of the group's members.
  final UnmodifiableListView<String> memberIds;

  AzureGroup({
    required this.id,
    required this.displayName,
    this.securityEnabled = false,
    this.mailEnabled = false,
    List<String> groupTypes = const [],
    this.mail,
    this.mailNickname,
    List<String> memberIds = const [],
  })  : groupTypes = UnmodifiableListView(List.of(groupTypes)),
        memberIds = UnmodifiableListView(List.of(memberIds));

  /// Fields the connector requests from Graph (`$select`) when listing groups.
  static const List<String> graphSelectFields = [
    'id',
    'displayName',
    'securityEnabled',
    'mailEnabled',
    'groupTypes',
    'mail',
    'mailNickname',
  ];

  /// Whether this group is a Microsoft 365 ("unified") group — the shape a
  /// class group must have to be mailed and attached to a Team (#228).
  ///
  /// **`groupTypes` is the whole answer** (#331). Until then this was inferred
  /// as `!securityEnabled && mail != ''`, which cannot tell a Microsoft 365
  /// group from a plain distribution list (neither is security-enabled, both
  /// carry an address), and cannot see a mail-enabled security group at all —
  /// the group shape that caused the bug, since it *is* security-enabled and so
  /// read as "not unified, therefore an ordinary security group we manage".
  bool get isUnified => groupTypes.contains('Unified');

  /// Whether this group is mastered by **Exchange Online** rather than by the
  /// directory (#331) — a mail-enabled security group or a distribution list.
  ///
  /// Graph refuses directory writes on those: their membership and their
  /// lifecycle are Exchange's, not Entra's, so an add, a remove or a delete
  /// comes back refused however often it is retried. The port's own class
  /// groups are never this shape ([GroupManager.createGroup] always writes
  /// `groupTypes: ["Unified"]`), but a hand-made group inside the school's
  /// `<PREFIX>-` namespace can be — `SSM-1A` in the live tenant is exactly one,
  /// and the app proposed a membership sync on it every pass.
  ///
  /// The two remaining shapes are ours to manage: a Microsoft 365 group
  /// ([isUnified]) and a plain, non-mail-enabled security group — the shape the
  /// legacy WPF app created its class groups as.
  bool get isExchangeManaged => mailEnabled && !isUnified;

  /// Whether Graph will manage this group's membership (#331). The inverse of
  /// [isExchangeManaged], named for the question the actions actually ask.
  bool get canManageMembership => !isExchangeManaged;

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
        mailEnabled: (json['mailEnabled'] as bool?) ?? false,
        groupTypes: _stringList(json['groupTypes']),
        mail: json['mail'] as String?,
        mailNickname: json['mailNickname'] as String?,
        memberIds: members,
      );

  /// Returns a copy with [memberIds] replaced. Used to apply membership writes
  /// locally after a successful Graph call.
  AzureGroup withMembers(List<String> members) => AzureGroup(
        id: id,
        displayName: displayName,
        securityEnabled: securityEnabled,
        mailEnabled: mailEnabled,
        groupTypes: groupTypes,
        mail: mail,
        mailNickname: mailNickname,
        memberIds: members,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'securityEnabled': securityEnabled,
        'mailEnabled': mailEnabled,
        'groupTypes': groupTypes.toList(),
        if (mail != null) 'mail': mail,
        if (mailNickname != null) 'mailNickname': mailNickname,
        'memberIds': memberIds.toList(),
      };

  /// Reads a stored group back. A snapshot written before #331 carries neither
  /// `mailEnabled` nor `groupTypes`, and both default to the shape the app
  /// manages — the conservative direction: an old snapshot behaves exactly as it
  /// did rather than silently withholding every class group's membership sync
  /// until the next Azure pull refreshes it.
  factory AzureGroup.fromJson(Map<String, dynamic> json) => AzureGroup(
        id: json['id'] as String,
        displayName: (json['displayName'] as String?) ?? '',
        securityEnabled: (json['securityEnabled'] as bool?) ?? false,
        mailEnabled: (json['mailEnabled'] as bool?) ?? false,
        groupTypes: _stringList(json['groupTypes']),
        mail: json['mail'] as String?,
        mailNickname: json['mailNickname'] as String?,
        memberIds:
            ((json['memberIds'] as List<dynamic>?) ?? const []).cast<String>(),
      );

  static List<String> _stringList(Object? value) =>
      ((value as List<dynamic>?) ?? const <dynamic>[]).cast<String>();

  @override
  bool operator ==(Object other) =>
      other is AzureGroup &&
      other.id == id &&
      other.displayName == displayName &&
      other.securityEnabled == securityEnabled &&
      other.mailEnabled == mailEnabled &&
      _listEquals(other.groupTypes, groupTypes) &&
      other.mail == mail &&
      other.mailNickname == mailNickname &&
      _listEquals(other.memberIds, memberIds);

  @override
  int get hashCode => Object.hash(
        id,
        displayName,
        securityEnabled,
        mailEnabled,
        Object.hashAll(groupTypes),
        mail,
        mailNickname,
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
