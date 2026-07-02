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
///   needs the group tree.
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

  const ClassPlacement({
    required this.className,
    required this.resolveClass,
    this.currentClass,
  });

  /// The current official class name, or `''` when the student is in no
  /// official class — the value legacy compared against [className].
  String get currentClassName => currentClass?.name ?? '';
}
