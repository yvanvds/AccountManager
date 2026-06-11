import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart';
import 'package:uuid/uuid.dart';

/// A [PersonIdResolver] backed by a JSON file on disk.
///
/// The file holds a flat `{ "<naturalKey>": "<uuid>" }` object. The whole map
/// is read into memory once by [load]; [resolve] then serves hits from memory
/// and, on a miss, mints a fresh UUID, writes the updated map back to disk
/// synchronously, and returns the new id. Writing inside [resolve] is what
/// lets the contract stay synchronous (so the pure linker can call it) while
/// still persisting every mint.
///
/// Persistence is whole-file: each mint rewrites the entire map. The id sets
/// involved (one entry per person) are small enough that this is simpler and
/// safe rather than a bottleneck.
class FilePersonIdResolver implements PersonIdResolver {
  FilePersonIdResolver._(this._file, this._map, this._mintId);

  final File _file;
  final Map<String, String> _map;
  final String Function() _mintId;

  /// Loads a resolver from the JSON file at [path].
  ///
  /// A missing or empty file starts an empty map; an existing file is parsed
  /// as a `String -> String` JSON object. [mintId] overrides how new ids are
  /// generated (defaults to a random UUID v4) — primarily a test seam.
  static Future<FilePersonIdResolver> load(
    String path, {
    String Function()? mintId,
  }) async {
    final file = File(path);
    final map = <String, String>{};
    if (file.existsSync()) {
      final raw = await file.readAsString();
      if (raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) => map[key] = value as String);
      }
    }
    String defaultMint() => const Uuid().v4();
    return FilePersonIdResolver._(file, map, mintId ?? defaultMint);
  }

  @override
  PersonId resolve(String naturalKey) {
    final existing = _map[naturalKey];
    if (existing != null) {
      return PersonId(existing);
    }
    final minted = _mintId();
    _map[naturalKey] = minted;
    _persist();
    return PersonId(minted);
  }

  void _persist() {
    _file.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    _file.writeAsStringSync('${encoder.convert(_map)}\n');
  }
}
