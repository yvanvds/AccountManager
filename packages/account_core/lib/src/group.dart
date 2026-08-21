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

  /// The [origin] system's own numeric identifier for this group, when it
  /// exposes one distinct from [id].
  ///
  /// Smartschool returns it in the per-account `groups` arrays of
  /// `getAllAccountsExtended` (e.g. `298` for class code `SSM1A`) but *not* in
  /// the `getAllGroupsAndClasses` tree these records are built from, so the
  /// connector backfills it by joining on the code (#138). It is the id
  /// Smartschool uses to address a group outside its SOAP API. `null` when the
  /// sync could not resolve one — a group with no members anywhere — or when
  /// the system carries no such id (WISA class groups).
  final int? sourceId;

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
    this.sourceId,
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
        if (sourceId != null) 'sourceId': sourceId,
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
        sourceId: json['sourceId'] as int?,
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
          sourceId == other.sourceId &&
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
        sourceId,
        origin,
      );
}

/// The cross-system match key for a group *name* (#225).
///
/// A class carries no stable id across WISA, Smartschool and Azure — the name
/// **is** the bridge — so every layer that joins groups by name must normalize
/// it the same way, or the linker and the placement resolver disagree about
/// which classes exist. Trimmed and lower-cased (INV-12), plus every run of
/// whitespace collapsed to a single ASCII space: a class name is typed by an
/// operator in Smartschool, so it picks up double spaces and the non-breaking
/// space a copy-paste leaves behind, neither of which makes it a different
/// class from the WISA one.
///
/// Returns `null` for a null or blank name so an empty key never matches or
/// indexes anything.
String? normalizeGroupName(String? name) {
  if (name == null) return null;
  final collapsed = name.replaceAll(_whitespaceRun, ' ').trim();
  return collapsed.isEmpty ? null : collapsed.toLowerCase();
}

/// A deliberately *looser* key than [normalizeGroupName]: the same name with
/// **all** whitespace removed, so `2G` and `2 G` share one key.
///
/// Never used to link two systems' groups together — dropping the space that
/// separates a class from its sub-group (`5A 01`) would fuse names that really
/// are distinct. It exists for the one question where a false positive is
/// cheap and a false negative is not: "does a group by roughly this name
/// already exist in Smartschool?" (#225). Answering that wrongly-yes costs an
/// informational notice; answering it wrongly-no proposes creating a class
/// Smartschool already has.
String? groupNameFingerprint(String? name) =>
    normalizeGroupName(name)?.replaceAll(' ', '');

/// A run of Unicode whitespace, spelled out rather than left to `\s` alone so
/// the non-breaking (U+00A0) and narrow no-break (U+202F) spaces are covered
/// whatever the regex engine's reading of `\s` is.
final RegExp _whitespaceRun =
    RegExp(r'[\s\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+');

/// The Office 365 group name for a class: `<PREFIX>-<KLAS>` (#228).
///
/// [className] is the **bare** WISA class name \u2014 `2F`, never the sub-grouped
/// `2F ECO`: sub-groups get no group of their own, so every one of their
/// students belongs to the parent class's group. The same string is used as the
/// group's `displayName` and its `mailNickname`, which makes the resulting
/// address `<PREFIX>-<KLAS>@<studentdomein>`.
///
/// Returns `null` when either half is blank \u2014 there is no group to name then.
String? azureClassGroupName(String? schoolPrefix, String? className) {
  final prefix = schoolPrefix?.trim() ?? '';
  final name = className?.trim() ?? '';
  if (prefix.isEmpty || name.isEmpty) return null;
  return '$prefix-$name';
}

/// The bare class name an Azure group's [displayName] stands for, given the
/// school's [schoolPrefix] \u2014 the inverse of [azureClassGroupName] (#228).
///
/// The Azure side of the class-group bridge is **prefix-aware**: a group named
/// `SSM-2A` is the Office 365 group of class `2A`, and matching its display name
/// against the WISA class name directly never joins the two. Comparison of the
/// prefix is case-insensitive (INV-12); the remainder is returned as written so
/// it can be displayed.
///
/// Returns `null` when [displayName] is not in our `<PREFIX>-` namespace, or
/// when nothing follows the separator.
String? azureClassNameOf(String? displayName, String? schoolPrefix) {
  final name = displayName?.trim() ?? '';
  final prefix = schoolPrefix?.trim() ?? '';
  if (name.isEmpty || prefix.isEmpty) return null;
  final marker = '$prefix-';
  if (name.length <= marker.length) return null;
  if (name.substring(0, marker.length).toLowerCase() != marker.toLowerCase()) {
    return null;
  }
  final bare = name.substring(marker.length).trim();
  return bare.isEmpty ? null : bare;
}

/// Whether [nickname] is usable verbatim as a Graph `mailNickname` (#228).
///
/// Bare class names carry no spaces, so `<PREFIX>-<KLAS>` needs no slug rule \u2014
/// but nothing *enforces* that on the WISA side, and Graph rejects a create
/// whose nickname holds a space, a diacritic, or one of its reserved
/// characters. The group actions consult this instead of silently mangling a
/// name into something the operator never asked for: an unusable name means no
/// create is proposed at all.
///
/// Graph accepts ASCII 0\u2013127 except ``@ ( ) \ [ ] " ; : < > ,`` and space.
bool isValidMailNickname(String? nickname) {
  final value = nickname ?? '';
  if (value.isEmpty || value.trim().length != value.length) return false;
  for (final unit in value.codeUnits) {
    if (unit < 0x21 || unit > 0x7e) return false;
    if (_reservedNicknameChars.contains(unit)) return false;
  }
  return true;
}

/// The characters Graph refuses inside a `mailNickname`, as code units.
final Set<int> _reservedNicknameChars = '@()\\[]";:<>,'.codeUnits.toSet();

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
