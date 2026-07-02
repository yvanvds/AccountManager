/// Action engine for the Arcadia Account Manager port.
///
/// A sealed `Action` hierarchy grouped by family (spec
/// `docs/domain-model.md` §3.10, §6.3–6.4). Each action exposes a pure
/// `evaluate()` and `describeChanges()` and an impure, dry-run-capable
/// `apply()` that returns the **mutated source record** so the State layer can
/// patch its snapshot without a network re-sync.
///
/// This package currently ships the **student** family and its dispatcher.
/// The staff and group families are tracked as follow-ups to #46, mirroring
/// how the linker shipped student/staff/group as separate slices
/// (#43/#44/#45).
///
/// Pure Dart — no Flutter, no UI coupling. Legacy reference (read-only):
/// `legacy-wpf/AccountManager/Action/`.
library;

export 'src/action_result.dart';
export 'src/apply_options.dart';
export 'src/change_set.dart';
export 'src/connectors.dart';
export 'src/student_action.dart';
export 'src/student_action_config.dart';
export 'src/student_dispatch.dart';
