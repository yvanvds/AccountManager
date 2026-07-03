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
/// [prepare]d up front: [prepare] loads the whole map and mints-or-fetches every
/// still-unknown key in one transaction, then [resolve] is a pure, synchronous,
/// *total* lookup into the primed cache (an unknown key means the caller forgot
/// to prepare it — a programming error, not a normal miss). The State layer
/// computes the exact key set with `account_linker`'s `naturalKeysFor` and
/// awaits [prepare] before it links (see `PreparablePersonIdResolver`).
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

  static String _defaultMint() => const Uuid().v4();

  @override
  Future<void> prepare(Iterable<String> naturalKeys) async {
    // Idempotent: keys already resolved this session need no work.
    final wanted = naturalKeys.toSet()..removeWhere(_cache.containsKey);
    if (wanted.isEmpty) return;

    final connection = await _factory.open(_config, _tokens);
    try {
      // Load the whole identity map — one small row per person, mirroring the
      // file resolver reading its whole file — so every already-minted id is
      // served without a round-trip per key.
      for (final row in await connection.query(_selectAllSql)) {
        _cache[_string(row['NaturalKey'])] = PersonId(_string(row['PersonId']));
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

/// Loads the whole identity map. Small — one row per person — so reading it
/// whole to seed the cache is simpler and safe rather than a bottleneck.
const String _selectAllSql =
    'SELECT NaturalKey, PersonId FROM $personIdentityTableName';

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
