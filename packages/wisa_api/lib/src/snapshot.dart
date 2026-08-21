import 'dart:collection';

import 'package:account_core/account_core.dart' as core;

import 'models/wisa_class_group.dart';
import 'models/wisa_school.dart';
import 'models/wisa_staff.dart';
import 'models/wisa_student.dart';

/// Immutable result of one WISA sync.
///
/// Spec: `docs/domain-model.md` §3.8. All exposed lists are
/// [UnmodifiableListView]s — handing the snapshot to the linker is safe.
class WisaSnapshot implements core.Snapshot {
  @override
  final DateTime fetchedAt;

  @override
  core.Origin get origin => core.Origin.wisa;

  /// The **werkdatum** this roster was pulled as of — the `Werkdatum` SOAP
  /// parameter the row queries went out with (#247).
  ///
  /// WISA answers *as of* a date, so the roster is only meaningful together
  /// with it: a pull made on the wrong side of the school-year rollover simply
  /// has none of the new intake in it. [fetchedAt] says when we asked, this
  /// says which school year we asked about — and the two routinely disagree.
  ///
  /// Null on a snapshot no [WisaConnector.sync] stamped: a hand-built fixture,
  /// or one restored from a `snapshots` document written before this existed.
  /// A virtual school's rows come from the *virtuele* werkdatum instead; this
  /// is the ordinary one, the same date [WisaConnector.sync] gives every
  /// non-virtual school.
  final DateTime? workDate;

  final UnmodifiableListView<WisaStudent> students;
  final UnmodifiableListView<WisaStaff> staff;
  final UnmodifiableListView<WisaClassGroup> classGroups;
  final UnmodifiableListView<WisaSchool> schools;

  WisaSnapshot({
    required this.fetchedAt,
    required List<WisaStudent> students,
    required List<WisaStaff> staff,
    required List<WisaClassGroup> classGroups,
    required List<WisaSchool> schools,
    this.workDate,
  })  : students = UnmodifiableListView(List.of(students)),
        staff = UnmodifiableListView(List.of(staff)),
        classGroups = UnmodifiableListView(List.of(classGroups)),
        schools = UnmodifiableListView(List.of(schools));

  /// Serializes the whole snapshot to a JSON-encodable map. Round-trips with
  /// [WisaSnapshot.fromJson] — the payload form the cold `snapshots` store
  /// persists so a fresh session seeds from the store instead of re-pulling
  /// WISA (#107).
  Map<String, dynamic> toJson() => {
        'fetchedAt': fetchedAt.toIso8601String(),
        if (workDate != null) 'workDate': workDate!.toIso8601String(),
        'students': [for (final s in students) s.toJson()],
        'staff': [for (final s in staff) s.toJson()],
        'classGroups': [for (final g in classGroups) g.toJson()],
        'schools': [for (final s in schools) s.toJson()],
      };

  factory WisaSnapshot.fromJson(Map<String, dynamic> json) => WisaSnapshot(
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
        workDate: json['workDate'] == null
            ? null
            : DateTime.parse(json['workDate'] as String),
        students: [
          for (final e in (json['students'] as List<dynamic>? ?? const []))
            WisaStudent.fromJson(e as Map<String, dynamic>),
        ],
        staff: [
          for (final e in (json['staff'] as List<dynamic>? ?? const []))
            WisaStaff.fromJson(e as Map<String, dynamic>),
        ],
        classGroups: [
          for (final e in (json['classGroups'] as List<dynamic>? ?? const []))
            WisaClassGroup.fromJson(e as Map<String, dynamic>),
        ],
        schools: [
          for (final e in (json['schools'] as List<dynamic>? ?? const []))
            WisaSchool.fromJson(e as Map<String, dynamic>),
        ],
      );
}
