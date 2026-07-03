import 'dart:math' as math;

import 'package:account_core/account_core.dart';
import 'package:uuid/uuid.dart';

import 'aad_token_provider.dart';
import 'azure_sql_config.dart';
import 'person_id_schema.dart';
import 'sql_connection.dart';

/// A [PersonIdResolver] backed by the centralized Azure SQL identity map.
///
/// The Phase B replacement for `FilePersonIdResolver` (issue #85): the same
/// `NaturalKey → PersonId` mapping, but shared by the whole team instead of
/// living in each operator's `%APPDATA%` JSON. Centralizing it fixes the latent
/// correctness bug the epic is built around (#76) — a per-machine map mints a
/// *different* [PersonId] for the same human on each operator.
///
/// **Why two phases.** The linker calls `resolve` synchronously inside its pure
/// pass, but a database read is asynchronous, so this resolver cannot mint
/// lazily on a miss the way the file resolver does. Instead it is
/// [prepare]d up front: [prepare] fetches the still-unknown keys and
/// mints-or-fetches every one still absent in one transaction, then [resolve] is
/// a pure, synchronous, *total* lookup into the primed cache (an unknown key
/// means the caller forgot to prepare it — a programming error, not a normal
/// miss). The State layer computes the exact key set with `account_linker`'s
/// `naturalKeysFor` and awaits [prepare] before it links (see
/// `PreparablePersonIdResolver`).
///
/// **Warm cache (#93).** The [_cache] survives across [prepare] calls within a
/// session, and [prepare] never reloads the whole table: it fetches only the
/// keys it does not already hold, batched under the SQL Server parameter limit
/// (`WHERE NaturalKey IN (...)`). Since one link pass runs [prepare] once —
/// including after every apply-triggered incremental relink — a full-table
/// `SELECT *` per call reloaded the same rows many times over for no gain. The
/// convergence guarantee below is what makes the narrow fetch safe: dropping the
/// proactive full reload cannot miss an id another operator minted, because the
/// mint-or-fetch path already adopts it on write.
///
/// **Convergence.** For a brand-new key two operators may both mint a fresh
/// UUID. The insert is guarded by the natural-key primary key
/// ([personIdentityTableName]): each operator inserts its id *only if the key is
/// still absent* (a serializable key-range lock orders the two), then reads the
/// row back. Whoever committed first owns the id; the other inserts nothing and
/// adopts the winner — so both [resolve] the same [PersonId], with no
/// after-the-fact reconciliation.
///
/// Like the other Phase B adapters, each [prepare] opens a fresh connection
/// through the injected [SqlConnectionFactory] (which reads a new per-operator
/// token) and closes it when done. The concrete ODBC/FFI factory is deferred to
/// #89; unit tests drive a scripted fake and the opt-in live round-trip
/// (skipped by default) exercises the real driver once it lands.
class AzureSqlPersonIdResolver implements PreparablePersonIdResolver {
  AzureSqlPersonIdResolver({
    required SqlConnectionFactory factory,
    required AzureSqlConfig config,
    required AadTokenProvider tokens,
    String Function()? mintId,
  })  : _factory = factory,
        _config = config,
        _tokens = tokens,
        _mintId = mintId ?? _defaultMint;

  final SqlConnectionFactory _factory;
  final AzureSqlConfig _config;
  final AadTokenProvider _tokens;
  final String Function() _mintId;

  /// The primed identity map: natural key → resolved id. Seeded from the table
  /// and grown with freshly minted (or adopted) ids by [prepare].
  final Map<String, PersonId> _cache = {};

  /// The maximum number of natural keys bound into one `WHERE NaturalKey IN
  /// (...)` lookup.
  /// SQL Server caps a single statement at ~2100 parameters, so a larger key set
  /// is split into this-sized chunks. Kept well under the ceiling for headroom.
  static const int maxKeysPerLookup = 2000;

  static String _defaultMint() => const Uuid().v4();

