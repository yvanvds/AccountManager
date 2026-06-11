import 'ids.dart';

/// Resolves a natural key to a stable [PersonId].
///
/// The linker derives a natural key for each person it encounters and asks a
/// resolver to turn it into a `PersonId`. The same key must always map to the
/// same id, within a process and across runs.
///
/// How ids are minted and whether they are persisted is deliberately left out
/// of this contract so the linker stays a pure function (INV-20): all
/// non-determinism (UUID minting) and I/O (disk persistence) live behind this
/// interface. The linker depends only on the interface and never imports an
/// implementation. See decision OQ-3.
abstract interface class PersonIdResolver {
  /// Returns the stable [PersonId] for [naturalKey], minting and persisting a
  /// fresh one the first time a key is seen. Calling it again with the same
  /// key — later in this process or in a future run — returns the same id.
  PersonId resolve(String naturalKey);
}
