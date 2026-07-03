import 'dart:convert';
import 'dart:io';

import 'app_settings.dart';

/// The persistence seam for the [AppSettings] config model.
///
/// The orchestration layer loads settings once at startup and saves them when
/// the operator edits connection details or import rules. Injecting this
/// interface keeps that layer free of any disk/format concern (the same reason
/// `account_store` hides UUID minting behind `PersonIdResolver`): tests drive
/// an in-memory store, production uses [FileSettingsStore].
abstract interface class SettingsStore {
  /// Loads the persisted settings. A store with nothing persisted yet returns
  /// a default [AppSettings] rather than throwing, so first-run has no special
  /// case.
  Future<AppSettings> load();

  /// Persists [settings], replacing any previously stored value.
  Future<void> save(AppSettings settings);
}

/// An in-memory [SettingsStore] holding a single [AppSettings] in a field.
///
/// The default for headless tests: zero disk, zero infra. Seed it with an
/// initial value to simulate a store that already has content.
class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([AppSettings initial = const AppSettings()])
      : _settings = initial;

  AppSettings _settings;

  @override
  Future<AppSettings> load() async => _settings;

  @override
  Future<void> save(AppSettings settings) async => _settings = settings;
}

/// A [SettingsStore] backed by a JSON file on disk.
///
/// [load] returns a default [AppSettings] when the file is missing or empty;
/// [save] writes the whole model as pretty-printed JSON, creating parent
/// directories as needed. Whole-file writes are fine — the config is small and
/// saved only on operator edits.
class FileSettingsStore implements SettingsStore {
  FileSettingsStore(this.path);

  /// The path of the JSON file (legacy: `%APPDATA%\AccountManager\config.json`).
  final String path;

  @override
  Future<AppSettings> load() async {
    final file = File(path);
    if (!file.existsSync()) return const AppSettings();
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return const AppSettings();
    return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> save(AppSettings settings) async {
    final file = File(path);
    file.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(settings.toJson())}\n');
  }
}
