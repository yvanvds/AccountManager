/// A WISA class group ("klasgroep") record.
///
/// Source: one row of the `SyncKlas` CSV query in
/// `legacy-wpf/AccountApi/Wisa/ClassGroup.cs`.
///
/// `groupName == "00"` is the special "no subgroups" sentinel — a class
/// with `00` and no other groupName for the same class is a single-group
/// class. The connector dedupes accordingly in
/// `legacy-wpf/AccountApi/Wisa/ClassGroupManager.cs`.
class WisaClassGroup {
  final String name;
  final String groupName;
  final String description;
  final String adminCode;

  /// School institute number (`INSTELLINGSNUMMER`). May have been rewritten
  /// at snapshot construction by the `ReplaceInstitute` import rule.
  final String schoolCode;

  /// Numeric school id this group belongs to (set by the connector when
  /// fetching, not from the CSV itself).
  final int schoolId;

  const WisaClassGroup({
    required this.name,
    required this.groupName,
    required this.description,
    required this.adminCode,
    required this.schoolCode,
    required this.schoolId,
  });

  /// Serializes to the connector's own snapshot shape. Round-trips with
  /// [WisaClassGroup.fromJson] for the persisted cold snapshot (#107).
  Map<String, dynamic> toJson() => {
        'name': name,
        'groupName': groupName,
        'description': description,
        'adminCode': adminCode,
        'schoolCode': schoolCode,
        'schoolId': schoolId,
      };

  factory WisaClassGroup.fromJson(Map<String, dynamic> json) => WisaClassGroup(
        name: json['name'] as String,
        groupName: json['groupName'] as String,
        description: json['description'] as String,
        adminCode: json['adminCode'] as String,
        schoolCode: json['schoolCode'] as String,
        schoolId: json['schoolId'] as int,
      );

  /// `"name groupName"` when subgroups apply, otherwise just `name`.
  /// Mirrors legacy `ClassGroup.FullName`.
  ///
  /// A **blank** [groupName] is treated like the `"00"` sentinel: it names no
  /// group either, so appending it would only leave the trailing separator of
  /// `'1A '`. Since #362 the connector no longer drops such a row on the way in
  /// — a class must not vanish because one of its rows is malformed — so this
  /// is the guard that keeps it from reaching a class name.
  String get fullName {
    final group = groupName.trim();
    return group.isEmpty || group == '00' ? name : '$name $group';
  }

  /// First numeric character of [name] — e.g. `'1A'` ⇒ `1`. Returns `-1`
  /// when [name] is empty or doesn't start with a digit (legacy returns
  /// `-1` via `char.GetNumericValue` for non-digits).
  int get year {
    if (name.isEmpty) return -1;
    final c = name.codeUnitAt(0);
    if (c < 0x30 || c > 0x39) return -1;
    return c - 0x30;
  }

  WisaClassGroup copyWith({String? schoolCode}) => WisaClassGroup(
        name: name,
        groupName: groupName,
        description: description,
        adminCode: adminCode,
        schoolCode: schoolCode ?? this.schoolCode,
        schoolId: schoolId,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaClassGroup &&
          name == other.name &&
          groupName == other.groupName &&
          description == other.description &&
          adminCode == other.adminCode &&
          schoolCode == other.schoolCode &&
          schoolId == other.schoolId;

  @override
  int get hashCode => Object.hash(
        name,
        groupName,
        description,
        adminCode,
        schoolCode,
        schoolId,
      );

  @override
  String toString() =>
      'WisaClassGroup(name: $name, groupName: $groupName, schoolId: $schoolId)';
}
