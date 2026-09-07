/// Where the late-arrival journal actually lives on this machine (#402).
///
/// The journal itself is pure Dart in `packages/late_arrivals/`; this is the one
/// piece it deliberately does not own — the path. It sits beside
/// `preferences.json` and the token cache under `%APPDATA%\AccountManager\`, in
/// its own `late-arrivals\` subdirectory because there is one file per school
/// day and they would otherwise litter the root.
///
/// Plain JSON lines, unencrypted, for the same reason `preferences.json` is: a
/// name, a class and an arrival time are school data the operator already has on
/// screen, not a credential. Anything that *is* one belongs in the
/// DPAPI-encrypted token cache.
library;

import 'dart:convert';
import 'dart:io';

import 'package:late_arrivals/late_arrivals.dart';

/// The directory under `%APPDATA%\AccountManager\` the day files live in.
const String lateArrivalJournalDirectoryName = 'late-arrivals';

/// The production [JournalStore]: one append-only `.jsonl` file per school day.
class FileJournalStore implements JournalStore {
  FileJournalStore(this.directory);

  /// The journal directory, which need not exist yet — a desk that has never
  /// registered anybody has no files, which reads as an empty journal.
  final Directory directory;

  @override
  Future<List<SchoolDay>> days() async {
    if (!directory.existsSync()) return <SchoolDay>[];
    final List<SchoolDay> found = <SchoolDay>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final SchoolDay? day = schoolDayOfJournalFile(_baseName(entity.path));
      if (day != null) found.add(day);
    }
    found.sort((SchoolDay a, SchoolDay b) => a.compareTo(b));
    return found;
  }

  @override
  Future<String> read(SchoolDay day) async {
    final File file = _fileFor(day);
    if (!file.existsSync()) return '';
    // Read as bytes and decode leniently: a torn write can leave a partial
    // UTF-8 sequence in the tail, and a strict decode would throw away the whole
    // day over the one line the journal is already prepared to discard.
    return const Utf8Decoder(allowMalformed: true).convert(
      await file.readAsBytes(),
    );
  }

  @override
  Future<void> append(SchoolDay day, String line) async {
    final File file = _fileFor(day);
    await file.parent.create(recursive: true);
    // `flush: true` is the whole contract: this future must not complete until
    // the line is on the medium, because the ticket prints the moment it does.
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  @override
  Future<void> delete(SchoolDay day) async {
    final File file = _fileFor(day);
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Best effort: a locked file just means a rolled-off day lingers, which
      // costs disk space and nothing else.
    }
  }

  @override
  String locationOf(SchoolDay day) => _fileFor(day).path;

  File _fileFor(SchoolDay day) =>
      File('${directory.path}${Platform.pathSeparator}${journalFileName(day)}');

  static String _baseName(String path) {
    final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

/// The journal store for the machine this process is running on:
/// `%APPDATA%\AccountManager\late-arrivals\` on Windows, an in-memory one
/// anywhere APPDATA is absent — the same rule the token cache and
/// `preferences.json` follow.
///
/// The in-memory fallback keeps the journal's ordering and status model working
/// for the session; it just cannot survive a restart, which on a non-Windows
/// build is not a reception desk anyway.
JournalStore lateArrivalJournalStoreForThisMachine() {
  final String? appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null || appData.isEmpty) {
    return InMemoryJournalStore();
  }
  return FileJournalStore(
    Directory('$appData\\AccountManager\\$lateArrivalJournalDirectoryName'),
  );
}
