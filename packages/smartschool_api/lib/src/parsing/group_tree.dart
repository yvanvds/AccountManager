import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:xml/xml.dart';

import '../models/smartschool_group.dart';

/// Decodes and parses the `getAllGroupsAndClasses` payload into a forest of
/// top-level [SmartschoolGroup] trees.
///
/// The service returns a base64-encoded UTF-8 XML document whose `<group>`
/// elements nest to form the tree. This ports `GroupManager.Reload`
/// (`legacy-wpf/AccountApi/Smartschool/GroupManager.cs:54-154`) from a
/// streaming `XmlReader` walk to a DOM walk — same field handling, same
/// `G`/`K` type mapping.
///
/// The live V3 payload nests a group's subgroups inside a `<children>`
/// wrapper element and lists titulars as `<titu><user><username>…`. The
/// legacy streaming reader was agnostic to both — it descended on every
/// `<group>` start regardless of intervening wrappers, and reacted to every
/// `<username>` element — so this DOM walk looks through `<children>` for
/// subgroups and through `<titu>` for titulars (still accepting the flat
/// shapes older/test payloads use).
///
/// [parentCode] edges are filled in as the tree is built. The synthetic
/// legacy "root container" is not represented; the returned list is the set
/// of real top-level groups.
List<SmartschoolGroup> parseGroupTree(String base64Payload) {
  final cleaned = base64Payload.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.isEmpty) return const [];
  final xmlText = utf8.decode(base64.decode(cleaned));
  final doc = XmlDocument.parse(xmlText);

  // The payload's root may itself be a `<group>` (a single top-level tree)
  // or a wrapper element whose direct children are the top-level `<group>`s.
  final root = doc.rootElement;
  final topLevel = root.name.local == 'group'
      ? <XmlElement>[root]
      : root.findElements('group');

  return [
    for (final el in topLevel) _parseGroupElement(el, null),
  ];
}

SmartschoolGroup _parseGroupElement(XmlElement el, String? parentCode) {
  final group = SmartschoolGroup(parentCode: parentCode);

  for (final child in el.childElements) {
    switch (child.name.local) {
      case 'name':
        group.name = child.innerText;
      case 'desc':
        group.description = child.innerText;
      case 'type':
        group.type = _typeFrom(child.innerText);
      case 'code':
        group.code = child.innerText;
      case 'untis':
        group.untis = child.innerText;
      case 'visible':
        group.visible = _flag(child.innerText);
      case 'isOfficial':
        // Trimmed, like `adminNumber` below: a `1` that arrives padded (a CDATA
        // section wrapped onto its own line) must not silently read as "not an
        // official class" — that drops the class from the group link entirely
        // and its WISA twin then looks like a class nobody has created yet
        // (#225).
        group.official = _flag(child.innerText);
      case 'coAccountLabel':
        group.coAccountLabel = child.innerText;
      case 'adminNumber':
        group.adminNumber = int.tryParse(child.innerText.trim()) ?? 0;
      case 'instituteNumber':
        group.instituteNumber = child.innerText;
      case 'username':
        // Flat shape (older/test payloads): titular usernames listed
        // directly on the group.
        if (child.innerText.isNotEmpty) group.titulars.add(child.innerText);
      case 'titu':
        // Live V3 shape: <titu><user><username>…</username>…</user>…</titu>.
        for (final user in child.findElements('user')) {
          final name =
              user.findElements('username').firstOrNull?.innerText ?? '';
          if (name.isNotEmpty) group.titulars.add(name);
        }
    }
  }

  for (final sub in _childGroups(el)) {
    group.children.add(_parseGroupElement(sub, group.code));
  }
  return group;
}

/// The immediate subgroups of [el]: direct `<group>` children plus the
/// `<group>` children of any `<children>` wrapper (the live V3 shape). Does
/// not descend into nested groups — each subgroup recurses on its own.
Iterable<XmlElement> _childGroups(XmlElement el) sync* {
  for (final child in el.childElements) {
    if (child.name.local == 'group') {
      yield child;
    } else if (child.name.local == 'children') {
      yield* child.findElements('group');
    }
  }
}

/// Smartschool's boolean flags, which it spells `1`/`0`. Trimmed, so a value
/// padded by the surrounding XML still reads as the flag it is.
bool _flag(String raw) => raw.trim() == '1';

core.GroupType _typeFrom(String raw) {
  switch (raw) {
    case 'G':
      return core.GroupType.group;
    case 'K':
      return core.GroupType.classGroup;
    default:
      return core.GroupType.invalid;
  }
}
