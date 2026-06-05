import 'package:account_core/account_core.dart' as core;

/// A node in the Smartschool group tree, as returned by
/// `getAllGroupsAndClasses`.
///
/// This is the connector-native parse model: mutable during the XML walk,
/// carrying every field Smartschool emits plus tree edges. The connector
/// flattens it to immutable [core.Group] records (keyed by [code]) for the
/// snapshot. Legacy reference: `legacy-wpf/AccountApi/Smartschool/Group.cs`,
/// `GroupManager.Reload`.
class SmartschoolGroup {
  String name;
  String description;

  /// Stable group identifier within Smartschool. Becomes the
  /// [core.GroupId] value.
  String code;

  core.GroupType type;

  /// `true` ⇒ official class (has students); requires an institute and
  /// admin number when saved.
  bool official;

  bool visible;
  String untis;
  String instituteNumber;
  int adminNumber;

  /// Label co-accounts see for this group (optional, read-only).
  String coAccountLabel;

  /// (Co-)titular usernames. Read-only — Smartschool does not let the API
  /// write these.
  final List<String> titulars;

  /// Child groups. Empty for leaves.
  final List<SmartschoolGroup> children;

  /// The parent's [code], or `null` for a top-level group.
  String? parentCode;

  SmartschoolGroup({
    this.name = '',
    this.description = '',
    this.code = '',
    this.type = core.GroupType.invalid,
    this.official = false,
    this.visible = false,
    this.untis = '',
    this.instituteNumber = '',
    this.adminNumber = 0,
    this.coAccountLabel = '',
    List<String>? titulars,
    List<SmartschoolGroup>? children,
    this.parentCode,
  })  : titulars = titulars ?? <String>[],
        children = children ?? <SmartschoolGroup>[];

  /// Projects this node to an immutable [core.Group]. `parentId` is set from
  /// [parentCode] when it is non-empty.
  core.Group toCoreGroup() => core.Group(
        id: core.GroupId(code),
        name: name,
        description: description,
        type: type,
        official: official,
        parentId: (parentCode != null && parentCode!.isNotEmpty)
            ? core.GroupId(parentCode!)
            : null,
        instituteNumber: instituteNumber.isEmpty ? null : instituteNumber,
        adminNumber: adminNumber == 0 ? null : adminNumber,
        origin: core.Origin.smartschool,
      );
}
