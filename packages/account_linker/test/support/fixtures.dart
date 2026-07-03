/// Test helpers for `account_linker`: terse builders for the verbose connector
/// records, a deterministic [PersonIdResolver], and a structural signature for
/// comparing [LinkedSnapshot]s (which have no `==`).
library;

import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime _fixedDate = DateTime.utc(2020, 1, 1);

const Address _blankAddress = Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

/// A WISA student carrying only the fields the linker reads (`wisaId`); the
/// rest are inert defaults.
wapi.WisaStudent wisaStudent(String wisaId) => wapi.WisaStudent(
      wisaId: WisaId(wisaId),
      classGroup: '',
      classSubGroup: '',
      name: 'Doe',
      firstName: 'Jane',
      preferredName: '',
      birthDate: _fixedDate,
      stemId: '',
      gender: Gender.female,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: _blankAddress,
      classChange: _fixedDate,
      schoolId: 1,
    );

/// A Smartschool **student** account. [accountId] holds the WISA id by
/// convention; [mail] is the Azure-UPN bridge.
ss.SmartschoolAccount ssAccount({
  required String uid,
  required String accountId,
  required String mail,
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: PersonRole.student,
      givenName: 'Jane',
      surname: 'Doe',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: _blankAddress,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
    );

/// A WISA staff member. [code] is the alphabetic surname-mnemonic that bridges
/// to Smartschool (`accountId`); [wisaId] is the distinct numeric id that
/// bridges to Azure (`employeeId`) and may be null (OQ-1).
wapi.WisaStaff wisaStaff(String code, {String? wisaId}) => wapi.WisaStaff(
      code: WisaStaffCode(code),
      wisaId: wisaId == null ? null : WisaId(wisaId),
      firstName: 'Jane',
      lastName: 'Doe',
    );

/// A Smartschool **staff** account. Unlike [ssAccount], [accountId] holds the
/// WISA staff `code` (not the wisaId) and [role] is a staff role so the linker
/// routes it to the staff population.
ss.SmartschoolAccount ssStaffAccount({
  required String uid,
  required String accountId,
  required String mail,
  PersonRole role = PersonRole.teacher,
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: role,
      givenName: 'Jane',
      surname: 'Doe',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: _blankAddress,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
    );

/// An Azure user. [companyName] equal to the school prefix marks one of the
/// school's own *students*; a [department] containing the prefix marks a
/// *staff* member (INV-22).
az.AzureUser azureUser({
  required String id,
  required String upn,
  String? employeeId,
  String? companyName,
  String? department,
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      companyName: companyName,
      department: department,
    );

/// A WISA class group. [name] + [groupName] form the `fullName` the linker
/// matches on; `groupName == '00'` (the default) means "no subgroup", so
/// `fullName == name`. [schoolCode] becomes the linked group's institute
/// number.
wapi.WisaClassGroup wisaClassGroup(
  String name, {
  String groupName = '00',
  String schoolCode = '123',
  String adminCode = '',
}) =>
    wapi.WisaClassGroup(
      name: name,
      groupName: groupName,
      description: '',
      adminCode: adminCode,
      schoolCode: schoolCode,
      schoolId: 1,
    );

/// A Smartschool class group as a [core.Group]. Matched to WISA by [name];
/// [official] must be `true` for the linker to consider it (non-official
/// organisational groups never link). [code] defaults to [name].
Group ssGroup(
  String name, {
  String? code,
  bool official = true,
}) =>
    Group(
      id: GroupId(code ?? name),
      name: name,
      description: '',
      type: GroupType.classGroup,
      official: official,
      origin: Origin.smartschool,
    );

/// An Azure group, matched to WISA by [displayName]. [id] defaults to
/// [displayName].
az.AzureGroup azureGroup(String displayName, {String? id}) => az.AzureGroup(
      id: id ?? displayName,
      displayName: displayName,
    );

wapi.WisaSnapshot wisaSnap(
  List<wapi.WisaStudent> students, {
  List<wapi.WisaStaff> staff = const [],
  List<wapi.WisaClassGroup> classGroups = const [],
}) =>
    wapi.WisaSnapshot(
      fetchedAt: _fixedDate,
      students: students,
      staff: staff,
      classGroups: classGroups,
      schools: const [],
    );

ss.SmartschoolSnapshot ssSnap(
  List<ss.SmartschoolAccount> accounts, {
  List<Group> groups = const [],
}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: _fixedDate,
      groups: groups,
      accounts: accounts,
      memberships: const [],
    );

az.AzureSnapshot azSnap(
  List<az.AzureUser> users, {
  List<az.AzureGroup> groups = const [],
}) =>
    az.AzureSnapshot(
      fetchedAt: _fixedDate,
      users: users,
      groups: groups,
    );

/// Deterministic [PersonIdResolver]: mints `p0`, `p1`, … in first-seen order
/// and caches by natural key, so repeated keys return the same id. No I/O.
class SeqResolver implements PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  PersonId resolve(String naturalKey) {
    final existing = _seen[naturalKey];
    if (existing != null) return PersonId(existing);
    final minted = 'p${_seen.length}';
    _seen[naturalKey] = minted;
    return PersonId(minted);
  }
}

/// A stable, order-sensitive textual signature of a [LinkedSnapshot] for
/// equality assertions (the type has no `==`). Captures every account's id,
/// confidence, and which systems are present (plus their keys), the warnings,
/// and the per-system counts.
List<String> structuralSignature(LinkedSnapshot snapshot) {
  String acc(LinkedAccount a) => [
        a.id.value,
        a.confidence.name,
        'w:${a.wisa?.wisaId.value ?? '-'}',
        's:${a.smartschool?.uid ?? '-'}',
        'a:${a.azure?.id ?? '-'}',
      ].join('|');

  String stf(LinkedStaff s) => [
        s.id.value,
        s.role.name,
        s.confidence.name,
        'w:${s.wisa?.code.value ?? '-'}',
        's:${s.smartschool?.uid ?? '-'}',
        'a:${s.azure?.id ?? '-'}',
      ].join('|');

  // Groups have no linker-minted id; the WISA name anchors the record when
  // present, else the Smartschool/Azure name of the orphan (#52).
  String grp(LinkedGroup g) => [
        g.confidence.name,
        'w:${g.wisa?.name ?? '-'}',
        's:${g.smartschool?.id.value ?? '-'}',
        'a:${g.azure?.id ?? '-'}',
      ].join('|');

  String warning(LinkWarning w) => switch (w) {
        ResolveDuplicateMail(:final mail, :final accounts) =>
          'dupmail:$mail:${(accounts.map((x) => x.uid).toList()..sort()).join(',')}',
      };

  return [
    for (final a in snapshot.accounts) 'acc:${acc(a)}',
    for (final s in snapshot.staff) 'stf:${stf(s)}',
    for (final g in snapshot.groups) 'grp:${grp(g)}',
    for (final w in snapshot.warnings) warning(w),
    'wisa:${snapshot.wisa.total}/${snapshot.wisa.linked}/${snapshot.wisa.unlinked}',
    'ss:${snapshot.smartschool.total}/${snapshot.smartschool.linked}/${snapshot.smartschool.unlinked}',
    'az:${snapshot.azure.total}/${snapshot.azure.linked}/${snapshot.azure.unlinked}',
  ];
}
