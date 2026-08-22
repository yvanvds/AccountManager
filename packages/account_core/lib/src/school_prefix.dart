/// INV-22 — the one definition of "this Azure account is one of ours".
///
/// The school stamps its own prefix on its Office 365 accounts, but stamps it
/// in two different shapes, so the rule has two halves:
///
/// - a **student** is an exact `companyName` match. We write that field
///   ourselves and write nothing else into it, so equality is the whole test.
/// - a **staff member** is a `department` that *contains* the prefix. That
///   field is **not ours to write** (#237): other software maintains it as a
///   comma-separated list of every school prefix the teacher is currently
///   active at (`SSM,GBS`), and our prefix sitting second in that list is the
///   ordinary state, not an edge case.
///
/// Both halves trim and case-fold first (INV-12): a prefix is typed by an
/// operator in Instellingen and a `department` list is typed by whoever
/// maintains it elsewhere, so neither is trustworthy about whitespace or case.
///
/// **A blank prefix matches nobody.** Every string contains the empty string,
/// so a `contains` test against an unconfigured prefix would claim the entire
/// tenant belongs to us — the opposite of what an unconfigured prefix means.
///
/// ## Why this lives here
///
/// This rule is asked twice, from opposite ends of the pipeline: the linker
/// asks it to decide whether an unmatched Azure row is kept as an orphan
/// record, and the Azure connector asks it to decide whether a row it just
/// read is kept at all. Those two answers must agree, and the asymmetry of
/// disagreeing is what makes a shared definition worth the indirection: a read
/// **wider** than the linker is merely wasteful (the linker drops the extra
/// rows a moment later), while a read **narrower** than the linker is silently
/// lossy — the linker never gets to ask about a row the read already threw
/// away, and nothing anywhere reports a row that never arrived.
///
/// Only one of those two failure modes is visible, which is exactly why the
/// copies drifted for as long as they did: the connector tested
/// `startsWith(department, prefix)` while the linker tested `contains` until
/// #268, so every staff member listed second was dropped by the read. #279
/// folded the copies into this one predicate so the next change to the rule
/// cannot reach one caller and miss the other.
///
/// Note this is a *domain* rule about the values, not a Graph query: the
/// server-side `$filter` in `UserManager.filterFor` is deliberately narrower
/// (Graph offers no `contains` on these properties) and is completed by the
/// `employeeId` back-fill rather than by widening. Every leg that filters in
/// Dart calls this instead.
library;

/// Whether an Azure account's [companyName] marks it as one of the school's
/// own **students** — a current or former one (INV-22).
///
/// Exact match after trimming and case-folding. `null`/blank on either side
/// matches nothing.
bool studentBelongsToSchool(String? companyName, String? schoolPrefix) {
  final company = _fold(companyName);
  final prefix = _fold(schoolPrefix);
  return company != null && prefix != null && company == prefix;
}

/// Whether an Azure account's [department] marks it as one of the school's own
/// **staff** — a current or former one (INV-22).
///
/// A *substring* test, not a prefix one: `department` is the comma-separated
/// list of schools other software maintains (#237), so our prefix may sit
/// anywhere in it. Trimmed and case-folded; `null`/blank on either side matches
/// nothing.
bool staffBelongsToSchool(String? department, String? schoolPrefix) {
  final dept = _fold(department);
  final prefix = _fold(schoolPrefix);
  return dept != null && prefix != null && dept.contains(prefix);
}

/// Whether an Azure account belongs to the school under **either** half of
/// INV-22 — the question a bulk read asks, which cannot yet tell a student row
/// from a staff row.
///
/// This is the union of [studentBelongsToSchool] and [staffBelongsToSchool], so
/// it is exactly as wide as the linker: every row the linker would keep as an
/// orphan survives the read that uses this, and the linker still applies the
/// *specific* half when it decides which population the row joins.
bool belongsToSchool({
  String? companyName,
  String? department,
  required String? schoolPrefix,
}) =>
    studentBelongsToSchool(companyName, schoolPrefix) ||
    staffBelongsToSchool(department, schoolPrefix);

/// Trims and lower-cases [value] for the comparisons above (INV-12), returning
/// `null` for a null or blank string so an empty value never matches.
String? _fold(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed.toLowerCase();
}
