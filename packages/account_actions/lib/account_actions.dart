/// Action engine for the Arcadia Account Manager port.
///
/// A sealed `Action` hierarchy grouped by family (spec
/// `docs/domain-model.md` §3.10, §6.3–6.4). Each action exposes a pure
/// `evaluate()` and `describeChanges()` and an impure, dry-run-capable
/// `apply()` that returns the **mutated source record** so the State layer can
/// patch its snapshot without a network re-sync.
///
/// This package ships the **student**, **staff**, and **group** families and
/// their dispatchers, mirroring how the linker shipped student/staff/group as
/// separate slices (#43/#44/#45). The group family ships the subset the
/// `LinkedGroup` model can express (#54); membership/tree-dependent group
/// actions are tracked as a follow-up (see the package README).
///
/// Pure Dart — no Flutter, no UI coupling. Legacy reference (read-only):
/// `legacy-wpf/AccountManager/Action/`.
library;

export 'src/action_result.dart';
export 'src/apply_options.dart';
export 'src/change_set.dart';
export 'src/connectors.dart';
export 'src/group_action.dart';
export 'src/group_dispatch.dart';
export 'src/staff_action.dart';
export 'src/staff_action_config.dart';
export 'src/staff_dispatch.dart';
export 'src/student_action.dart';
export 'src/student_action_config.dart';
export 'src/student_dispatch.dart';
