import 'package:account_core/account_core.dart';

/// The Smartschool creation context for one WISA class group — the membership
/// and group-tree data a [LinkedGroup] does not carry (spec
/// `docs/domain-model.md` §3.7, §6.3, PAIN-1).
///
/// Two group actions need it and neither can be expressed as a pure function of
/// a [LinkedGroup] alone (which is why #54 deferred them):
/// `AddToSmartschool` and `CreateInSmartschool`. Both branch on whether the
/// WISA class currently holds students — a signal that lives in the WISA
/// membership list, not on the [Group] record — and `AddToSmartschool` also
/// needs the Smartschool group tree to resolve the parent the new class hangs
/// under.
///
/// This is a plain injectable value object, exactly like [ClassPlacement]: the
/// caller (the future State layer, or a test) builds one per WISA-only class
/// from the WISA and Smartschool snapshots and binds it to the dispatch.
/// Keeping the snapshots out of the action preserves the package's pure-function
/// boundary — the action reads the placement, it never walks a tree or a
/// membership list.
class GroupPlacement {
  /// Whether the WISA class currently holds any students (legacy
  /// `WisaClassGroup.ContainsStudents()`). Distinguishes `AddToSmartschool`
  /// (create a populated official class) from `CreateInSmartschool` (an empty
  /// WISA class, informational only).
  final bool containsStudents;

  /// The Smartschool parent group the new class should hang under — legacy
  /// `GroupManager.GetLogicalParent(name)` resolved through
  /// `Root.FindByCode(...)`. The caller performs that year → grade/path lookup
  /// against the group tree; the action only reads the result.
  ///
  /// `null` when the parent cannot be resolved (the class name's leading digit
  /// is out of the 1–7 range, or the resolved parent node is absent from the
  /// tree), in which case `AddToSmartschool.apply` cannot place the class and
  /// reports a failure rather than legacy's silent no-op.
  final Group? parent;

  const GroupPlacement({required this.containsStudents, this.parent});
}