  @override
  Future<void> prepare(Iterable<String> naturalKeys) async {
    // Idempotent: keys already resolved this session need no work. The cache is
    // warm across calls, so a re-prepare only ever fetches genuinely new keys.
    final wanted = naturalKeys.toSet()..removeWhere(_cache.containsKey);
    if (wanted.isEmpty) return;

    final connection = await _factory.open(_config, _tokens);
    try {
      // Fetch only the keys we do not already hold — never the whole table.
      // Batched under [maxKeysPerLookup] so a large key set stays under the SQL
      // Server parameter limit; each already-minted id is served without a
      // round-trip per key.
      final lookup = wanted.toList();
      for (var i = 0; i < lookup.length; i += maxKeysPerLookup) {
        final chunk =
            lookup.sublist(i, math.min(i + maxKeysPerLookup, lookup.length));
        for (final row
            in await connection.query(_selectInSql(chunk.length), chunk)) {
          _cache[_string(row['NaturalKey'])] =
              PersonId(_string(row['PersonId']));
        }
      }

      final missing = [
        for (final key in wanted)
          if (!_cache.containsKey(key)) key
      ];
      if (missing.isEmpty) return;

      // Mint-or-fetch the genuinely new keys atomically (see the class doc): the
      // guarded insert plus its read-back is the "converge on one id" step, so
      // it runs inside a single transaction as the seam intends (#85).
      await connection.transaction((tx) async {
        for (final key in missing) {
          await tx.execute(_insertIfAbsentSql, [key, _mintId(), key]);
          final winner = await tx.query(_selectOneSql, [key]);
          if (winner.isEmpty) {
            // Unreachable: the key either pre-existed or we just inserted it.
            throw StateError('PersonIdentity row vanished for key: $key');
          }
          _cache[key] = PersonId(_string(winner.first['PersonId']));
        }
      });
    } finally {
      await connection.close();
    }
  }

  @override
  PersonId resolve(String naturalKey) {
    final id = _cache[naturalKey];
    if (id == null) {
      throw StateError(
        'AzureSqlPersonIdResolver.resolve("$naturalKey") before prepare(): the '
        'DB-backed resolver mints ahead of the pass, so every natural key link() '
        'will resolve must be passed to prepare() first (via naturalKeysFor).',
      );
    }
    return id;
  }
}

/// Reads the rows for a batch of [count] natural keys — the warm-cache fetch
/// that replaced the full-table load (#93). The placeholders are generated (not
/// interpolated data): the keys themselves are bound positionally as parameters,
/// so a key can never be read as SQL. Callers chunk [count] under the SQL Server
/// parameter limit (see `AzureSqlPersonIdResolver.maxKeysPerLookup`).
String _selectInSql(int count) =>
    'SELECT NaturalKey, PersonId FROM $personIdentityTableName '
    'WHERE NaturalKey IN (${List.filled(count, '?').join(', ')})';

/// Reads back the row that owns [NaturalKey] after a guarded insert — either the
/// id this operator just minted or the one a concurrent operator committed first.
const String _selectOneSql =
    'SELECT PersonId FROM $personIdentityTableName WHERE NaturalKey = ?';

/// Inserts a freshly minted id **only if the key is still absent**. The
/// `UPDLOCK, HOLDLOCK` takes a serializable key-range lock so two operators
/// minting the same new key are ordered: the loser's `NOT EXISTS` sees the
/// winner's row and inserts nothing. Params: `[naturalKey, personId, naturalKey]`.
const String _insertIfAbsentSql = 'INSERT INTO $personIdentityTableName '
    '(NaturalKey, PersonId) SELECT ?, ? WHERE NOT EXISTS ('
    'SELECT 1 FROM $personIdentityTableName WITH (UPDLOCK, HOLDLOCK) '
    'WHERE NaturalKey = ?)';

/// Reads a driver value as a non-null string. The identity columns are declared
/// `NOT NULL`, so a null here would be a schema violation; coercing keeps the
/// mapping total and driver-agnostic.
String _string(Object? value) => (value as String?) ?? '';
