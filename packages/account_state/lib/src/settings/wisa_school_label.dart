import 'package:wisa_api/wisa_api.dart' as wapi;

import 'wisa_school_profile.dart';

// How a WISA school is named for a human — the one place that knows it (#204).
//
// A school has two halves: the long descriptive name ("Instituut Sancta
// Maria-A") and the short code operators use day to day (`ISMAA`). Both
// `WisaSchool` and `WisaSchoolProfile` now name those halves honestly — `name`
// is the long one, `code` the short one — because `parseSchoolRow` untangles
// WISA's inverted `NAME`/`DESCRIPTION` columns at the connector edge (#208).
//
// Every view that names a school routes through here — the Settings grid, the
// Actions drill-down, and the label baked into the materialized documents — so
// the two can never drift into showing different halves of the same pair.

/// The full single-line label for one school: `"<naam> (<code>)"`, degrading to
/// whichever half is known and finally to `School <id>` when neither is.
///
/// [code] is the short code (`ISMAA`), [name] the long name ("Instituut Sancta
/// Maria-A"). The `School <id>` form is the **last resort** for an id that
/// matches no known school — never the normal rendering.
String wisaSchoolLabel({
  required int schoolId,
  String code = '',
  String name = '',
}) {
  final String c = code.trim();
  final String n = name.trim();
  if (n.isNotEmpty && c.isNotEmpty) return '$n ($c)';
  if (n.isNotEmpty) return n;
  if (c.isNotEmpty) return c;
  return 'School $schoolId';
}

/// The lead label for one school: the long [name] when known, else the short
/// [code], else `School <id>`.
///
/// What the Settings grid leads each cell with, with the short code as the
/// second line rather than a parenthetical (#194, corrected in #208 — the grid
/// always *showed* the long name first; before the fix it got there by leading
/// with a `code` field that actually held the long name).
String wisaSchoolNameLabel({
  required int schoolId,
  String code = '',
  String name = '',
}) {
  final String n = name.trim();
  if (n.isNotEmpty) return n;
  final String c = code.trim();
  if (c.isNotEmpty) return c;
  return 'School $schoolId';
}

/// The school-id → display-label map the materializer bakes into its documents.
///
/// Merges the operator-curated [profiles] persisted in the settings document
/// (available without any WISA pull, so a passive session labels schools too)
/// with the live snapshot [schools] of the session's WISA pull. The merge is
/// per half rather than per school: a fresh pull refreshes whichever of the two
/// halves it actually carries and never blanks the other one out of a stored
/// profile — the same rule the Settings grid merges a fetch with.
Map<int, String> wisaSchoolLabels({
  Iterable<WisaSchoolProfile> profiles = const <WisaSchoolProfile>[],
  Iterable<wapi.WisaSchool> schools = const <wapi.WisaSchool>[],
}) {
  final codes = <int, String>{};
  final names = <int, String>{};
  void put(int id, String code, String name) {
    if (code.trim().isNotEmpty) codes[id] = code.trim();
    if (name.trim().isNotEmpty) names[id] = name.trim();
  }

  for (final p in profiles) {
    put(p.schoolId, p.code, p.name);
  }
  // The live pull wins where it has something to say — a WISA-side rename must
  // show this session, not only after the operator re-fetches in Settings.
  for (final s in schools) {
    put(s.id, s.code, s.name);
  }

  return <int, String>{
    for (final id in <int>{...codes.keys, ...names.keys})
      id: wisaSchoolLabel(
        schoolId: id,
        code: codes[id] ?? '',
        name: names[id] ?? '',
      ),
  };
}

/// The display labels of one persisted school profile.
extension WisaSchoolProfileLabel on WisaSchoolProfile {
  /// The full single-line label — `"<naam> (<code>)"` — as the Actions
  /// drill-down names this school.
  String get label =>
      wisaSchoolLabel(schoolId: schoolId, code: code, name: name);

  /// The lead label the Settings grid puts at the top of this school's cell,
  /// with the short code beneath it.
  String get nameLabel =>
      wisaSchoolNameLabel(schoolId: schoolId, code: code, name: name);
}
