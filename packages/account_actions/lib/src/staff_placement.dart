import 'package:account_core/account_core.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;

/// The name of the Smartschool group a staff account belongs in (#374).
///
/// Legacy `Action\StaffAccount\AddToSmartschool.Apply` hard-codes it, and so do
/// we — but in **one** place. The issue that raised this asked whether the two
/// names should become settings; they should not, and the reason is the one the
/// issue itself gives: `Leerkrachten` was already being guessed in three
/// places. A third configurable name next to `AppSettings.smartschoolRoots` and
/// the Passwords screen's own `staffGroupName` would add a fourth guess, not
/// remove the first three. A tenant that renames the group changes this
/// constant (or injects a [StaffPlacement] naming another node) — a one-line
/// change in a port that is otherwise faithful to the names the school uses.
///
/// The one place is [ss.smartschoolStaffGroupName], in the connector package,
/// since #378: the repair that re-seats the accounts created *before* #374 has
/// to name the same group as the create, and it cannot import this package
/// (the dependency runs the other way). This alias keeps the action engine's
/// callers reading unchanged while there is still exactly one literal.
const String smartschoolStaffGroupName = ss.smartschoolStaffGroupName;

/// The name of the group Smartschool seats **every** `saveUser` account in,
/// whatever role the account carries (#374).
///
/// This is platform behaviour, not a choice of ours: the create cannot opt out
/// of it, so a staff create has to compensate afterwards by leaving the group
/// again. A student create deliberately does not — a student belongs here.
///
/// Aliased from [ss.smartschoolDefaultGroupName] for the reason above.
const String smartschoolDefaultGroupName = ss.smartschoolDefaultGroupName;

/// The Smartschool group-placement context for a freshly created **staff**
/// account (#374) — the staff twin of `ClassPlacement`.
///
/// Smartschool's `saveUser` seats every account it creates in the platform's
/// default group ([smartschoolDefaultGroupName]), so a staff create has two
/// unconditional follow-up writes: add the account to
/// [smartschoolStaffGroupName], and remove it from the default group. Legacy
/// performed both inside `AddToSmartschool.Apply`; the port dropped them, and
/// every staff account it had ever made sat in the student subtree instead.
///
/// The two writes need no membership knowledge at all — they are fixed-name
/// plumbing — but they *do* need the group tree, because `addUserToGroup`
/// addresses a group by its **code**. That tree does not live on a
/// [LinkedStaff], so it arrives here instead: a plain injectable value object,
/// exactly like `ClassPlacement` and `GroupPlacement`. The State layer resolves
/// it once from the Smartschool snapshot; the action reads a resolved target
/// and never walks a tree, which is what keeps this package pure.
///
/// Note the asymmetry the Smartschool API imposes, and why this carries both a
/// [Group] and a bare name for the default group: `saveUserToClassesAndGroups`
/// takes a group **code**, while `removeUserFromGroup` takes a group **name**.
/// So the add cannot happen at all unless [staffGroup] resolves, whereas the
/// removal only needs [defaultGroupName] — [defaultGroup] is the local node, and
/// its only job is to let the State layer drop the membership row from the
/// snapshot in hand.
class StaffPlacement {
  const StaffPlacement({
    this.staffGroup,
    this.defaultGroup,
    this.defaultGroupName = smartschoolDefaultGroupName,
  });

  /// The staff group ([smartschoolStaffGroupName]) a new account must be added
  /// to, resolved against the Smartschool tree.
  ///
  /// `null` when the tree carries no such group — the account is then created
  /// and left where `saveUser` put it, and the create says so in its warnings
  /// rather than failing.
  final Group? staffGroup;

  /// The default group's node in the tree, when the snapshot carries one.
  ///
  /// Used **only** so the State layer can drop the local membership row after a
  /// successful removal. The removal itself is addressed by [defaultGroupName],
  /// so a `null` here does not stop it: Smartschool seats the account in that
  /// group whether or not our (root-scoped) snapshot happens to show it.
  final Group? defaultGroup;

  /// The name of the platform default group to remove the new account from —
  /// [smartschoolDefaultGroupName] unless a tenant renamed it.
  final String defaultGroupName;
}
