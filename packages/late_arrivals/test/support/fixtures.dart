/// Minimal Smartschool fixtures for the scan-resolver tests: only the fields
/// the resolver reads carry meaning, the rest are inert defaults.
library;

import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart' as ss;

const core.Address blankAddress = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

/// A Smartschool account. [accountId] is the "Internnummer" that holds the
/// student's WISA id by operator convention — the value a card encodes.
///
/// [referenceIdentifier] defaults to a well-formed `<platform>_<userId>_0`;
/// pass `null` for the row whose internal user id cannot be parsed.
ss.SmartschoolAccount account(
  String uid, {
  required String accountId,
  String givenName = 'Jane',
  String surname = 'Doe',
  String preferredName = '',
  core.PersonRole? role = core.PersonRole.student,
  String? referenceIdentifier = '4069_12016_0',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: '$uid@example.org',
      registerId: '',
      stemId: 0,
      role: role,
      givenName: givenName,
      surname: surname,
      extraNames: '',
      initials: '',
      preferredName: preferredName,
      gender: core.Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: blankAddress,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
      referenceIdentifier: referenceIdentifier,
    );

/// A Smartschool group. [sourceId] is the numeric id the Presence module knows
/// the class by (#400); `null` for a class no member payload has ever named.
core.Group ssGroup(
  String code, {
  required String name,
  bool official = true,
  int? sourceId,
}) =>
    core.Group(
      id: core.GroupId(code),
      name: name,
      description: '',
      type: official ? core.GroupType.classGroup : core.GroupType.group,
      official: official,
      sourceId: sourceId,
      origin: core.Origin.smartschool,
    );

ss.SmartschoolMembership membership(String uid, String groupCode) =>
    ss.SmartschoolMembership(uid: uid, groupId: core.GroupId(groupCode));

ss.SmartschoolSnapshot snapshot({
  List<ss.SmartschoolAccount> accounts = const [],
  List<core.Group> groups = const [],
  List<ss.SmartschoolMembership> memberships = const [],
}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026, 9, 7),
      groups: groups,
      accounts: accounts,
      memberships: memberships,
    );
