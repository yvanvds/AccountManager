import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart' as ss;

import 'scan_code.dart';
import 'scan_result.dart';
import 'scanned_student.dart';

/// Turns a code scanned at the reception desk into the student behind it and
/// the Smartschool Presence target a late-arrival registration needs (#401).
///
/// **Built once, queried per scan.** Construction walks the snapshot and builds
/// a hash index; [resolve] is a constant-time lookup, because the desk has a
/// queue of students waiting and the name has to appear the instant the scanner
/// beeps. Nothing here touches the network — that is the point of the whole
/// layer (see epic #399).
///
/// **Why the Smartschool snapshot and not the materialized view.** The two
/// identifiers a presence write needs are only there: `accountId`
/// ("Internnummer") holds the student's WISA id by operator convention and is
/// what the card encodes, and `referenceIdentifier` yields the internal user id
/// the Presence module addresses users by (#138). Neither is carried by
/// `MaterializedAccount` or by the narrow `core.SmartschoolAccount` interface,
/// so #400 settled the chain as: scanned code → `SmartschoolAccount.accountId`
/// → `internalUserId`, read off the snapshot every session seeds at launch. The
/// class target comes from the same snapshot: `core.Group.sourceId` **is** the
/// Presence module's `groupID` (verified in #400 — `SSM1A` is `298` on both
/// sides), so it is passed straight through with no mapping table.
///
/// The snapshot is handed in rather than reached for: this package is pure Dart
/// and knows nothing about application state or where a snapshot comes from.
class ScanResolver {
  ScanResolver._(this._byCode, this._ambiguous);

  /// Indexes every **student** account of [snapshot] by its scannable code.
  ///
  /// Staff and any account whose Smartschool `Basisrol` did not map to a role
  /// are left out: a colleague's card scanned at the desk is an unknown code,
  /// not a late arrival. So is an account with a blank `accountId`, which
  /// carries no scannable code at all.
  ///
  /// [personIdsByUid] optionally supplies the linker's stable person id per
  /// Smartschool username, for callers that have linked this session. It is an
  /// input rather than a lookup this package performs, because person ids are
  /// minted by the linker and a session reading only the shared materialized
  /// state has none to give — [ScannedStudent.smartschoolUid] identifies the
  /// student in that case.
  factory ScanResolver.fromSmartschool(
    ss.SmartschoolSnapshot snapshot, {
    Map<String, core.PersonId> personIdsByUid = const {},
  }) {
    final groupsById = <core.GroupId, core.Group>{
      for (final group in snapshot.groups) group.id: group,
    };
    final officialClassByUid = _officialClassesByUid(
      snapshot.memberships,
      groupsById,
    );

    final byCode = <String, ScannedStudent>{};
    final ambiguous = <String, List<String>>{};

    for (final account in snapshot.accounts) {
      if (account.role != core.PersonRole.student) continue;
      final code = normalizeScanCode(account.accountId);
      if (code.isEmpty) continue;

      final existing = byCode[code];
      if (existing != null) {
        // Keep the first, but stop answering for this code at all: the desk
        // must not mark one of two students present on a coin flip.
        ambiguous
            .putIfAbsent(code, () => <String>[existing.smartschoolUid])
            .add(account.uid);
        continue;
      }

      final classGroup = officialClassByUid[account.uid];
      byCode[code] = ScannedStudent(
        scanCode: code,
        wisaId: account.accountId,
        smartschoolUid: account.uid,
        personId: personIdsByUid[account.uid],
        displayName: _displayName(account),
        className: classGroup?.name.trim() ?? '',
        classCode: classGroup?.id,
        internalUserId: account.internalUserId,
        classGroupId: classGroup?.sourceId,
      );
    }

    return ScanResolver._(byCode, ambiguous);
  }

  final Map<String, ScannedStudent> _byCode;
  final Map<String, List<String>> _ambiguous;

  /// How many students the desk can resolve — every indexed account, including
  /// those that turn out not to be registerable.
  int get studentCount => _byCode.length;

  /// The scannable codes carried by more than one student, in index order.
  /// Empty in a healthy tenant; exposed so a session can report the collision
  /// once at startup instead of only when somebody scans into it.
  Iterable<String> get ambiguousCodes => _ambiguous.keys;

  /// Resolves one scan. Constant time; never throws.
  ///
  /// [rawScan] is the burst exactly as the scanner typed it, terminator and
  /// all — [normalizeScanCode] strips that here rather than at every call site.
  ScanResult resolve(String rawScan) {
    final code = normalizeScanCode(rawScan);
    if (code.isEmpty) return const ScanEmpty();

    final collisions = _ambiguous[code];
    if (collisions != null) {
      return ScanAmbiguous(
        code: code,
        smartschoolUids: List.unmodifiable(collisions),
      );
    }

    final student = _byCode[code];
    if (student == null) return ScanUnknown(code);

    final blockers = <ScanBlocker>{
      if (student.internalUserId == null) ScanBlocker.noInternalUserId,
      if (student.className.isEmpty)
        ScanBlocker.noOfficialClass
      else if (student.classGroupId == null)
        ScanBlocker.noClassGroupId,
    };
    return blockers.isEmpty
        ? ScanRegisterable(student)
        : ScanIncomplete(
            student: student, blockers: Set.unmodifiable(blockers));
  }
}

/// The official class each account sits in, keyed by Smartschool username.
///
/// Memberships are one row per (account, group) pair — multi-membership is
/// preserved, not deduplicated (PAIN-1) — so an account reaches here through
/// several groups and only the official ones are classes. INV-31 allows at most
/// one official class per student, but nothing in the connector enforces it, so
/// a tie is broken on the normalized class name: whichever record the desk
/// shows, it shows the same one on every scan and in every session.
Map<String, core.Group> _officialClassesByUid(
  Iterable<ss.SmartschoolMembership> memberships,
  Map<core.GroupId, core.Group> groupsById,
) {
  final byUid = <String, core.Group>{};
  for (final membership in memberships) {
    if (membership.accountType != core.AccountType.student) continue;
    final group = groupsById[membership.groupId];
    if (group == null || !group.official) continue;

    final held = byUid[membership.uid];
    if (held == null ||
        _classSortKey(group).compareTo(_classSortKey(held)) < 0) {
      byUid[membership.uid] = group;
    }
  }
  return byUid;
}

/// Deterministic ordering key for a tie between two official classes: the
/// normalized name, falling back to the group code when a name is blank.
String _classSortKey(core.Group group) =>
    core.normalizeGroupName(group.name) ?? group.id.value.toLowerCase();

/// The name to put on screen: the roepnaam Smartschool carries when there is
/// one — it is what the student answers to, and the desk is a spoken exchange —
/// the given name otherwise, then the surname. Falls back to the username when
/// the record carries no name at all.
String _displayName(ss.SmartschoolAccount account) {
  final first = account.preferredName.trim().isNotEmpty
      ? account.preferredName.trim()
      : account.givenName.trim();
  final full = '$first ${account.surname.trim()}'.trim();
  return full.isEmpty ? account.uid : full;
}
