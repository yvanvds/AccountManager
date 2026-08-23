import 'package:account_core/account_core.dart';

/// The Smartschool class-placement context for one student — the membership +
/// group-tree data a [LinkedAccount] does not carry (spec
/// `docs/domain-model.md` §3.7, PAIN-1, INV-31).
///
/// Two student actions need it and neither can be expressed as a pure function
/// of a [LinkedAccount] alone (which is why #46 deferred them):
/// `MoveToSmartschoolClassGroup` and the class-group placement step inside
/// `AddStudentToSmartschool`. Both need to know
/// - which official Smartschool class the student is *currently* in — sourced
///   from the Smartschool memberships, which the linker does not project onto a
///   [LinkedAccount] (a `LinkedAccount` has no membership at all); and
/// - how to resolve a class *name* to its Smartschool group (and code), which
///   needs the group tree; and
/// - whether a class name is one of *our* classes at all (#333), which needs
///   the managed schools' WISA class inventory.
///
/// This is a plain injectable value object, exactly like [StudentActionConfig]:
/// the caller (the future State layer, or a test) builds one per student from
/// the Smartschool snapshot and binds it to the action. Keeping the snapshot
/// out of the action preserves the package's pure-function boundary — the
/// action reads the placement, it never walks a tree or a membership list.
class ClassPlacement {
  /// The student's current *official* Smartschool class, or `null` when the
  /// student holds no official class membership (e.g. a freshly created account
  /// that has not been placed yet). Mirrors legacy `Smartschool.Account.Group`,
  /// which held the account's class name.
  final Group? currentClass;

  /// The student's target class name as it should read in Smartschool — the
  /// WISA `classGroup`, plus the `classSubGroup` when the class uses sub-groups
  /// (legacy `Student.ClassName` / `ClassGroupManager.UseSubGroups`). The
  /// sub-group decision needs the class-group admin data, which lives outside
  /// the student record, so the caller computes it; without sub-groups it is
  /// just the bare `classGroup`.
  final String className;

  /// Resolves a Smartschool class group by name across the whole tree,
  /// including the non-official "Leerlingen" root (legacy
  /// `GroupManager.Root.Find`). Returns `null` when no group carries that name.
  final Group? Function(String name) resolveClass;

  /// Whether [name] is one of **our own** classes — a class the WISA schools
  /// the operator manages actually have (#333).
  ///
  /// The guard in front of every class write fed by this placement: a class
  /// name our WISA does not have is never something to write into our
  /// Smartschool, at any point in the year, so an action that would propose one
  /// raises nothing at all instead of a proposal that can be bulk-applied.
  /// Observed live as a dual-enrolled student offered `3MWW1 → 3HWa` — a
  /// sibling group school's class — on a card whose "Toepassen op alle (14)"
  /// cohort otherwise held thirteen legitimate rollover moves (#332 fixed the
  /// placement that named it; this is the guard that holds whatever names it).
  ///
  /// It asks about **WISA**, deliberately — not about the Smartschool tree
  /// [resolveClass] searches. At the September rollover the target class
  /// legitimately does not exist in Smartschool yet (creating it is another
  /// action on another card), so gating on `resolveClass != null` would
  /// suppress the very moves these actions exist for. A class that is ours but
  /// missing from Smartschool still fails loudly at apply time; a foreign one
  /// never gets that far.
  final bool Function(String name) isOurClass;

  const ClassPlacement({
    required this.className,
    required this.resolveClass,
    required this.isOurClass,
    this.currentClass,
  });

  /// The current official class name, or `''` when the student is in no
  /// official class — the value legacy compared against [className].
  String get currentClassName => currentClass?.name ?? '';
}
