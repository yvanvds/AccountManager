/// A WISA school ("instelling") record.
///
/// Source: legacy `legacy-wpf/AccountApi/Wisa/School.cs`. The CSV columns
/// from the `SMAGetInst` query are `ID,NAME,DESCRIPTION` — note that the
/// legacy code maps column 1 (the WISA "NAME" column) to `Description` and
/// column 2 (the WISA "DESCRIPTION" column) to `Name`, which we preserve.
///
/// [isVirtual] is set at snapshot construction time by the
/// `MarkAsVirtual` import rule; it tells the connector that this school
/// should be synced using the virtual workdate instead of the real one.
class WisaSchool {
  final int id;
  final String name;
  final String description;
  final bool isVirtual;

  const WisaSchool({
    required this.id,
    required this.name,
    required this.description,
    this.isVirtual = false,
  });

  WisaSchool copyWith({bool? isVirtual}) => WisaSchool(
        id: id,
        name: name,
        description: description,
        isVirtual: isVirtual ?? this.isVirtual,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaSchool &&
          id == other.id &&
          name == other.name &&
          description == other.description &&
          isVirtual == other.isVirtual;

  @override
  int get hashCode => Object.hash(id, name, description, isVirtual);

  @override
  String toString() =>
      'WisaSchool(id: $id, name: $name, isVirtual: $isVirtual)';
}
