/// Per-WISA-school ownership entry persisted in the settings document.
///
/// The shared credentials pull *every* WISA school the group can see, but we
/// only **manage** some of them. This profile records, per school id, whether
/// it is [ours] (managed) and an optional per-school [prefix] override for the
/// Azure-orphan scoping the linker does (INV-22). It is the persistent, keyed
/// counterpart of the snapshot-time `MarkAsOurs` import rule: the rule flips
/// `WisaSchool.isOurs` at pull time by school *name*, while this list is the
/// operator-editable ownership record keyed by school *id* that survives in the
/// settings blob.
///
/// The shape (`{ schoolId, name, ours, prefix }`) is the per-WISA-school ownership
/// link #112/#113 called for, so the settings document is not reshaped twice.
/// This slice only carries the data — no action reads it yet (#134 is slice 2).
class WisaSchoolProfile {
  const WisaSchoolProfile({
    required this.schoolId,
    this.name = '',
    this.ours = false,
    this.prefix = '',
  });

  /// The WISA school id (`WisaSchool.id`) this ownership entry is keyed by.
  final int schoolId;

  /// The WISA school name (`WisaSchool.name`), persisted so the settings editor
  /// can render the full known-school list by name without re-fetching. Empty
  /// for profiles stored before the name was persisted (#171) — the editor
  /// falls back to `School <id>` and a later fetch fills the name in.
  final String name;

  /// Whether we manage this school. A student found only in schools where this
  /// is `false` (group-visible siblings) has left *our* schools.
  final bool ours;

  /// Per-school Azure-orphan scoping prefix. Empty means "inherit the global
  /// [AppSettings.schoolPrefix]" — a per-school override to grow into (#113),
  /// not yet consulted by the linker.
  final String prefix;

  WisaSchoolProfile copyWith({
    int? schoolId,
    String? name,
    bool? ours,
    String? prefix,
  }) =>
      WisaSchoolProfile(
        schoolId: schoolId ?? this.schoolId,
        name: name ?? this.name,
        ours: ours ?? this.ours,
        prefix: prefix ?? this.prefix,
      );

  Map<String, dynamic> toJson() => {
        'schoolId': schoolId,
        'name': name,
        'ours': ours,
        'prefix': prefix,
      };

  factory WisaSchoolProfile.fromJson(Map<String, dynamic> json) =>
      WisaSchoolProfile(
        schoolId: json['schoolId'] as int,
        name: (json['name'] as String?) ?? '',
        ours: (json['ours'] as bool?) ?? false,
        prefix: (json['prefix'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaSchoolProfile &&
          schoolId == other.schoolId &&
          name == other.name &&
          ours == other.ours &&
          prefix == other.prefix;

  @override
  int get hashCode => Object.hash(schoolId, name, ours, prefix);

  @override
  String toString() =>
      'WisaSchoolProfile(schoolId: $schoolId, name: $name, ours: $ours, '
      'prefix: $prefix)';
}
