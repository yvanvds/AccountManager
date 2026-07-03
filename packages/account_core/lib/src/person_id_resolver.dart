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

/// A [PersonIdResolver] whose in-memory id map is populated by an asynchronous
/// [prepare] step *before* the pure pass, so [resolve] stays synchronous and
/// total.
///
/// The file- and memory-backed resolvers mint lazily inside [resolve] and need
/// no preparation. A resolver backed by a network store (the centralized Azure
/// SQL identity map, issue #85) cannot do I/O inside the synchronous [resolve],
/// so it is given the full set of keys up front: [prepare] runs the
/// transactional mint-or-fetch for every key, and [resolve] then serves purely
/// from memory. A caller that may hold either kind checks
/// `resolver is PreparablePersonIdResolver` and awaits [prepare] before it links
/// — a plain [PersonIdResolver] simply skips that step.
///
/// Moving minting ahead of the pass (rather than lazily inside it) is what lets
/// the DB resolver converge concurrent operators on **one id per key**: the
/// unique-constraint mint-or-fetch runs once, atomically, before any
/// [LinkedAccount] is built, so no id can diverge and then need reconciling.
abstract interface class PreparablePersonIdResolver
    implements PersonIdResolver {
  /// Mints-or-fetches the stable [PersonId] for every key in [naturalKeys] and
  /// caches it, so a subsequent [resolve] of any of those keys is a pure
  /// in-memory hit. New keys are minted and persisted; keys another operator
  /// already minted are fetched, so all operators converge. Idempotent: calling
  /// it again (e.g. before the next pass) only resolves keys not yet cached.
  Future<void> prepare(Iterable<String> naturalKeys);
}
