import 'school_day.dart';

/// Where the journal's day files live (#402).
///
/// A seam rather than a bare directory, for the same reason
/// `LocalPreferenceStore` is one: this package is pure Dart and must be testable
/// without touching a real filesystem, while the concrete on-disk location is an
/// application concern and is wired up in `account_manager/`.
///
/// **The one contract that matters.** [append] must not complete until the line
/// is on the storage medium — flushed, not buffered. Everything the journal
/// promises rests on that: the ticket prints only after [append] returns, so an
/// implementation that returns early turns a printed ticket into a student who
/// can vanish in a crash.
abstract interface class JournalStore {
  /// Every day that has a file, ascending. A day with no file is simply absent.
  Future<List<SchoolDay>> days();

  /// The whole of [day]'s file, verbatim — including a trailing partial line
  /// left by a crash, which the reader is responsible for discarding. `''` when
  /// there is no file.
  Future<String> read(SchoolDay day);

  /// Appends [line] to [day]'s file, creating it if needed, and completes only
  /// once it is durable. [line] arrives newline-terminated; write it verbatim.
  Future<void> append(SchoolDay day, String line);

  /// Removes [day]'s file. Called for a rolled-off day; a missing file is not
  /// an error.
  Future<void> delete(SchoolDay day);

  /// Where [day]'s records are kept, as a support question should be answered.
  String locationOf(SchoolDay day);
}

/// The journal file name for [day]. Pinned here, in the pure package, so the
/// on-disk layout stays one decision even though the directory is chosen by the
/// app.
String journalFileName(SchoolDay day) => 'late-arrivals-${day.id}.jsonl';

/// The day [fileName] holds, or `null` when it is not a journal file — a README
/// or an editor's backup dropped in the directory, which must be ignored rather
/// than parsed.
SchoolDay? schoolDayOfJournalFile(String fileName) {
  const String prefix = 'late-arrivals-';
  const String suffix = '.jsonl';
  if (!fileName.startsWith(prefix) || !fileName.endsWith(suffix)) return null;
  return SchoolDay.tryParse(
    fileName.substring(prefix.length, fileName.length - suffix.length),
  );
}

/// A [JournalStore] that keeps the day files in memory.
///
/// What a test binds so a headless run never writes to the operator's real
/// `%APPDATA%`, and the fallback for a build with nowhere to write — where the
/// journal then guarantees ordering and recovery *within* the session, which is
/// still strictly better than an unordered list and never worse.
class InMemoryJournalStore implements JournalStore {
  InMemoryJournalStore([Map<SchoolDay, String>? stored])
      : _files = <SchoolDay, String>{...?stored};

  final Map<SchoolDay, String> _files;

  @override
  Future<List<SchoolDay>> days() async =>
      _files.keys.toList()..sort((SchoolDay a, SchoolDay b) => a.compareTo(b));

  @override
  Future<String> read(SchoolDay day) async => _files[day] ?? '';

  @override
  Future<void> append(SchoolDay day, String line) async {
    _files[day] = (_files[day] ?? '') + line;
  }

  @override
  Future<void> delete(SchoolDay day) async {
    _files.remove(day);
  }

  @override
  String locationOf(SchoolDay day) =>
      '${journalFileName(day)} (niet bewaard op deze machine)';
}
