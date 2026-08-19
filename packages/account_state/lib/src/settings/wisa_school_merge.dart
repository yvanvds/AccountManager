import 'package:wisa_api/wisa_api.dart' as wapi;

import 'wisa_school_profile.dart';

// How a freshly pulled WISA school list is folded into the persisted school
// profiles — the one place that knows the rule (#207).
//
// Two callers merge the same two things and must not drift apart:
//
// - **Scholen ophalen** in Settings, which refreshes the grid and may add a
//   school the operator has never seen ([addUnknown]);
// - every **sync**, which repairs the stored profiles from the school list the
//   pull already loaded, so the grid never renders `School 25` again just
//   because the document predates the `code`/`name` fields (#171/#194).
//
// The rule itself is per half rather than per school, exactly as
// `wisaSchoolLabels` merges a snapshot over the stored profiles: the pull
// refreshes whichever of the two halves it actually carries and never blanks
// out the other.

/// Merges the freshly pulled [schools] into the persisted [profiles], filling
/// in each profile's `code` and `name` from the school with its id.
///
/// **Only those two halves are touched.** `ours`, `virtual` and `prefix` are
/// operator decisions and are carried through untouched — a repair must never
/// silently un-manage a school. A pulled half that is empty leaves the stored
/// one alone, so a partial pull cannot blank a known name.
///
/// By default the merge is strictly a repair: no entry is added and none is
/// removed, and the order of [profiles] is preserved, so a sync can run it
/// against the settings document without the grid growing or reordering behind
/// the operator's back. With [addUnknown] — what the **Scholen ophalen** button
/// does — a pulled school that has no profile yet is appended as neither
/// managed nor virtual.
///
/// Both halves come straight across: `parseSchoolRow` untangles WISA's inverted
/// `NAME`/`DESCRIPTION` columns at the connector edge, so `WisaSchool.name` is
/// the long name and `WisaSchool.code` the short code (#208).
List<WisaSchoolProfile> mergeWisaSchoolProfiles({
  required Iterable<WisaSchoolProfile> profiles,
  required Iterable<wapi.WisaSchool> schools,
  bool addUnknown = false,
}) {
  final byId = <int, wapi.WisaSchool>{for (final s in schools) s.id: s};
  final merged = <WisaSchoolProfile>[
    for (final p in profiles) _enriched(p, byId[p.schoolId]),
  ];
  if (!addUnknown) return merged;

  final known = <int>{for (final p in profiles) p.schoolId};
  for (final s in schools) {
    if (known.add(s.id)) {
      merged.add(WisaSchoolProfile(
        schoolId: s.id,
        code: s.code.trim(),
        name: s.name.trim(),
      ));
    }
  }
  return merged;
}

/// [profile] with whichever halves [school] actually carries filled in, and
/// every operator-owned field left as it was.
WisaSchoolProfile _enriched(
    WisaSchoolProfile profile, wapi.WisaSchool? school) {
  if (school == null) return profile;
  final String code = school.code.trim();
  final String name = school.name.trim();
  if (code.isEmpty && name.isEmpty) return profile;
  return profile.copyWith(
    code: code.isEmpty ? profile.code : code,
    name: name.isEmpty ? profile.name : name,
  );
}
