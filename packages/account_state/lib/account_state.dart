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
/// - [SqlConnection] / [SqlConnectionFactory] + [AadTokenProvider] — the
///   connection/auth seam the Phase B Azure SQL adapters plug into (#74). The
///   database is AAD-only, so a connection is authenticated with a per-operator
///   bearer token; the concrete ODBC/FFI factory lands with the first adapter.
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
export 'package:account_core/account_core.dart' show PersonId, PersonIdResolver;
export 'package:account_store/account_store.dart' show FilePersonIdResolver;

export 'src/apply/state_applier.dart';
export 'src/apply/wisa_import_rules.dart';
export 'src/link/linked_state.dart';
export 'src/link/placement.dart';
export 'src/passwords/password_entry.dart';
export 'src/passwords/password_queue_store.dart';
export 'src/settings/app_settings.dart';
export 'src/settings/connection.dart';
export 'src/settings/import_rule_codec.dart';
export 'src/settings/secret_provider.dart';
export 'src/settings/settings_store.dart';
export 'src/settings/work_date.dart';
export 'src/sql/aad_token_provider.dart';
export 'src/sql/azure_sql_config.dart';
export 'src/sql/azure_sql_live_config.dart';
export 'src/sql/azure_sql_settings_store.dart';
export 'src/sql/settings_schema.dart';
export 'src/sql/sql_connection.dart';
export 'src/sync/application_state.dart';
export 'src/sync/system_state.dart';
