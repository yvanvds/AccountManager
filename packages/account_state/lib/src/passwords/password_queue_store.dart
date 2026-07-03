import 'dart:convert';
import 'dart:io';

import 'password_entry.dart';

/// The persistence seam for the pending-password queue.
///
/// Mirrors the legacy `PasswordManager`, which held two JSON-backed
/// `Manager<T>` lists (`Passwords.json` / `CoPasswords.json`). One store here
/// carries both [PasswordAccountKind]s — the [PasswordEntry.kind] tag
/// distinguishes them — keeping the seam a single injectable interface.
///
/// Injected so the orchestration layer neither knows nor cares where the queue
/// lives: tests use [InMemoryPasswordQueueStore], production uses
/// [FilePasswordQueueStore].
abstract interface class PasswordQueueStore {
  /// Loads all queued entries. An empty or never-persisted queue returns an
  /// empty list, not an error.
  Future<List<PasswordEntry>> load();

  /// Persists [entries], replacing the whole queue.
  Future<void> save(List<PasswordEntry> entries);
}

/// An in-memory [PasswordQueueStore] holding the queue in a field.
///
/// The default for headless tests. [save] copies the incoming list so a
/// caller mutating its own list afterwards cannot reach into the store.
class InMemoryPasswordQueueStore implements PasswordQueueStore {
  InMemoryPasswordQueueStore([List<PasswordEntry> initial = const []])
      : _entries = List.of(initial);

  List<PasswordEntry> _entries;

  @override
  Future<List<PasswordEntry>> load() async => List.of(_entries);

  @override
  Future<void> save(List<PasswordEntry> entries) async =>
      _entries = List.of(entries);
}

/// A [PasswordQueueStore] backed by a JSON file on disk.
///
/// The file holds a JSON array of entry objects. [load] returns an empty list
/// when the file is missing or empty; [save] writes the whole array as
/// pretty-printed JSON, creating parent directories as needed.
class FilePasswordQueueStore implements PasswordQueueStore {
  FilePasswordQueueStore(this.path);

  /// The path of the JSON file (legacy: `Passwords.json` / `CoPasswords.json`
  /// under `%APPDATA%\AccountManager\`).
  final String path;

  @override
  Future<List<PasswordEntry>> load() async {
    final file = File(path);
    if (!file.existsSync()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in decoded)
        PasswordEntry.fromJson(e as Map<String, dynamic>),
    ];
  }

  @override
  Future<void> save(List<PasswordEntry> entries) async {
    final file = File(path);
    file.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final json = entries.map((e) => e.toJson()).toList();
    await file.writeAsString('${encoder.convert(json)}\n');
  }
}
