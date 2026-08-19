/// A WISA school ("instelling") record.
///
/// Source: legacy `legacy-wpf/AccountApi/Wisa/School.cs`. The CSV columns
/// from the `SMAGetInst` query are `ID,NAME,DESCRIPTION`, and WISA fills them
/// the other way round from what they are called: column `NAME` carries the
/// **long** name ("Instituut Sancta Maria-A") and column `DESCRIPTION` the
/// **short** code (`ISMAA`). The legacy C# preserved that inversion in its
/// field names; we do not (#208). Here [name] is always the long name and
/// [code] always the short code, so no reader has to remember a swap —
/// `parseSchoolRow` is the single place that untangles the CSV.
///
/// [isVirtual] is set at snapshot construction time by the
/// `MarkAsVirtual` import rule; it tells the connector that this school
/// should be synced using the virtual workdate instead of the real one.
///
/// [isOurs] marks a school we actually **manage** (as opposed to one that
/// is merely group-visible through the shared credentials). It is set at
/// snapshot construction time by the `MarkAsOurs` import rule, paralleling
/// [isVirtual]. Group-wide leave detection (#113) needs it to tell a student
/// who left *our* school but stayed in the group from one who left the group
/// entirely; this slice only carries the flag — it changes no action yet.
class WisaSchool {
  final int id;

  /// The long, human-readable school name ("Instituut Sancta Maria-A").
  /// Parsed from the `SMAGetInst` CSV's `NAME` column.
  final String name;

  /// The short code operators use day to day (`ISMAA`). Parsed from the
  /// `SMAGetInst` CSV's `DESCRIPTION` column, and what the school-marking
  /// import rules (`MarkAsOurs`, `MarkAsVirtual`) match on.
  final String code;
  final bool isVirtual;
  final bool isOurs;

  const WisaSchool({
    required this.id,
    required this.name,
    required this.code,
    this.isVirtual = false,
    this.isOurs = false,
  });

  /// Serializes to the connector's own snapshot shape. Round-trips with
  /// [WisaSchool.fromJson] for the persisted cold snapshot (#107).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'code': code,
        'isVirtual': isVirtual,
        'isOurs': isOurs,
      };

  /// Reads a snapshot school, migrating documents written before #208.
  ///
  /// Those carry the halves under the inverted legacy keys — `name` held the
  /// short code and `description` the long name — so a document with no `code`
  /// key is read back swapped. Nothing else distinguishes the two shapes, and
  /// the `code` key is written unconditionally, so the test is exact rather
  /// than a guess about the values.
  factory WisaSchool.fromJson(Map<String, dynamic> json) {
    final legacy = !json.containsKey('code') && json.containsKey('description');
    return WisaSchool(
      id: json['id'] as int,
      name: (legacy ? json['description'] : json['name']) as String,
      code: (legacy ? json['name'] : json['code']) as String,
      isVirtual: (json['isVirtual'] as bool?) ?? false,
      isOurs: (json['isOurs'] as bool?) ?? false,
    );
  }

  WisaSchool copyWith({bool? isVirtual, bool? isOurs}) => WisaSchool(
        id: id,
        name: name,
        code: code,
        isVirtual: isVirtual ?? this.isVirtual,
        isOurs: isOurs ?? this.isOurs,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaSchool &&
          id == other.id &&
          name == other.name &&
          code == other.code &&
          isVirtual == other.isVirtual &&
          isOurs == other.isOurs;

  @override
  int get hashCode => Object.hash(id, name, code, isVirtual, isOurs);

  @override
  String toString() => 'WisaSchool(id: $id, name: $name, code: $code, '
      'isVirtual: $isVirtual, isOurs: $isOurs)';
}
