/// Layer-5 orchestration package for the Arcadia Account Manager port.
///
/// Persistence seams the orchestration layer plugs into (spec
/// `docs/domain-model.md` §7, PROJECT_OVERVIEW §5–§7):
///
/// - [SettingsStore] — load/save the [AppSettings] config model, including the
///   per-connector import-rule sets.
/// - [PasswordQueueStore] — the pending-password queue ([PasswordEntry]).
/// - `PersonIdResolver` (re-exported from `account_core`) — the identity seam,
///   with `account_store`'s [FilePersonIdResolver] as the default
///   implementation.
/// - [CosmosClient] / [CosmosTransport] + [CosmosTokenProvider] — the
///   data-plane/auth seam the Cosmos adapters plug into (#114). The account is
///   AAD-only, so each request is authenticated with a per-operator bearer
///   token; [HttpCosmosClient] binds the pure-Dart HTTPS+JSON data plane, so
///   there is no native driver dependency.
/// - [SnapshotStore] — the cold store the three connector snapshots (WISA,
///   Smartschool, Azure + delta token) persist to, so a fresh session seeds
///   from the store instead of re-pulling (#107). [CosmosSnapshotStore] keeps
///   the metadata in Cosmos and overflows large payloads to a [BlobStore]
///   ([HttpBlobStore] over the same AAD-token discipline). [persistingSyncer]
///   and [seedSnapshot] compose that persistence over a [SystemState]'s syncer.
/// - [SignalPublisher] / [SignalSubscriber] — the realtime change-notification
///   seam (#116): a writer publishes a small, data-free [ChangeSignal] and every
///   connected operator is nudged to refetch just the changed shard, so the
///   shared view stays live without polling the serverless stores awake.
///   [InMemorySignalHub] is the fan-out fake; [SignalRPublisher] posts to Azure
///   SignalR's REST endpoint over the same AAD / no-stored-secret discipline.
///
/// Every seam has an in-memory default so the layer is testable headlessly
/// with zero network and zero infra. The persist-vs-derive split — what is
/// stored here vs recomputed by the linker — is described in the README.
///
/// On top of the seams, the sync layer owns the connector snapshots
/// (domain-model §6.1):
///
/// - [SystemState] — one system's last-good snapshot, `lastSync`, and transient
///   connection-test state; `sync()` replaces the snapshot only on success.
/// - [ApplicationState] — the three [SystemState]s plus a `sync(Origin)` entry
///   point. [azureSyncer] wires the delta-from-day-one behaviour (PAIN-2).
///
/// On top of the snapshots, the linked view is **derived** (never persisted):
///
/// - [LinkedState] — re-runs the pure `link()` over the current snapshots and
///   the three action dispatchers, with the membership/tree-dependent actions
///   wired through a [PlacementResolver] built from the injected
///   [SmartschoolClassTree] (#55 / #65).
///
/// Driving the action engine and keeping the snapshots consistent afterwards:
///
/// - [StateApplier] — runs an action's dry-run-capable `apply()`, then on a
///   real write patches the owning snapshot from the mutated record and
///   re-runs `link()` with no re-sync, or (for a `DontImportFromWisa` rule)
///   accumulates it in [WisaImportRules] and re-syncs WISA (#72).
///
/// Pure Dart plus `dart:io`. No Flutter.
library;

// Identity seam: reuse account_core's interface; account_store ships the
// file-backed default. Re-exported so consumers get the whole persistence
// surface from one import.
export 'package:account_core/account_core.dart'
    show PersonId, PersonIdResolver, PreparablePersonIdResolver;
export 'package:account_store/account_store.dart' show FilePersonIdResolver;

export 'src/apply/state_applier.dart';
export 'src/apply/wisa_import_rules.dart';
export 'src/blob/blob_store.dart';
export 'src/blob/blob_token_provider.dart';
export 'src/blob/blob_transport.dart';
export 'src/keyvault/key_vault_config.dart';
export 'src/keyvault/key_vault_live_config.dart';
export 'src/keyvault/key_vault_secret_provider.dart';
export 'src/keyvault/key_vault_token_provider.dart';
export 'src/keyvault/key_vault_transport.dart';
export 'src/link/azure_class_groups.dart';
export 'src/link/linked_state.dart';
export 'src/link/placement.dart';
export 'src/materialize/accepted_duplicates.dart';
export 'src/materialize/decisions_merge.dart';
export 'src/materialize/linked_state_materializer.dart';
export 'src/materialize/linked_store.dart';
export 'src/materialize/materialized_state.dart';
export 'src/passwords/password_entry.dart';
export 'src/passwords/password_queue_store.dart';
export 'src/realtime/change_signal.dart';
export 'src/realtime/signal_channel.dart';
export 'src/realtime/signalr_config.dart';
export 'src/realtime/signalr_hub_protocol.dart';
export 'src/realtime/signalr_live_config.dart';
export 'src/realtime/signalr_negotiate.dart';
export 'src/realtime/signalr_publisher.dart';
export 'src/realtime/signalr_socket.dart';
export 'src/realtime/signalr_subscriber.dart';
export 'src/realtime/signalr_token_provider.dart';
export 'src/realtime/signalr_transport.dart';
export 'src/settings/app_settings.dart';
export 'src/settings/connection.dart';
export 'src/settings/import_rule_codec.dart';
export 'src/settings/live_settings.dart';
export 'src/settings/secret_provider.dart';
export 'src/settings/settings_store.dart';
export 'src/settings/wisa_school_label.dart';
export 'src/settings/wisa_school_merge.dart';
export 'src/settings/wisa_school_profile.dart';
export 'src/settings/work_date.dart';
export 'src/cosmos/cosmos_client.dart';
export 'src/cosmos/cosmos_config.dart';
export 'src/cosmos/cosmos_containers.dart';
export 'src/cosmos/cosmos_live_config.dart';
export 'src/cosmos/cosmos_password_queue_store.dart';
export 'src/cosmos/cosmos_person_id_resolver.dart';
export 'src/cosmos/cosmos_linked_store.dart';
export 'src/cosmos/cosmos_retry.dart';
export 'src/cosmos/cosmos_settings_store.dart';
export 'src/cosmos/cosmos_snapshot_store.dart';
export 'src/cosmos/cosmos_token_provider.dart';
export 'src/cosmos/cosmos_transport.dart';
export 'src/sync/application_state.dart';
export 'src/sync/snapshot_persistence.dart';
export 'src/sync/system_state.dart';
export 'src/sync/wisa_snapshot_diff.dart';
