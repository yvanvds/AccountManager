import 'dart:math' as math;

import 'package:account_core/account_core.dart';
import 'package:uuid/uuid.dart';

import 'cosmos_client.dart';
import 'cosmos_config.dart';

/// A [PersonIdResolver] backed by the centralized Cosmos `identity` container.
///
/// The Phase B replacement for `FilePersonIdResolver`, and the Cosmos successor
/// to `AzureSqlPersonIdResolver`: the same `NaturalKey → PersonId` mapping,
/// shared by the whole team instead of living in each operator's `%APPDATA%`
/// JSON. Centralizing it fixes the latent correctness bug the epic is built
/// around (#76) — a per-machine map mints a *different* [PersonId] for the same
/// human on each operator.
///
/// **Why two phases.** The linker calls `resolve` synchronously inside its pure
/// pass, but a Cosmos read is asynchronous, so this resolver cannot mint lazily
/// on a miss the way the file resolver does. Instead it is [prepare]d up front:
/// [prepare] fetches the still-unknown keys and mints-or-adopts every one still
/// absent, then [resolve] is a pure, synchronous, *total* lookup into the primed
/// cache (an unknown key means the caller forgot to prepare it — a programming
/// error, not a normal miss). The State layer computes the exact key set with
/// `account_linker`'s `naturalKeysFor` and awaits [prepare] before it links (see
/// `PreparablePersonIdResolver`).
///
/// **Warm cache.** The [_cache] survives across [prepare] calls within a
/// session, and [prepare] never reloads the whole container: it queries only the
/// keys it does not already hold, batched under [maxKeysPerQuery]. Since one link
/// pass runs [prepare] once — including after every apply-triggered incremental
/// relink — reloading the same documents each call would be pure waste. The
/// convergence guarantee below is what makes the narrow fetch safe: dropping a
/// proactive full reload cannot miss an id another operator minted, because the
/// mint-or-adopt path already adopts it on the conflicting create.
///
/// **Convergence.** For a brand-new key two operators may both mint a fresh
/// UUID. The `identity` container is a single logical partition with a
/// **unique-key policy on `/naturalKey`** (see [identityContainer]): each
/// operator's create carries a new document, but Cosmos admits only the first
/// for a given natural key and rejects the rest with `409 Conflict`. Whoever
/// committed first owns the id; the loser's create returns `false`, and it
/// re-reads the key to **adopt** the winner — so both [resolve] the same
/// [PersonId], with no after-the-fact reconciliation. This is the direct Cosmos
/// analogue of the SQL guarded insert (`INSERT … WHERE NOT EXISTS`) it replaces.
///
/// Each [prepare] reads a fresh per-operator token through the injected
/// [CosmosClient] (which the app wires to the operator's Cosmos data-plane
/// identity). Unit tests drive an in-memory fake client; the opt-in live
/// round-trip (skipped by default) exercises the real account.
class CosmosPersonIdResolver implements PreparablePersonIdResolver {
  CosmosPersonIdResolver({
    required CosmosClient client,
    String Function()? mintId,
  })  : _client = client,
        _mintId = mintId ?? _defaultMint;

  final CosmosClient _client;
  final String Function() _mintId;

  /// The primed identity map: natural key → resolved id. Seeded from the
  /// container and grown with freshly minted (or adopted) ids by [prepare].
  final Map<String, PersonId> _cache = {};

  /// The maximum number of natural keys bound into one `ARRAY_CONTAINS(@keys,
  /// …)` lookup. Cosmos has no hard parameter cap the way SQL Server does, but a
  /// huge array inflates the request body and RU cost, so a large key set is
  /// split into this-sized chunks.
  static const int maxKeysPerQuery = 500;

  /// The maximum number of `identity` creates issued concurrently. Cosmos
  /// creates are one round-trip each (no multi-document create outside a
  /// per-partition transactional batch), so a first run over a real school
  /// (~1500 fresh keys) is fanned out under this bound rather than run
  /// sequentially — which is what froze the SQL path before it was batched
  /// (#99) — while staying polite to the account's RU budget.
  static const int createConcurrency = 32;

