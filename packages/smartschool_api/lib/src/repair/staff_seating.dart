/// The staff-seating backlog #374 left behind (#378).
///
/// Smartschool's `saveUser` seats **every** account it creates in the platform
/// default group ([smartschoolDefaultGroupName]), whatever role the account
/// carries. Legacy compensated inside the staff create with two follow-up
/// writes; the port dropped both, so every staff account it made before #374
/// sat in the student subtree and in no staff group at all.
///
/// #374 is forward-only: it seats the accounts it creates from now on. This
/// library is the other half — it *finds* the accounts already mis-seated and
/// applies the same two writes to them.
///
/// Two functions, deliberately split:
///
///  - [misSeatedStaffAccounts] is pure. It answers "how many, and which?" from
///    a snapshot alone, which is the question #378 says must be answered
///    **first**, because the count decides whether the repair is worth being
///    self-service at all.
///  - [repairStaffSeating] performs the writes, and is the only part that
///    touches the tenant.
///
/// Neither is wired into the app. The repair is a **one-off**: after #374 the
/// mis-seating cannot recur through the app, so a standing action would have to
/// carry Smartschool group membership on `LinkedStaff` — the membership-aware
/// follow-up `AddToStaffGroup` / `AddToAzureStaffGroup` are also waiting on —
/// to keep proposing a repair nothing can produce any more. The entry point is
/// `tool/staff_seat_repair.dart`, run by hand: the repair writes to Smartschool,
/// and the project's live-testing policy keeps write-capable runs manual.
library;

import 'package:account_core/account_core.dart' as core;

import '../connector.dart';
import '../models/smartschool_account.dart';
import '../snapshot.dart';

/// The name of the Smartschool group a staff account belongs in (#374).
///
/// Stated **once**, here, and aliased by `account_actions`' `StaffPlacement`:
/// the create and this repair must agree about where a staff account goes, and
/// two literals in two packages is exactly how they would stop agreeing. It
/// lives in the connector package because it names a node of the *Smartschool*
/// tree, which is what this package models — the action engine consumes it, it
/// does not own it.
///
/// A tenant that renames the group changes this constant (or passes another
/// name to [misSeatedStaffAccounts] / [repairStaffSeating]); it is deliberately
/// not a fourth configurable name beside `AppSettings.smartschoolRoots` and the
/// Passwords screen's own — see `StaffPlacement` for that argument in full.
const String smartschoolStaffGroupName = 'Leerkrachten';

/// The name of the group Smartschool seats **every** `saveUser` account in,
/// whatever role the account carries (#374).
///
/// Platform behaviour, not a choice of ours: the create cannot opt out of it,
/// so a staff create has to compensate afterwards by leaving the group again —
/// and every staff account created before #374 never did.
const String smartschoolDefaultGroupName = 'Leerlingen';

/// The name of the root the staff population lives under (#378).
///
/// Used by [misSeatedStaffAccounts] as the "is this account seated *somewhere*
/// staff-side?" test, so a staff member sitting in `Directie` or `Secretariaat`
/// rather than [smartschoolStaffGroupName] is not mistaken for a mis-seated
/// one. It is the same root `AppSettings.smartschoolRoots` scopes the pull to,
/// spelled the way this school's tree spells it; a tenant whose tree names it
/// otherwise passes its own `staffRootName`.
const String smartschoolStaffRootName = 'Personeel';

/// One staff account the pre-#374 create left in the platform default group.
class MisSeatedStaffAccount {
  const MisSeatedStaffAccount({
    required this.account,
    required this.defaultGroup,
    required this.otherGroups,
  });

  /// The mis-seated account itself.
  final SmartschoolAccount account;

  /// The default-group node it is sitting in — the membership row the repair's
  /// removal takes away.
  final core.Group defaultGroup;

  /// Every other group it belongs to, in snapshot order.
  ///
  /// None of them is under the staff root (that is what makes the account
  /// mis-seated), but they are not nothing: an account that also sits in
  /// `Stagiairs` or `Beheerders` was put there by an operator, not by our
  /// create, and an operator eyeballing the audit before applying it needs to
  /// see that. Groups the snapshot carries no node for are omitted.
  final List<core.Group> otherGroups;

  @override
  String toString() => 'MisSeatedStaffAccount(${account.uid} '
      'in ${defaultGroup.name})';
}

