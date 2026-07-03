import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

final DateTime _first = DateTime.utc(2026, 7, 1);
final DateTime _second = DateTime.utc(2026, 7, 2);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

WisaStudent _student({
  String wisaId = 'W1',
  String firstName = 'Jan',
  String classGroup = '3A',
}) =>
    WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '00',
      name: 'Peeters',
      firstName: firstName,
      preferredName: '',
      birthDate: DateTime.utc(2010),
      stemId: '',
      gender: core.Gender.male,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: _addr,
      classChange: DateTime.utc(2025, 9, 1),
      schoolId: 1,
    );

WisaStaff _staff({String code = 'SMIT'}) => WisaStaff(
      code: core.WisaStaffCode(code),
      wisaId: const core.WisaId('42'),
      firstName: 'Anna',
      lastName: 'Smit',
    );

WisaClassGroup _classGroup({String name = '3A'}) => WisaClassGroup(
      name: name,
      groupName: '00',
      description: 'Derde jaar A',
      adminCode: '3A',
      schoolCode: '012345',
      schoolId: 1,
    );

WisaSchool _school({int id = 1, bool isVirtual = false}) => WisaSchool(
      id: id,
      name: 'SMA',
      description: 'Sint-Michiel',
      isVirtual: isVirtual,
    );

WisaSnapshot _snap({
  DateTime? fetchedAt,
  List<WisaStudent>? students,
  List<WisaStaff>? staff,
  List<WisaClassGroup>? classGroups,
  List<WisaSchool>? schools,
}) =>
    WisaSnapshot(
      fetchedAt: fetchedAt ?? _first,
      students: students ?? [_student()],
      staff: staff ?? [_staff()],
      classGroups: classGroups ?? [_classGroup()],
      schools: schools ?? [_school()],
    );

void main() {
  group('wisaSnapshotUnchanged', () {
    test('same content with a fresh fetchedAt is unchanged', () {
      expect(
        wisaSnapshotUnchanged(_snap(), _snap(fetchedAt: _second)),
        isTrue,
      );
    });

    test('record order does not count as a change', () {
      final previous = _snap(
        students: [_student(wisaId: 'W1'), _student(wisaId: 'W2')],
      );
      final fresh = _snap(
        fetchedAt: _second,
        students: [_student(wisaId: 'W2'), _student(wisaId: 'W1')],
      );
      expect(wisaSnapshotUnchanged(previous, fresh), isTrue);
    });

    test('an added student is a change', () {
      final fresh = _snap(
        fetchedAt: _second,
        students: [_student(), _student(wisaId: 'W2')],
      );
      expect(wisaSnapshotUnchanged(_snap(), fresh), isFalse);
    });

    test('a removed student is a change', () {
      final fresh = _snap(fetchedAt: _second, students: const []);
      expect(wisaSnapshotUnchanged(_snap(), fresh), isFalse);
    });

    test('a modified student field is a change', () {
      final fresh = _snap(
        fetchedAt: _second,
        students: [_student(classGroup: '3B')],
      );
      expect(wisaSnapshotUnchanged(_snap(), fresh), isFalse);
    });

    test('a duplicated record is a change, not collapsed away', () {
      // Same record twice vs once: a set comparison alone would call these
      // equal; the length guard must catch it.
      final fresh = _snap(
        fetchedAt: _second,
        students: [_student(), _student()],
      );
      expect(wisaSnapshotUnchanged(_snap(), fresh), isFalse);
    });

    test('a staff change is a change', () {
      final fresh = _snap(fetchedAt: _second, staff: [_staff(code: 'JANS')]);
      expect(wisaSnapshotUnchanged(_snap(), fresh), isFalse);
    });

    test('a class-group change is a change', () {
      final fresh = _snap(
        fetchedAt: _second,
        classGroups: [_classGroup(name: '3B')],
      );
      expect(wisaSnapshotUnchanged(_snap(), fresh), isFalse);
    });

    test('a school change (including the virtual flag) is a change', () {
      final fresh = _snap(
        fetchedAt: _second,
        schools: [_school(isVirtual: true)],
      );
      expect(wisaSnapshotUnchanged(_snap(), fresh), isFalse);
    });
  });
}
