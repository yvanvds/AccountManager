/// Per-WISA-school ownership entry persisted in the settings document.
///
/// The shared credentials pull *every* WISA school the group can see, but we
/// only **manage** some of them. This profile records, per school id, whether
/// it is [ours] (managed) and an optional per-school [prefix] override for the
/// Azure-orphan scoping the linker does (INV-22). Since #286 this list is the
/// **only** ownership record: the snapshot-time `MarkAsOurs` import rule that
/// once flagged a school by code is gone, because this operator-editable list —
/// keyed by school *id* and persisted in the settings document — won over it
/// everywhere it was read.
///
/// The shape (`{ schemaVersion, schoolId, code, name, ours, virtual, prefix }`)
/// is the
/// per-WISA-school ownership link #112/#113 called for, so the settings document
/// is not reshaped twice. This slice only carries the data — no action reads it
/// yet (#134 is slice 2).
class WisaSchoolProfile {
  const WisaSchoolProfile({
    required this.schoolId,
    this.code = '',
    this.name = '',
    this.ours = false,
    this.virtual = false,
    this.prefix = '',
  });

  /// The WISA school id (`WisaSchool.id`) this ownership entry is keyed by.
  final int schoolId;

  /// The short WISA school code (`ISMAA`, `ISMAB`, …) — how the schools are
  /// identified day to day, and what the settings editor shows beneath the
  /// [name] (#194). It arrives on `WisaSchool.code` (#208). Empty for profiles
  /// stored before the code was persisted — the editor falls back to the [name]
  /// and a later fetch fills the code in.
  final String code;

  /// The long descriptive WISA school name (`WisaSchool.name`), which the
  /// settings editor leads each cell with. Empty for profiles stored before
  /// the name was persisted (#171) — the editor falls back to the [code], then
  /// to `School <id>`, and a later fetch fills the name in.
  final String name;

  /// Whether we manage this school. A student found only in schools where this
  /// is `false` (group-visible siblings) has left *our* schools.
  final bool ours;

  /// Whether this school is a *virtual* school, i.e. one WISA must be queried
  /// with [AppSettings.wisa]'s separate virtual workdate instead of the ordinary
  /// one (#203). The persistent, id-keyed counterpart of the snapshot-time
  /// `MarkAsVirtual` import rule, which still exists — the pull unions both
  /// surfaces, unlike [ours], whose rule was dropped in #286.
  /// Defaults to `false`, so a settings document written before this field
  /// existed loads with every school non-virtual.
  final bool virtual;

  /// Per-school Azure-orphan scoping prefix. Empty means "inherit the global
  /// [AppSettings.schoolPrefix]" — a per-school override to grow into (#113),
  /// not yet consulted by the linker.
  final String prefix;

  WisaSchoolProfile copyWith({
    int? schoolId,
    String? code,
    String? name,
    bool? ours,
    bool? virtual,
    String? prefix,
  }) =>
      WisaSchoolProfile(
        schoolId: schoolId ?? this.schoolId,
        code: code ?? this.code,
        name: name ?? this.name,
        ours: ours ?? this.ours,
        virtual: virtual ?? this.virtual,
        prefix: prefix ?? this.prefix,
      );

  /// The layout version [toJson] writes, and the marker [fromJson] migrates on.
  ///
  /// `1` (or, in practice, its absence) is every profile persisted before #208:
  /// those were filled from a `WisaSchool` whose halves were swapped, so their
  /// `code` holds the long name and their `name` the short code. `2` is the
  /// honest layout. Bump this — and extend [fromJson]'s ladder — if the shape
  /// ever changes again.
  static const int schemaVersion = 2;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'schoolId': schoolId,
        'code': code,
        'name': name,
        'ours': ours,
        'virtual': virtual,
        'prefix': prefix,
      };

  /// Reads a persisted profile, migrating the pre-#208 layout on the way in.
  ///
  /// A document with no `schemaVersion` was written when `code` held the long
  /// name and `name` the short code, so its two halves are swapped back here.
  /// The alternative — waiting for the next WISA fetch to re-derive both — was
  /// rejected: a passive session may never fetch, and it would leave every
  /// stored profile rendering inside out until someone did.
  factory WisaSchoolProfile.fromJson(Map<String, dynamic> json) {
    final int version = (json['schemaVersion'] as int?) ?? 1;
    final String storedCode = (json['code'] as String?) ?? '';
    final String storedName = (json['name'] as String?) ?? '';
    final bool swapped = version < 2;
    return WisaSchoolProfile(
      schoolId: json['schoolId'] as int,
      code: swapped ? storedName : storedCode,
      name: swapped ? storedCode : storedName,
      ours: (json['ours'] as bool?) ?? false,
      virtual: (json['virtual'] as bool?) ?? false,
      prefix: (json['prefix'] as String?) ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaSchoolProfile &&
          schoolId == other.schoolId &&
          code == other.code &&
          name == other.name &&
          ours == other.ours &&
          virtual == other.virtual &&
          prefix == other.prefix;

  @override
  int get hashCode => Object.hash(schoolId, code, name, ours, virtual, prefix);

  @override
  String toString() =>
      'WisaSchoolProfile(schoolId: $schoolId, code: $code, name: $name, '
      'ours: $ours, virtual: $virtual, prefix: $prefix)';
}
