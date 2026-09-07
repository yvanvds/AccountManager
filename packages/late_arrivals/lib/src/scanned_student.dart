import 'package:account_core/account_core.dart' as core;

/// One student as the reception desk sees them after a scan, together with the
/// two identifiers a Smartschool presence write needs (#401).
///
/// Assembled by `ScanResolver` from state that is already in memory, so the
/// desk never waits on the network for a name.
///
/// The two presence identifiers are nullable on purpose. A student whose record
/// yields a name but not an [internalUserId] or a [classGroupId] is a *known*
/// student the app cannot register by scanning, which is a different situation
/// from an unknown code and has a different remedy — see `ScanIncomplete` and
/// `ScanBlocker`.
class ScannedStudent {
  const ScannedStudent({
    required this.scanCode,
    required this.wisaId,
    required this.smartschoolUid,
    required this.displayName,
    this.personId,
    this.className = '',
    this.classCode,
    this.internalUserId,
    this.classGroupId,
  });

  /// The normalised code this student is indexed under — what a scan has to
  /// produce to reach them.
  final String scanCode;

  /// The WISA id verbatim, as Smartschool's `accountId` ("Internnummer") holds
  /// it. Displayed and logged; [scanCode] is what is matched.
  final String wisaId;

  /// The student's Smartschool username. Always present, and stable — the key
  /// to identify this student by in the journal (#402) when [personId] is not
  /// available.
  final String smartschoolUid;

  /// The linker's stable person id, when the caller could supply one.
  ///
  /// `null` in a session that has not linked: the id is minted by the linker
  /// and lives on the linked records, and the Smartschool snapshot the index is
  /// built from carries no person id of its own (#400). It is passed in rather
  /// than derived so this package stays a pure lookup over data it is handed.
  final core.PersonId? personId;

  /// Name to show at the desk: the roepnaam when Smartschool carries one, the
  /// given name otherwise, followed by the surname.
  final String displayName;

  /// The official class the student sits in, as Smartschool names it (`1A`).
  /// Empty when no official class membership was found.
  final String className;

  /// The Smartschool group code of that class (`SSM1A`). `null` when the
  /// student has no official class. Carried for the log line, never for the
  /// presence call.
  final core.GroupId? classCode;

  /// Smartschool's internal user id — the identifier the Presence module
  /// addresses a user by (#138). `null` when the account's
  /// `referenceIdentifier` is missing or malformed.
  final int? internalUserId;

  /// The Presence module's `groupID` for [className] — the connector's
  /// `Group.sourceId`, which is the same number (verified in #400).
  ///
  /// `null` when the class carries no `sourceId`: the connector harvests it
  /// from member payloads, so a class with no members anywhere stays
  /// unresolved. The name is still known in that case, which is why this is
  /// reported apart from an unknown code.
  final int? classGroupId;

  /// Whether a presence write can be addressed for this student — both
  /// identifiers present.
  bool get isRegisterable => internalUserId != null && classGroupId != null;

  @override
  String toString() => 'ScannedStudent($displayName, $className, '
      'uid: $smartschoolUid, userId: $internalUserId, '
      'classGroupId: $classGroupId)';
}
