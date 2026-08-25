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
/// ## The Azure profile is output, never input (#359)
///
/// INV-22 is the one thing the app ever *reads* out of an Azure profile field,
/// and it reads exactly one bit: "is this account one of ours?". Nothing else
/// may be inferred from those fields — not a class, not a school level, not an
/// entitlement. **Always resolve a student against WISA first.**
///
/// `companyName`, `department` and `jobTitle` are values *we* stamp on a student
/// account, and nothing outside this app maintains them. A stamp is only ever as
/// fresh as the last pass that wrote it, so reading a class back out of
/// `department` answers with the class the pupil sat in when the account was
/// made — which in the live tenant means basisschool class names on pupils who
/// are now in secondary. The same holds for deriving the *kind* of pupil from
/// `companyName`: our prefix says which school an account belongs to, never what
/// its holder is (#358).
///
/// So the direction is fixed: WISA decides, and the Azure fields are written to
/// follow it (`ModifyAzureSchool`, `ModifyAzureJobTitle`, `ModifyAzureDepartment`
/// in `account_actions`, all three reachable only from the student dispatch's
/// modify branch, which requires a WISA row of ours). A code path that wants a
/// student's class asks `WisaStudent.classGroup`.
///
/// Staff are the exception that proves it: their `department` is not ours at all
/// (#237), so it is neither read for anything but INV-22 nor written except to
/// strike our own claim out of it (see [departmentSchoolsExcept]).
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

/// The individual school prefixes an Azure staff account's [department] lists,
/// in the order they appear, trimmed, with blank entries dropped (#349).
///
/// The original casing is preserved: this is the field's own content, and the
/// only writer entitled to touch it rewrites it from these very items (see
/// [departmentSchoolsExcept]).
List<String> departmentSchools(String? department) => <String>[
      for (final part in (department ?? '').split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];

/// [departmentSchools] minus every entry that **is** [schoolPrefix] — the other
/// schools of the group that still claim this staff member (#349).
///
/// Empty means nobody but us claims them, which is the one condition under
/// which their Office 365 account may be deleted rather than merely released.
///
/// **An exact item match, deliberately unlike [staffBelongsToSchool]'s
/// `contains`.** The two are asymmetric on purpose: a read that is too wide only
/// keeps a row the linker drops a moment later, while a *write* that is too wide
/// destroys a sibling school's claim in a field we do not own. `SSM` must not
/// match inside a longer school code here, and that is exactly the failure mode
/// #237 removed `ModifyStaffAzureSchool` for — it collapsed `GBS,SSM` to a bare
/// `SSM`. Releasing our own entry is the only edit to this field we are entitled
/// to make, so it is the only one this expresses.
List<String> departmentSchoolsExcept(String? department, String? schoolPrefix) {
  final prefix = _fold(schoolPrefix);
  if (prefix == null) return departmentSchools(department);
  return <String>[
    for (final school in departmentSchools(department))
      if (_fold(school) != prefix) school,
  ];
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
