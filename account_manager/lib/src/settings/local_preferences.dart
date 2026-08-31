/// This operator's own working state on this machine (#394): the small,
/// remembered answers that make a repetitive job less repetitive.
///
/// Deliberately **not** the shared Cosmos settings document, and the line is
/// worth stating because almost everything else in this app is on the other
/// side of it. `AppSettings` is *school configuration*: the werkdatum, the WISA
/// import rules, the managed schools — decisions one operator makes on behalf of
/// every operator, which therefore have to be shared, versioned and visible in
/// Instellingen. What lives here is none of that. It is a convenience for the
/// person sitting in front of this install: the last uitschrijvingsdatum they
/// typed, so a departure batch does not mean typing it thirty times. Publishing
/// that to the whole school would make one operator's half-finished batch move
/// the default under a colleague's hands, which is the opposite of a
/// convenience.
///
/// It sits beside `connection.json` under `%APPDATA%\AccountManager\`, in the
/// same plain JSON and for the same reason: no secret ever goes in here. A
/// remembered date is not a credential, and anything that is one belongs in the
/// DPAPI-encrypted token cache or Key Vault.
///
/// **Adding a value.** This is a keyed bag on purpose, so a second unrelated
/// preference costs a key constant and a typed accessor pair and nothing else:
///
/// ```dart
/// static const String _somethingKey = 'something';
/// String? get something => _stringOf(_somethingKey);
/// Future<void> setSomething(String value) => _set(_somethingKey, value);
/// ```
///
/// An unknown key read by an older build is preserved rather than dropped —
/// [_set] writes the whole map back — so two builds sharing one machine cannot
/// erase each other's answers.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

/// The file this machine's working preferences live in, next to
/// `connection.json` under the same `%APPDATA%\AccountManager\` root.
const String localPreferencesFileName = 'preferences.json';

/// Where the preference bag is read and written.
///
/// A seam rather than a bare file so the app can be driven headlessly: a test
/// binds an [InMemoryLocalPreferenceStore] (or a temp-file
/// [FileLocalPreferenceStore]) and never touches the operator's real
/// `%APPDATA%`.
abstract interface class LocalPreferenceStore {
  /// Everything stored, or an empty map. **Never throws** — a missing, empty,
  /// or corrupt file reads as "nothing remembered", which is a state the app
  /// has to handle on every fresh install anyway. A working convenience must
  /// not be able to take a launch down.
  Future<Map<String, Object?>> read();

  /// Replaces the stored bag with [values]. Best effort: a failure to persist
  /// leaves the in-memory answer standing for this session rather than
  /// interrupting whatever the operator was doing.
  Future<void> write(Map<String, Object?> values);

  /// Where a [write] puts the values, as the operator should read it.
  String get location;
}

/// The production [LocalPreferenceStore]: a plain JSON object on disk.
class FileLocalPreferenceStore implements LocalPreferenceStore {
  FileLocalPreferenceStore(this.file);

  /// The preference file, which need not exist — an install that never wrote
  /// one reads as an install with nothing remembered.
  final File file;

  @override
  String get location => file.path;

  @override
  Future<Map<String, Object?>> read() async {
    try {
      if (!file.existsSync()) return <String, Object?>{};
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return <String, Object?>{};
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, Object?>{};
      return Map<String, Object?>.from(decoded);
    } on Object {
      // A convenience file that cannot be read is a convenience the operator
      // does without — never a failed launch. See the library doc.
      return <String, Object?>{};
    }
  }

  @override
  Future<void> write(Map<String, Object?> values) async {
    try {
      file.parent.createSync(recursive: true);
      const JsonEncoder encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString('${encoder.convert(values)}\n');
    } on Object {
      // Best effort — the session keeps its answer, the next launch forgets it.
    }
  }
}

/// A [LocalPreferenceStore] that keeps the bag in memory.
///
/// Two uses, and both matter: it is what tests bind so a headless run cannot
/// write to the operator's real `%APPDATA%`, and it is what a non-Windows (or
/// APPDATA-less) run falls back to — the remembered value then lives for the
/// session, which is still better than nothing and never worse.
class InMemoryLocalPreferenceStore implements LocalPreferenceStore {
  InMemoryLocalPreferenceStore([Map<String, Object?>? stored])
      : _values = <String, Object?>{...?stored};

  Map<String, Object?> _values;

  @override
  String get location =>
      '$localPreferencesFileName (niet bewaard op deze machine)';

  @override
  Future<Map<String, Object?>> read() async => Map<String, Object?>.from(
        _values,
      );

