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
/// [isVirtual] tells the connector that this school should be synced using the
/// virtual workdate instead of the real one. It is stamped on just before the
/// pull from the operator's per-school virtual marks in Instellingen
/// (`AppSettings.virtualWisaSchoolIds`, keyed by school id, #203). A
/// snapshot-time `MarkAsVirtual` import rule set the same flag by short code
/// until #277 retired it: two surfaces for one flag could disagree, and the id
/// the grid keys by survives a rename or a recode where a code does not.
///
/// There is no ownership flag here (#286). Which schools we **manage** — as
/// opposed to the sibling schools the shared credentials also reach — is the
/// operator's WISA-scholen list in Instellingen, keyed by school id
/// (`AppSettings.managedWisaSchoolIds`, #178). A snapshot-time `isOurs` flag
/// existed alongside it until #286 and nothing read it: the settings list wins
/// as soon as it holds a single school, which is every install that has ever
/// pressed **Scholen ophalen**. An `isOurs` key in a cold snapshot written
/// before #286 is ignored by [WisaSchool.fromJson].
class WisaSchool {
  final int id;

  /// The long, human-readable school name ("Instituut Sancta Maria-A").
  /// Parsed from the `SMAGetInst` CSV's `NAME` column.
  final String name;

  /// The short code operators use day to day (`ISMAA`). Parsed from the
  /// `SMAGetInst` CSV's `DESCRIPTION` column, and what the WISA-scholen grid
  /// shows beneath each school's long name.
  final String code;
  final bool isVirtual;

  const WisaSchool({
    required this.id,
    required this.name,
    required this.code,
    this.isVirtual = false,
  });

  /// Serializes to the connector's own snapshot shape. Round-trips with
  /// [WisaSchool.fromJson] for the persisted cold snapshot (#107).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'code': code,
        'isVirtual': isVirtual,
      };

  /// Reads a snapshot school, migrating documents written before #208.
  ///
  /// Those carry the halves under the inverted legacy keys — `name` held the
  /// short code and `description` the long name — so a document with no `code`
  /// key is read back swapped. Nothing else distinguishes the two shapes, and
  /// the `code` key is written unconditionally, so the test is exact rather
  /// than a guess about the values.
  ///
  /// An `isOurs` key from a document written before #286 is ignored: the flag
  /// is gone and the managed-school set comes from Settings (see the class
  /// doc).
  factory WisaSchool.fromJson(Map<String, dynamic> json) {
    final legacy = !json.containsKey('code') && json.containsKey('description');
    return WisaSchool(
      id: json['id'] as int,
      name: (legacy ? json['description'] : json['name']) as String,
      code: (legacy ? json['name'] : json['code']) as String,
      isVirtual: (json['isVirtual'] as bool?) ?? false,
    );
  }

  WisaSchool copyWith({bool? isVirtual}) => WisaSchool(
        id: id,
        name: name,
        code: code,
        isVirtual: isVirtual ?? this.isVirtual,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaSchool &&
          id == other.id &&
          name == other.name &&
          code == other.code &&
          isVirtual == other.isVirtual;

  @override
  int get hashCode => Object.hash(id, name, code, isVirtual);

  @override
  String toString() =>
      'WisaSchool(id: $id, name: $name, code: $code, isVirtual: $isVirtual)';
}
