import 'package:account_core/account_core.dart' as core;

/// A WISA student record (one row of the `SmaSyncLln` CSV).
///
/// Implements the [core.WisaStudent] interface so the linker can refer to
/// it without depending on `wisa_api`. Spec:
/// `docs/domain-model.md` §3.3. Legacy reference:
/// `legacy-wpf/AccountApi/Wisa/Student.cs`.
class WisaStudent implements core.WisaStudent {
  @override
  final core.WisaId wisaId;

  final String classGroup;
  final String classSubGroup;
  final String name;
  final String firstName;
  final String preferredName;
  final DateTime birthDate;
  final String stemId;
  final core.Gender gender;
  final String nationalId;
  final String birthPlace;
  final String nationality;
  final core.Address address;
  final DateTime classChange;
  final int schoolId;

  const WisaStudent({
    required this.wisaId,
    required this.classGroup,
    required this.classSubGroup,
    required this.name,
    required this.firstName,
    required this.preferredName,
    required this.birthDate,
    required this.stemId,
    required this.gender,
    required this.nationalId,
    required this.birthPlace,
    required this.nationality,
    required this.address,
    required this.classChange,
    required this.schoolId,
  });

  /// Serializes to the connector's own snapshot shape. Round-trips with
  /// [WisaStudent.fromJson] for the persisted cold snapshot (#107).
  Map<String, dynamic> toJson() => {
        'wisaId': wisaId.toJson(),
        'classGroup': classGroup,
        'classSubGroup': classSubGroup,
        'name': name,
        'firstName': firstName,
        'preferredName': preferredName,
        'birthDate': birthDate.toIso8601String(),
        'stemId': stemId,
        'gender': gender.toJson(),
        'nationalId': nationalId,
        'birthPlace': birthPlace,
        'nationality': nationality,
        'address': address.toJson(),
        'classChange': classChange.toIso8601String(),
        'schoolId': schoolId,
      };

  factory WisaStudent.fromJson(Map<String, dynamic> json) => WisaStudent(
        wisaId: core.WisaId(json['wisaId'] as String),
        classGroup: json['classGroup'] as String,
        classSubGroup: json['classSubGroup'] as String,
        name: json['name'] as String,
        firstName: json['firstName'] as String,
        preferredName: json['preferredName'] as String,
        birthDate: DateTime.parse(json['birthDate'] as String),
        stemId: json['stemId'] as String,
        gender: core.Gender.fromJson(json['gender'] as String),
        nationalId: json['nationalId'] as String,
        birthPlace: json['birthPlace'] as String,
        nationality: json['nationality'] as String,
        address: core.Address.fromJson(json['address'] as Map<String, dynamic>),
        classChange: DateTime.parse(json['classChange'] as String),
        schoolId: json['schoolId'] as int,
      );

  /// Display name: `preferredName` when non-empty, otherwise `firstName`,
  /// followed by `name`. Mirrors legacy `Student.FullName`.
  String get fullName {
    final first = preferredName.isNotEmpty ? preferredName : firstName;
    return '$first $name';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaStudent &&
          wisaId == other.wisaId &&
          classGroup == other.classGroup &&
          classSubGroup == other.classSubGroup &&
          name == other.name &&
          firstName == other.firstName &&
          preferredName == other.preferredName &&
          birthDate == other.birthDate &&
          stemId == other.stemId &&
          gender == other.gender &&
          nationalId == other.nationalId &&
          birthPlace == other.birthPlace &&
          nationality == other.nationality &&
          address == other.address &&
          classChange == other.classChange &&
          schoolId == other.schoolId;

  @override
  int get hashCode => Object.hashAll([
        wisaId,
        classGroup,
        classSubGroup,
        name,
        firstName,
        preferredName,
        birthDate,
        stemId,
        gender,
        nationalId,
        birthPlace,
        nationality,
        address,
        classChange,
        schoolId,
      ]);

  @override
  String toString() =>
      'WisaStudent(wisaId: $wisaId, name: $name $firstName, class: $classGroup)';
}