  static String _defaultMint() => const Uuid().v4();

  @override
  Future<void> prepare(Iterable<String> naturalKeys) async {
    // Idempotent: keys already resolved this session need no work. The cache is
    // warm across calls, so a re-prepare only ever fetches genuinely new keys.
    final wanted = naturalKeys.toSet()..removeWhere(_cache.containsKey);
    if (wanted.isEmpty) return;

    // 1. Read the ids that already exist, batched under [maxKeysPerQuery]. Every
    //    already-minted id is served without a create attempt.
    await _fetchInto(wanted.toList());

    final missing = [
      for (final key in wanted)
        if (!_cache.containsKey(key)) key
    ];
    if (missing.isEmpty) return;

    // 2. Mint-or-adopt the genuinely new keys. Each create is guarded by the
    //    `/naturalKey` unique key: a 201 means we won and own the minted id; a
    //    409 (create returns false) means a concurrent operator won, so the key
    //    is set aside to adopt in step 3. Fanned out under [createConcurrency].
    final conflicted = <String>[];
    for (var i = 0; i < missing.length; i += createConcurrency) {
      final batch =
          missing.sublist(i, math.min(i + createConcurrency, missing.length));
      final outcomes = await Future.wait(batch.map(_mint));
      for (var j = 0; j < batch.length; j++) {
        if (!outcomes[j]) conflicted.add(batch[j]);
      }
    }

    // 3. Adopt the winners of every lost race in one batched read.
    if (conflicted.isNotEmpty) {
      await _fetchInto(conflicted);
      for (final key in conflicted) {
        if (!_cache.containsKey(key)) {
          // Unreachable in practice: a 409 means the natural key exists, so the
          // read-back must find it. (A UUID id-collision would also 409, but
          // that is astronomically unlikely.)
          throw StateError('identity document vanished for key: $key');
        }
      }
    }
  }

  /// Mints an id for [key] and tries to claim it. Returns `true` when the create
  /// was accepted (we own the id) and `false` on a unique-key conflict (a
  /// concurrent operator already claimed the key — adopt it via a read-back).
  Future<bool> _mint(String key) async {
    final id = _mintId();
    final created = await _client.createDocument(
      container: identityContainer,
      partitionKey: identityPartitionKeyValue,
      document: {
        'id': id,
        'pk': identityPartitionKeyValue,
        'naturalKey': key,
        'personId': id,
      },
    );
    if (created) _cache[key] = PersonId(id);
    return created;
  }

  /// Queries the ids for [keys] (chunked under [maxKeysPerQuery]) and caches each
  /// hit. Missing keys are simply absent from the result — the caller decides
  /// whether that is expected (a first-time key) or an error (a lost-race key).
  Future<void> _fetchInto(List<String> keys) async {
    for (var i = 0; i < keys.length; i += maxKeysPerQuery) {
      final chunk = keys.sublist(i, math.min(i + maxKeysPerQuery, keys.length));
      final rows = await _client.queryDocuments(
        container: identityContainer,
        partitionKey: identityPartitionKeyValue,
        query: 'SELECT c.naturalKey, c.personId FROM c '
            'WHERE ARRAY_CONTAINS(@keys, c.naturalKey)',
        parameters: {'@keys': chunk},
      );
      for (final row in rows) {
        _cache[_string(row['naturalKey'])] = PersonId(_string(row['personId']));
      }
    }
  }

  @override
  PersonId resolve(String naturalKey) {
    final id = _cache[naturalKey];
    if (id == null) {
      throw StateError(
        'CosmosPersonIdResolver.resolve("$naturalKey") before prepare(): the '
        'Cosmos-backed resolver mints ahead of the pass, so every natural key '
        'link() will resolve must be passed to prepare() first (via '
        'naturalKeysFor).',
      );
    }
    return id;
  }
}

/// Reads a document value as a non-null string. The identity properties are
/// always present and string-typed, so a null here would be a data violation;
/// coercing keeps the mapping total.
String _string(Object? value) => (value as String?) ?? '';
