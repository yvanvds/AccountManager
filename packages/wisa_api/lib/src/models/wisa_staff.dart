import 'package:account_core/account_core.dart' as core;

/// A WISA staff record (one row of the `SmaSyncPer` CSV).
///
/// Per the resolution of OQ-1 (`docs/domain-model.md` §3.4), `code` is the
/// primary key in WISA's staff scope and [wisaId] is retained as a
/// separate numeric identifier (which may be empty for some staff).
///
/// Implements the [core.WisaStaff] interface declared in `account_core`.
class WisaStaff implements core.WisaStaff {
  @override
  final core.WisaStaffCode code;

  @override
  final core.WisaId? wisaId;

  final String firstName;
  final String lastName;

  /// The WISA schools this staff member was pulled from (#340).
  ///
  /// The `SmaSyncPer` CSV carries **no** institution column — the school is only
  /// known from the `IS_ID` the query was sent with — so the connector stamps it
  /// on per pull, exactly as `parseStudentRow` stamps `WisaStudent.schoolId`.
  /// It is a *set* rather than a single id because the shared credentials walk
  /// every school of the group and a teacher who works at two of them comes back
  /// from two pulls: the second occurrence merges its id here instead of being
  /// dropped by the first-wins dedupe (see `WisaConnector.sync`).
  ///
  /// **Presence, not a filter.** Nothing narrows the pull by it: a teacher who
  /// left our school but is still listed by a sibling group school must keep
  /// arriving in the snapshot, because that is the sole reason
  /// `RemoveStaffFromAzure` / `RemoveStaffFromSmartschool` do not fire on them.
  /// This only records *where* they were found so the view layer can tell one of
  /// ours from one of the group's.
  ///
  /// Empty for a record restored from a snapshot written before #340, and for a
  /// hand-built one; every consumer reads an empty set as "school unknown" and
  /// falls back to the pre-#340 behaviour of treating the member as ours.
  final Set<int> schoolIds;

  WisaStaff({
    required this.code,
    this.wisaId,
    required this.firstName,
    required this.lastName,
    Set<int> schoolIds = const <int>{},
  }) : schoolIds = Set<int>.unmodifiable(schoolIds);

  /// This record with [ids] folded into [schoolIds] — how a second group
  /// school's `SmaSyncPer` row merges into the one the first school produced.
  ///
  /// Everything else is kept from the row already held, so the merge is
  /// first-wins on the *fields* exactly as the dedupe it replaces was, and only
  /// the school set grows.
  WisaStaff withSchoolIds(Iterable<int> ids) => WisaStaff(
        code: code,
        wisaId: wisaId,
        firstName: firstName,
        lastName: lastName,
        schoolIds: <int>{...schoolIds, ...ids},
      );

  /// Serializes to the connector's own snapshot shape. Round-trips with
  /// [WisaStaff.fromJson] for the persisted cold snapshot (#107).
  Map<String, dynamic> toJson() => {
        'code': code.toJson(),
        if (wisaId != null) 'wisaId': wisaId!.toJson(),
        'firstName': firstName,
        'lastName': lastName,
        // Omitted when empty so a snapshot of a hand-built record stays byte
        // -identical to the pre-#340 shape.
        if (schoolIds.isNotEmpty) 'schoolIds': (schoolIds.toList()..sort()),
      };

  factory WisaStaff.fromJson(Map<String, dynamic> json) => WisaStaff(
        code: core.WisaStaffCode(json['code'] as String),
        wisaId: json['wisaId'] == null
            ? null
            : core.WisaId(json['wisaId'] as String),
        firstName: json['firstName'] as String,
        lastName: json['lastName'] as String,
        // Absent in a document written before #340: an empty set reads as
        // "school unknown", which every consumer treats as ours.
        schoolIds: <int>{
          for (final id in (json['schoolIds'] as List<dynamic>? ?? const []))
            id as int,
        },
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaStaff &&
          code == other.code &&
          wisaId == other.wisaId &&
          firstName == other.firstName &&
          lastName == other.lastName &&
          _sameSchools(schoolIds, other.schoolIds);

  static bool _sameSchools(Set<int> a, Set<int> b) =>
      a.length == b.length && a.every(b.contains);

  @override
  int get hashCode => Object.hash(
        code,
        wisaId,
        firstName,
        lastName,
        Object.hashAllUnordered(schoolIds),
      );

  @override
  String toString() =>
      'WisaStaff(code: $code, name: $firstName $lastName, wisaId: $wisaId)';
}
