/// The connection target for the centralized Cosmos DB account.
///
/// Epic #112 migrates the shared state off Azure SQL (ODBC/FFI) onto **Cosmos
/// DB (serverless) + Blob Storage**: the data is document-shaped, Cosmos needs
/// no native driver (pure-Dart HTTPS + JSON), has no cold-start pause, and keeps
/// the AAD-token / no-stored-secret property via data-plane RBAC. This value
/// type names *where* that account lives — the data-plane endpoint and the
/// database — and nothing more. It carries no credential: authentication is a
/// separate seam ([CosmosTokenProvider]), so the target can round-trip through
/// settings or a log line without leaking a secret (the same discipline
/// `SecretRef` applies to the config blob, and `AzureSqlConfig` applied before).
///
/// The concrete endpoint/database for this deployment are recorded in
/// `docs/port-plan.md`, not hard-coded here, so the library stays independent of
/// any one environment.
class CosmosConfig {
  const CosmosConfig({required this.endpoint, required this.database});

  /// The account's data-plane endpoint, e.g.
  /// `https://accountmanager-cosmos-arcadia.documents.azure.com:443/`. A
  /// trailing slash is tolerated — [CosmosClient] normalizes it when building
  /// request URLs.
  final String endpoint;

  /// The database (SQL API) name on the account, e.g. `accountmanager`.
  final String database;

  /// Serializes to a JSON-encodable map. Carries no secret, so it is safe to
  /// persist next to the rest of `AppSettings`.
  Map<String, dynamic> toJson() => {'endpoint': endpoint, 'database': database};

  /// Reconstructs a [CosmosConfig] from a map produced by [toJson].
  factory CosmosConfig.fromJson(Map<String, dynamic> json) => CosmosConfig(
        endpoint: json['endpoint'] as String,
        database: json['database'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is CosmosConfig &&
      other.endpoint == endpoint &&
      other.database == database;

  @override
  int get hashCode => Object.hash(endpoint, database);

  @override
  String toString() => 'CosmosConfig($endpoint/$database)';
}

/// The identity-map container: one document per person, `{ id, pk, naturalKey,
/// personId }`, keyed by the linker's natural key.
///
/// Provisioned as a **single logical partition** (every document carries the
/// same [identityPartitionKeyValue]) with a **unique-key policy on
/// `/naturalKey`**, so uniqueness — which Cosmos scopes per logical partition —
/// is enforced globally. That unique key is the convergence mechanism
/// `CosmosPersonIdResolver` relies on: when two operators both mint an id for a
/// brand-new key, the second create is rejected with `409 Conflict` and adopts
/// the winner's id (see the resolver's class doc). The container is created out
/// of band (`az cosmosdb sql container create … --unique-key-policy …`), not by
/// the app — data-plane RBAC cannot create containers.
const String identityContainer = 'identity';

/// The constant partition-key value every `identity` document carries, forcing
/// them into one logical partition so the `/naturalKey` unique key is global.
const String identityPartitionKeyValue = 'identity';

/// The document property the `identity` container's unique-key policy is on.
const String identityNaturalKeyPath = '/naturalKey';

/// The config container: a single settings document plus the import-rule sets,
/// stored as one JSON document. Partitioned by `/id`, so the singleton document
/// is its own logical partition and a point read/upsert is atomic.
const String settingsContainer = 'settings';

/// The id (and partition-key value) of the singleton settings document.
const String settingsDocumentId = 'settings';

/// The password-queue container, moved from `dbo.PasswordQueue`. The whole queue
/// is one document (`{ id, pk, entries }`) partitioned by `/pk`, so a save
/// replaces the queue atomically — faithful to the seam's "replaces the whole
/// queue".
const String passwordQueueContainer = 'passwordQueue';

/// The id of the singleton password-queue document.
const String passwordQueueDocumentId = 'queue';

/// The constant partition-key value the password-queue document carries.
const String passwordQueuePartitionKeyValue = 'queue';

/// The cold-snapshot metadata container (#107): one document per system
/// (`wisa` / `smartschool` / `azure`) holding `fetchedAt`, `syncedBy`, the Azure
/// `deltaToken`, and either the raw payload inline or a `blobRef` when the
/// payload exceeds Cosmos's 2 MB document limit. Partitioned by `/id`, so each
/// system's document is its own logical partition and a point read/upsert is
/// atomic. Only the sync/drift process reads these — the dashboard never does.
/// Provisioned out of band (data-plane RBAC cannot create containers).
const String snapshotsContainer = 'snapshots';

/// The materialized linked-accounts container (#115): one document per linked
/// account, `{ id, pk (school), … }`, partitioned by `/pk` so a school's
/// accounts share a logical partition and a classroom drill-down reads one
/// partition. The sync process rewrites these wholesale; a passive session
/// only reads them on drill-down.
const String linkedAccountsContainer = 'linkedAccounts';

/// The rollup-aggregates container (#115): the small school / grade-year /
/// classroom count documents that drive the drill-down without touching the
/// per-account docs. Partitioned by `/pk` (school).
const String rollupsContainer = 'rollups';

/// The operator-decisions container (#115): one document per decision
/// (`chosenAlternative` / `acceptedDuplicate` / `appliedStatus`), partitioned by
/// `/pk` (the account id). Kept separate from the derived docs so a re-sync
/// re-attaches still-applicable decisions instead of clobbering them. The write
/// UIs live in #109 / #110.
const String decisionsContainer = 'decisions';

/// The sync-state container (#115): a single document holding the `generation`
/// counter and last-sync freshness. Partitioned by `/id`, so the singleton is
/// its own logical partition and a point read/upsert is atomic.
const String syncStateContainer = 'syncState';

/// The id (and partition-key value) of the singleton sync-state document.
const String syncStateDocumentId = 'syncState';
