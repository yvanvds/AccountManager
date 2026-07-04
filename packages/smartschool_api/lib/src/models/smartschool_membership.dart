import 'package:account_core/account_core.dart' as core;

/// A connector-native membership: one account's presence in one group.
///
/// Keyed by the Smartschool [uid] rather than a [core.PersonId], because the
/// connector runs before linking — `PersonId`s are minted by the linker. The
/// linker maps `uid → PersonId` and projects these to [core.Membership].
/// This mirrors how `WisaSnapshot` stays in WISA-native keys (`wisaId`,
/// class-name strings) until link time.
///
/// **Multi-membership (PAIN-1):** the legacy connector dedupes an account
/// that appears in several subtrees ("skip if already seen"). The port does
/// the opposite — it emits one [SmartschoolMembership] per (account, group)
/// pair, so the same account in two subtrees yields two membership rows.
/// Spec: `docs/domain-model.md` §3.7, INV-30.
class SmartschoolMembership {
  /// The member account's Smartschool username.
  final String uid;

  /// The group the account belongs to (its [core.GroupId] / Smartschool
  /// code).
  final core.GroupId groupId;

  /// `student` for a primary membership; `coAccount1..6` for a co-account.
  /// Always `student` for now — co-accounts are not given their own group
  /// memberships by the read path.
  final core.AccountType accountType;

  const SmartschoolMembership({
    required this.uid,
    required this.groupId,
    this.accountType = core.AccountType.student,
  });

  /// Serializes to the connector's own snapshot shape. Round-trips with
  /// [SmartschoolMembership.fromJson] for the persisted cold snapshot (#107).
  Map<String, dynamic> toJson() => {
        'uid': uid,
        'groupId': groupId.toJson(),
        'accountType': accountType.toJson(),
      };

  factory SmartschoolMembership.fromJson(Map<String, dynamic> json) =>
      SmartschoolMembership(
        uid: json['uid'] as String,
        groupId: core.GroupId(json['groupId'] as String),
        accountType: core.AccountType.fromJson(json['accountType'] as String),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SmartschoolMembership &&
          uid == other.uid &&
          groupId == other.groupId &&
          accountType == other.accountType;

  @override
  int get hashCode => Object.hash(uid, groupId, accountType);

  @override
  String toString() =>
      'SmartschoolMembership($uid in ${groupId.value}, $accountType)';
}
