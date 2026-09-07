import 'scanned_student.dart';

/// What one scan produced (#401).
///
/// Sealed, so every consumer — the desk UI (#407) above all — is made to answer
/// each outcome separately. The whole point of the split is that the remedies
/// differ: an unknown code sends the operator to Smartschool to enter the
/// absence by hand, while a known student the app cannot address is a data
/// problem somebody has to repair.
sealed class ScanResult {
  const ScanResult();
}

/// Nothing was scanned — the burst held only scanner noise (a stray Enter).
///
/// Distinct from [ScanUnknown] so the desk stays silent instead of announcing
/// an unknown student nobody scanned.
final class ScanEmpty extends ScanResult {
  const ScanEmpty();

  @override
  String toString() => 'ScanEmpty()';
}

/// No indexed student carries this code.
///
/// The epic's "leerling onbekend": the operator enters the absence in
/// Smartschool by hand and the case is reviewed afterwards.
final class ScanUnknown extends ScanResult {
  const ScanUnknown(this.code);

  /// The normalised code that matched nothing.
  final String code;

  @override
  String toString() => 'ScanUnknown($code)';
}

/// More than one indexed student carries this code.
///
/// `accountId` is an operator-maintained convention, not a Smartschool
/// constraint, so nothing guarantees it is unique. Registering "whichever came
/// first" would silently mark the wrong student present, so the resolver
/// refuses and says so.
final class ScanAmbiguous extends ScanResult {
  const ScanAmbiguous({required this.code, required this.smartschoolUids});

  /// The normalised code that matched several students.
  final String code;

  /// The Smartschool usernames carrying it, in index order — enough for the
  /// operator (or a log line) to name the records that need untangling.
  final List<String> smartschoolUids;

  @override
  String toString() => 'ScanAmbiguous($code, ${smartschoolUids.join(", ")})';
}

/// The student is known — name and class can be shown — but the app cannot
/// address a presence write for them.
///
/// The distinction this issue exists to make: the desk can tell the student who
/// they are and still has to fall back to a manual registration, and the
/// [blockers] say which repair is needed.
final class ScanIncomplete extends ScanResult {
  const ScanIncomplete({required this.student, required this.blockers});

  final ScannedStudent student;

  /// Why the registration cannot be addressed. Never empty.
  final Set<ScanBlocker> blockers;

  @override
  String toString() => 'ScanIncomplete(${student.displayName}, $blockers)';
}

/// The student is known and a presence write can be addressed for them.
final class ScanRegisterable extends ScanResult {
  const ScanRegisterable(this.student);

  final ScannedStudent student;

  /// Smartschool's internal user id for this student — non-null by
  /// construction.
  int get internalUserId => student.internalUserId!;

  /// The Presence module's `groupID` for this student's class — non-null by
  /// construction.
  int get classGroupId => student.classGroupId!;

  @override
  String toString() => 'ScanRegisterable(${student.displayName}, '
      '${student.className})';
}

/// Why a known student cannot be registered by scanning.
enum ScanBlocker {
  /// The Smartschool account carries no usable `referenceIdentifier`, so there
  /// is no internal user id to address (#138). Measured at zero on this tenant
  /// (#400), but the parser is allowed to return `null` and the desk must not
  /// crash if it ever does.
  noInternalUserId,

  /// The student holds no official class membership at all, so there is no
  /// class to register the arrival against.
  noOfficialClass,

  /// The student's class is known **by name** but carries no `sourceId`, so the
  /// Presence module's `groupID` for it is unknown.
  ///
  /// Deliberately apart from [noOfficialClass]: the operator sees a class on
  /// screen and would otherwise read the refusal as a bug. The cause is a class
  /// no member payload has ever named, which resolves itself the moment one
  /// student is enrolled in it (#400).
  noClassGroupId,
}
