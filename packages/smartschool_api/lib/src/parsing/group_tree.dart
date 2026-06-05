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
        group.visible = child.innerText == '1';
      case 'isOfficial':
        group.official = child.innerText == '1';
      case 'coAccountLabel':
        group.coAccountLabel = child.innerText;
      case 'adminNumber':
        group.adminNumber = int.tryParse(child.innerText.trim()) ?? 0;
      case 'instituteNumber':
        group.instituteNumber = child.innerText;
      case 'username':
        if (child.innerText.isNotEmpty) group.titulars.add(child.innerText);
    }
  }

  for (final sub in el.findElements('group')) {
    group.children.add(_parseGroupElement(sub, group.code));
  }
  return group;
}

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