/// The staff accounts of [snapshot] that are seated in the platform default
/// group and in no staff group at all (#378) — the backlog #374 left behind.
///
/// An account qualifies when all three hold:
///
///  1. its `Basisrol` maps to a **staff** role — anything but
///     [core.PersonRole.student]. An unmapped role (`null`) does not qualify:
///     we cannot claim an account is staff when Smartschool did not say so, and
///     a false positive here would add a student to the staff group.
///  2. it holds a membership in a group named [defaultGroupName]. This is the
///     bug's exact footprint: `saveUser` seats into that node itself, never
///     into a class below it, and it is also the row the repair's removal
///     addresses — so an account without it has nothing to repair.
///  3. it holds **no** membership anywhere in the subtree rooted at
///     [staffRootName]. This is the conservative half of the test: a staff
///     member who is in the default group *and* in `Directie` was seated by
///     someone on purpose, and undoing that is not this repair's business.
///
/// Both names are matched with [core.normalizeGroupName], the key the rest of
/// the port joins group names on (#241/#225), and **every** node carrying the
/// name counts — a namesake deeper in the tree seats an account just as
/// literally as the root one does, and the removal is addressed by name anyway.
///
/// Returned in snapshot account order, so a re-run of the audit lists the same
/// accounts in the same order.
List<MisSeatedStaffAccount> misSeatedStaffAccounts(
  SmartschoolSnapshot snapshot, {
  String defaultGroupName = smartschoolDefaultGroupName,
  String staffRootName = smartschoolStaffRootName,
}) {
  final defaultKey = core.normalizeGroupName(defaultGroupName);
  if (defaultKey == null) return const [];

  // Index by code, skipping the code-less nodes the tree carries: a group with
  // no code is never addressed by a membership row, and mapping them all to the
  // one empty key would resolve any such row to an arbitrary group.
  final byCode = <String, core.Group>{};
  for (final group in snapshot.groups) {
    final code = group.id.value;
    if (code.isNotEmpty) byCode.putIfAbsent(code, () => group);
  }

  final defaultCodes = <String>{
    for (final group in snapshot.groups)
      if (group.id.value.isNotEmpty &&
          core.normalizeGroupName(group.name) == defaultKey)
        group.id.value,
  };
  if (defaultCodes.isEmpty) return const [];

  final staffCodes = _subtreeCodes(snapshot.groups, staffRootName);

  final membershipsByUid = <String, List<String>>{};
  for (final membership in snapshot.memberships) {
    final uid = _norm(membership.uid);
    if (uid == null) continue;
    (membershipsByUid[uid] ??= <String>[]).add(membership.groupId.value);
  }

  final result = <MisSeatedStaffAccount>[];
  for (final account in snapshot.accounts) {
    final role = account.role;
    if (role == null || role == core.PersonRole.student) continue;

    final uid = _norm(account.uid);
    if (uid == null) continue;
    final codes = membershipsByUid[uid];
    if (codes == null) continue;

    core.Group? seat;
    final others = <core.Group>[];
    var staffSide = false;
    for (final code in codes) {
      if (staffCodes.contains(code)) staffSide = true;
      if (defaultCodes.contains(code)) {
        seat ??= byCode[code];
        continue;
      }
      final group = byCode[code];
      if (group != null) others.add(group);
    }
    if (staffSide || seat == null) continue;

    result.add(
      MisSeatedStaffAccount(
        account: account,
        defaultGroup: seat,
        otherGroups: List.unmodifiable(others),
      ),
    );
  }
  return List.unmodifiable(result);
}

/// The codes of every group in the subtree(s) rooted at a group named
/// [rootName], the roots themselves included.
///
/// Walks [core.Group.parentId] rather than a nested structure because a
/// snapshot's tree is flattened. Code-less nodes still propagate their
/// children's membership: a group whose parent is code-less simply cannot be
/// reached from the root, which is a limit of the flattened form, not of this
/// walk — such a node has no membership rows to hide either way.
Set<String> _subtreeCodes(List<core.Group> groups, String rootName) {
  final key = core.normalizeGroupName(rootName);
  if (key == null) return const {};

  final inside = <String>{
    for (final group in groups)
      if (group.id.value.isNotEmpty &&
          core.normalizeGroupName(group.name) == key)
        group.id.value,
  };
  if (inside.isEmpty) return const {};

  // The flattened tree is in no guaranteed parent-before-child order, so keep
  // sweeping until a pass adds nothing.
  var grew = true;
  while (grew) {
    grew = false;
    for (final group in groups) {
      final code = group.id.value;
      final parent = group.parentId?.value;
      if (code.isEmpty || parent == null || parent.isEmpty) continue;
      if (inside.contains(parent) && inside.add(code)) grew = true;
    }
  }
  return inside;
}

/// The [smartschoolStaffGroupName] node the repair adds accounts to, resolved
/// against [snapshot] (#378).
///
/// First node carrying the name, in snapshot order — the same resolution
/// `PlacementResolver.staffPlacement` gives the create, so the repair seats a
/// backlog account in the group a fresh create would have seated it in.
/// `null` when the tree carries no such node, which [repairStaffSeating] turns
/// into a per-account problem rather than a crash.
core.Group? resolveStaffGroup(
  SmartschoolSnapshot snapshot, {
  String name = smartschoolStaffGroupName,
}) {
  final key = core.normalizeGroupName(name);
  if (key == null) return null;
  for (final group in snapshot.groups) {
    if (core.normalizeGroupName(group.name) == key) return group;
  }
  return null;
}

