import 'package:account_core/account_core.dart';

/// The Office 365 class-group context for one linked class — everything the
/// group actions need to create `<PREFIX>-<KLAS>` and keep its membership equal
/// to the class roster, and which a [LinkedGroup] alone cannot answer (#228).
///
/// The analogue of [GroupPlacement] for the Azure side, and injected the same
/// way: the State layer builds one per linked class from the WISA + Azure
/// snapshots and the linked accounts, and the actions only ever *read* it. That
/// keeps `account_actions` a pure function of its inputs — no snapshot walking
/// inside an action.
///
/// Three things live here that a linked record cannot express:
///
/// - **The bare class name.** [LinkedGroup.wisa] is keyed and named by the WISA
///   `fullName`, so the sub-grouped class `2F ECO` says nothing about the group
///   `GBS-2F` its students belong to. [className] is the parent class.
/// - **Ownership.** Four linked groups (`2F ECO`, `2F MAW`, `2F MOW`,
///   `2F STEMW`) map to the **one** group `GBS-2F`, so exactly one of them must
///   raise the create/membership actions or the operator sees four proposals
///   for one write. The builder — which sees every class — nominates that
///   record and marks it [owner]; every other record of the same class carries
///   `owner: false` and raises nothing. When the parent class has a linked group
///   of its own it is the owner; otherwise the first sub-group record is (the
///   parent's `00` row is deduped away for a sub-grouped class, see #221), which
///   is why the proposals name the class explicitly.
/// - **The roster diff.** Membership is the union of the sub-groups' rosters,
///   expressed as Azure object ids; deriving it needs the linked accounts, not
///   this one record.
class AzureClassGroupPlan {
  const AzureClassGroupPlan({
    required this.className,
    required this.displayName,
    required this.mailNickname,
    required this.mail,
    required this.owner,
    required this.containsStudents,
    this.membersToAdd = const [],
    this.membersToRemove = const [],
  });

  /// The **bare** class name the group is named after — `2F`, never `2F ECO`.
  final String className;

  /// The group's display name, `<PREFIX>-<KLAS>`.
  final String displayName;

  /// The group's mail alias. Equal to [displayName]: bare class names carry no
  /// spaces, so no slug rule is needed (a name that would *not* survive as a
  /// nickname yields no plan at all — see [isValidMailNickname]).
  final String mailNickname;

  /// The address the group answers on, `<PREFIX>-<KLAS>@<studentdomein>`.
  final String mail;

  /// Whether this linked record is the one that raises this class's Office 365
  /// actions. Exactly one record per distinct [className] carries `true`.
  final bool owner;

  /// Whether the class currently holds students of a school we manage — the
  /// same signal [GroupPlacement.containsStudents] carries for Smartschool,
  /// tallied over the **bare** class name so a sub-grouped class counts all its
  /// sub-groups' students. An empty class gets no group, mirroring how an empty
  /// WISA class is not created in Smartschool either.
  final bool containsStudents;

  /// Azure object ids on the class roster that the existing group does not have
  /// as members yet. Empty when the group does not exist (nothing to diff
  /// against) or when membership already matches.
  final List<String> membersToAdd;

  /// Azure object ids to remove: **every current member the class roster does
  /// not name** (#389). A class group holds the students of that class, so
  /// anything else in it is a stray — the class-to-class mover, the student who
  /// has left the schools we manage, the sibling group school's pupil who was
  /// never ours at all, and the account carrying no school stamp to judge it by.
  ///
  /// This is plainly `current - roster`, and it deliberately replaced a narrow
  /// rule that named only accounts the app could account for as its own
  /// students, present or past (#385). That rule could only ever hold ids of
  /// accounts *in the Azure snapshot*, which is `$filter`-scoped to our own
  /// prefix (#224) — so a sibling school's pupil sitting in one of our class
  /// groups was never read, never linked, and could not be named however the
  /// predicate was written. A live audit found them in nearly every class group.
  ///
  /// The narrow rule's purpose was to keep teachers and titulars out of the net
  /// when [SyncAzureClassGroupMembers] is applied to all. That is now carried by
  /// **group identification** instead: these groups hold students only by
  /// policy, a teacher who needs access is made an *owner* (which Graph keeps in
  /// a different collection from members, and which this app never reads), and a
  /// plan is only ever built for a group whose `<PREFIX>-<KLAS>` name matches a
  /// real WISA class — so the subject groups that genuinely do hold teachers are
  /// out of reach.
  final List<String> membersToRemove;

  /// Whether membership differs from the roster in either direction.
  bool get membershipDiffers =>
      membersToAdd.isNotEmpty || membersToRemove.isNotEmpty;
}
