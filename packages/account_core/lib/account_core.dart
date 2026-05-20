/// Canonical domain model for the Arcadia Account Manager port.
///
/// Pure-Dart entities, identity types, enums, password generator, and log
/// sink. No Flutter, no I/O, no connector SDKs.
///
/// Spec: `docs/domain-model.md`. Legacy reference (read-only):
/// `legacy-wpf/AccountApi/`.
library;

export 'src/enums.dart';
export 'src/group.dart';
export 'src/ids.dart';
export 'src/linked.dart';
export 'src/log.dart';
export 'src/password.dart';
export 'src/person.dart';
export 'src/snapshot.dart';
export 'src/source_records.dart';