  @override
  Future<void> write(Map<String, Object?> values) async {
    _values = Map<String, Object?>.from(values);
  }
}

/// The preference store for the machine this process is running on:
/// `%APPDATA%\AccountManager\preferences.json` on Windows, an in-memory one
/// anywhere APPDATA is absent — the same rule the token cache and
/// `connection.json` follow.
LocalPreferenceStore localPreferenceStoreForThisMachine() {
  final String? appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null || appData.isEmpty) {
    return InMemoryLocalPreferenceStore();
  }
  return FileLocalPreferenceStore(
    File('$appData\\AccountManager\\$localPreferencesFileName'),
  );
}

/// The loaded bag, with a typed accessor per remembered value.
///
/// Read synchronously and written through: [load] is awaited once during the
/// launch, so every screen afterwards can ask what is remembered without an
/// await in the middle of a build, while a setter persists in the background.
class LocalPreferences {
  LocalPreferences(this.store);

  /// A preference set that remembers only for this session — the default for a
  /// test, and for any build with nowhere to write.
  LocalPreferences.inMemory() : store = InMemoryLocalPreferenceStore();

  /// Where the values are persisted.
  final LocalPreferenceStore store;

  Map<String, Object?> _values = <String, Object?>{};

  /// Loads the stored bag. Awaited once, during the launch.
  Future<void> load() async {
    _values = await store.read();
  }

  // --- the remembered values -------------------------------------------------

  /// The last **uitschrijvingsdatum** the operator applied with (#394).
  ///
  /// `null` on a fresh install with nothing remembered, and the prompt then
  /// offers today. Today is the honest default — it is what the operator would
  /// pick on the day a student actually leaves — even though it is also exactly
  /// the value the app used to supply silently. The difference is that it is now
  /// on screen, in a field the operator has to look at, instead of being decided
  /// for them by the clock.
  DateTime? get lastDeletionDate {
    final Object? raw = _values[_lastDeletionDateKey];
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  /// Remembers [value] as the uitschrijvingsdatum for the next prompt.
  ///
  /// Stored date-only: the operator answers a day, not a moment, and a stored
  /// midnight-plus-nine-hours would come back as a subtly different default.
  Future<void> setLastDeletionDate(DateTime value) => _set(
        _lastDeletionDateKey,
        DateTime(value.year, value.month, value.day).toIso8601String(),
      );

  static const String _lastDeletionDateKey = 'lastDeletionDate';

  /// The version whose release notes this machine has already been shown
  /// (#395), as the plain `X.Y.Z` text the tag parser reads back.
  ///
  /// Machine-local for the same reason the date above is, and the reason is
  /// sharper here: "what's new" is a thing one *person* has read. Put this in
  /// the shared Cosmos settings document and the first operator to close the
  /// dialog closes it for every colleague who has not seen it yet.
  ///
  /// `null` means this install has never recorded one — which the update layer
  /// treats as a **fresh install to seed**, not as a version to announce. See
  /// [UpdateController.start].
  String? get releaseNotesSeenVersion {
    final Object? raw = _values[_releaseNotesSeenVersionKey];
    return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
  }

  /// Records [version] as the last release whose notes this machine has seen.
  Future<void> setReleaseNotesSeenVersion(String version) =>
      _set(_releaseNotesSeenVersionKey, version.trim());

  static const String _releaseNotesSeenVersionKey = 'releaseNotesSeenVersion';

  // --- the bag ---------------------------------------------------------------

  /// Sets one key and persists the **whole** bag, so a key this build does not
  /// know about survives (see the library doc).
  Future<void> _set(String key, Object? value) {
    _values = <String, Object?>{..._values, key: value};
    return store.write(_values);
  }
}

/// Hands the [LocalPreferences] of this launch to whatever needs it, without
/// threading it through every screen in between.
///
/// The apply confirmation is four widgets deep in two different screens and is
/// reached from a free function; an inherited scope is what keeps that from
/// becoming a parameter on everything along the way. Absent — which is what a
/// widget test pumping one screen gets — [maybeOf] answers `null` and the
/// caller falls back to remembering nothing, exactly as the app behaved before
/// this existed.
class LocalPreferencesScope extends InheritedWidget {
  const LocalPreferencesScope({
    super.key,
    required this.preferences,
    required super.child,
  });

  /// The loaded preferences of this launch.
  final LocalPreferences preferences;

  /// The enclosing scope's preferences, or `null` when there is none.
  static LocalPreferences? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LocalPreferencesScope>()
      ?.preferences;

  @override
  bool updateShouldNotify(LocalPreferencesScope oldWidget) =>
      !identical(preferences, oldWidget.preferences);
}