/// What one account's repair ended up doing (#378).
class StaffSeatRepair {
  const StaffSeatRepair({
    required this.uid,
    required this.joined,
    required this.left,
    this.problems = const <String>[],
  });

  /// The repaired account's Smartschool uid.
  final String uid;

  /// Whether the account was added to the staff group.
  final bool joined;

  /// Whether the account was removed from the platform default group.
  final bool left;

  /// Why a write did not land, one line each. Empty when both landed.
  final List<String> problems;

  /// Whether the account is now seated correctly: in the staff group and out of
  /// the default one.
  bool get repaired => joined && left;

  @override
  String toString() => 'StaffSeatRepair($uid, joined: $joined, left: $left'
      '${problems.isEmpty ? '' : ', problems: ${problems.length}'})';
}

/// Applies #374's two seat writes to [accounts] — the accounts
/// [misSeatedStaffAccounts] found (#378).
///
/// The writes, and their order, are the ones `AddStaffToSmartschool` issues
/// after its `Save`, which are in turn the ones legacy
/// `Action\StaffAccount\AddToSmartschool.Apply` chained after its own:
///
///  1. `addUserToGroup(uid, staffGroup.code)` — addressed by **code**, so an
///     unresolved or official [staffGroup] cannot be written to at all;
///  2. `removeUserFromGroup(uid, defaultGroupName, now)` — addressed by
///     **name**, so it needs no node from the tree.
///
/// The two are independent, exactly as they are in the create: the removal is
/// attempted even when the add missed, because leaving a teacher in the student
/// subtree is the worse half of the same bug. Nothing throws — a refusal or a
/// transport error becomes a line in [StaffSeatRepair.problems], so one bad
/// account cannot abandon the rest of a batch halfway through. The caller
/// decides what an incomplete repair means; the tool prints it.
///
/// Idempotent in practice: `addUserToGroup` passes `keepOld = 1` and a repeat
/// removal of a group the account already left is a no-op, so a re-run after a
/// partial failure repairs only what is left.
Future<List<StaffSeatRepair>> repairStaffSeating(
  SmartschoolConnector connector,
  Iterable<MisSeatedStaffAccount> accounts, {
  required core.Group? staffGroup,
  String staffGroupName = smartschoolStaffGroupName,
  String defaultGroupName = smartschoolDefaultGroupName,
  DateTime Function() clock = DateTime.now,
}) async {
  final results = <StaffSeatRepair>[];
  for (final target in accounts) {
    final uid = target.account.uid;
    final problems = <String>[];

    final joined = await _join(
      connector,
      uid,
      staffGroup,
      staffGroupName,
      problems,
    );
    final left = await _leave(
      connector,
      uid,
      defaultGroupName,
      clock,
      problems,
    );

    results.add(
      StaffSeatRepair(
        uid: uid,
        joined: joined,
        left: left,
        problems: List.unmodifiable(problems),
      ),
    );
  }
  return results;
}

Future<bool> _join(
  SmartschoolConnector connector,
  String uid,
  core.Group? staffGroup,
  String staffGroupName,
  List<String> problems,
) async {
  if (staffGroup == null) {
    problems.add(
      'no group named $staffGroupName in the tree — cannot add $uid to it',
    );
    return false;
  }
  if (staffGroup.official) {
    problems.add(
      '${staffGroup.name} is an official class — members cannot be added to it',
    );
    return false;
  }
  try {
    final ok = await connector.addUserToGroup(uid, staffGroup.id.value);
    if (ok) return true;
    problems.add('Smartschool refused to add $uid to ${staffGroup.name}');
  } on Object catch (e) {
    problems.add('adding $uid to ${staffGroup.name} failed: $e');
  }
  return false;
}

Future<bool> _leave(
  SmartschoolConnector connector,
  String uid,
  String defaultGroupName,
  DateTime Function() clock,
  List<String> problems,
) async {
  try {
    // Legacy stamps the removal with the moment of the write
    // (`GroupManager.RemoveUserFromGroup`); the date carries no meaning for a
    // non-official group, but the API requires one.
    final ok = await connector.removeUserFromGroup(
      uid,
      defaultGroupName,
      clock(),
    );
    if (ok) return true;
    problems.add('Smartschool refused to remove $uid from $defaultGroupName');
  } on Object catch (e) {
    problems.add('removing $uid from $defaultGroupName failed: $e');
  }
  return false;
}

/// Trims and lower-cases [value] for case-insensitive matching (INV-12),
/// returning `null` for a null or blank input so an empty key never matches.
/// For identifiers only — group *names* go through
/// [core.normalizeGroupName] (#225).
String? _norm(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed.toLowerCase();
}
