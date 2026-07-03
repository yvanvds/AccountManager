/// Layer-5 orchestration package for the Arcadia Account Manager port.
///
/// This slice ships only the **persistence seams** the orchestration layer
/// will plug into — no sync/link/apply logic yet (spec `docs/domain-model.md`
/// §7, PROJECT_OVERVIEW §5–§7):
///
/// - [SettingsStore] — load/save the [AppSettings] config model, including the
///   per-connector import-rule sets.
/// - [PasswordQueueStore] — the pending-password queue ([PasswordEntry]).
/// - `PersonIdResolver` (re-exported from `account_core`) — the identity seam,
///   with `account_store`'s [FilePersonIdResolver] as the default
///   implementation.
///
/// Every seam has an in-memory default so the layer is testable headlessly
/// with zero network and zero infra. The persist-vs-derive split — what is
/// stored here vs recomputed by the linker — is described in the README.
///
/// Pure Dart plus `dart:io`. No Flutter.
library;

// Identity seam: reuse account_core's interface; account_store ships the
// file-backed default. Re-exported so consumers get the whole persistence
// surface from one import.
export 'package:account_core/account_core.dart' show PersonId, PersonIdResolver;
export 'package:account_store/account_store.dart' show FilePersonIdResolver;

export 'src/passwords/password_entry.dart';
export 'src/passwords/password_queue_store.dart';
export 'src/settings/app_settings.dart';
export 'src/settings/import_rule_codec.dart';
export 'src/settings/settings_store.dart';
