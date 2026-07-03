import 'enums.dart';
import 'ids.dart';

/// A class or non-class group. Forms a tree via [parentId].
///
/// Spec: `docs/domain-model.md` §3.7. The legacy `IGroup` tree owns its
/// members; here, membership is modelled separately by [Membership] so a
/// person can hold many memberships in the same system without resorting to
/// "skip if already seen" walks (PAIN-1).
class Group {
  final GroupId id;
  final String name;
  final String description;
  final GroupType type;

  /// `true` ⇒ real class (has students). Distinguishes administrative class
  /// nodes from organisational sub-groups in Smartschool.
  final bool official;

  /// Parent group in the tree. `null` for roots.
  final GroupId? parentId;

  final String? instituteNumber;
  final int? adminNumber;

  /// The Untis timetable code Smartschool stores for the class. Empty when the
  /// system carries none: WISA exposes no Untis value, and a freshly imported
  /// Smartschool class has it blank until it is set to the class [name]. Legacy
  /// `IGroup.Untis`; `ModifySmartschoolData` converges a drifted value to [name].
  final String untis;

  final Origin origin;

  const Group({
    required this.id,
    required this.name,
    required this.description,
    required this.type,
    required this.official,
    this.parentId,
    this.instituteNumber,
    this.adminNumber,
    this.untis = '',
    required this.origin,
  });

  Map<String, dynamic> toJson() => {
        'id': id.toJson(),
        'name': name,
        'description': description,
        'type': type.toJson(),
        'official': official,
        if (parentId != null) 'parentId': parentId!.toJson(),
        if (instituteNumber != null) 'instituteNumber': instituteNumber,
        if (adminNumber != null) 'adminNumber': adminNumber,
        if (untis.isNotEmpty) 'untis': untis,
        'origin': origin.toJson(),
      };

  factory Group.fromJson(Map<String, dynamic> json) => Group(
        id: GroupId(json['id'] as String),
        name: json['name'] as String,
        description: json['description'] as String,
        type: GroupType.fromJson(json['type'] as String),
        official: json['official'] as bool,
        parentId: json['parentId'] == null
            ? null
            : GroupId(json['parentId'] as String),
        instituteNumber: json['instituteNumber'] as String?,
        adminNumber: json['adminNumber'] as int?,
        untis: json['untis'] as String? ?? '',
        origin: Origin.fromJson(json['origin'] as String),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Group &&
          id == other.id &&
          name == other.name &&
          description == other.description &&
          type == other.type &&
          official == other.official &&
          parentId == other.parentId &&
          instituteNumber == other.instituteNumber &&
          adminNumber == other.adminNumber &&
          untis == other.untis &&
          origin == other.origin;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        description,
        type,
        official,
        parentId,
        instituteNumber,
        adminNumber,
        untis,
        origin,
      );
}

/// First-class many-to-many link between a [Person] and a [Group].
///
/// Replaces the legacy "groups own their members" model. Multiple memberships
/// of the same person in the same system are allowed (PAIN-1, INV-30); the
/// "at most one official class per snapshot" constraint applies to memberships
/// where `accountType == AccountType.student` and the [Group] has
/// `official == true` (INV-31, enforced by the linker / action engine).
class Membership {
  final PersonId personId;
  final GroupId groupId;
  final AccountType accountType;
  final Origin origin;

  const Membership({
    required this.personId,
    required this.groupId,
    required this.accountType,
    required this.origin,
  });

  Map<String, dynamic> toJson() => {
        'personId': personId.toJson(),
        'groupId': groupId.toJson(),
        'accountType': accountType.toJson(),
        'origin': origin.toJson(),
      };

  factory Membership.fromJson(Map<String, dynamic> json) => Membership(
        personId: PersonId(json['personId'] as String),
        groupId: GroupId(json['groupId'] as String),
        accountType: AccountType.fromJson(json['accountType'] as String),
        origin: Origin.fromJson(json['origin'] as String),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Membership &&
          personId == other.personId &&
          groupId == other.groupId &&
          accountType == other.accountType &&
          origin == other.origin;

  @override
  int get hashCode => Object.hash(personId, groupId, accountType, origin);
}
