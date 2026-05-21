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
  })  : students = UnmodifiableListView(List.of(students)),
        staff = UnmodifiableListView(List.of(staff)),
        classGroups = UnmodifiableListView(List.of(classGroups)),
        schools = UnmodifiableListView(List.of(schools));
}
