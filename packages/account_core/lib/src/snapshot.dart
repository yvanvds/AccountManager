import 'enums.dart';

/// Per-system, immutable result of one sync.
///
/// Spec: `docs/domain-model.md` §3.8. Concrete subtypes
/// (`WisaSnapshot`, `SmartschoolSnapshot`, `AzureSnapshot`) live in their
/// respective connector packages. This interface only exposes what the
/// linker and the UI need across systems.
abstract interface class Snapshot {
  /// When the connector finished the sync that produced this snapshot.
  DateTime get fetchedAt;

  /// Which system this snapshot came from.
  Origin get origin;
}
