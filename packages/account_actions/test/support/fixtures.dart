/// Test helpers for `account_actions`: terse builders for linked records, a
/// default [StudentActionConfig], and recording fake connector transports so
/// `apply` can be driven without a network — a dry run asserts **zero** writes
/// and a real apply asserts the exact call plus the returned mutated record.
library;

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime _fixedDate = DateTime.utc(2020, 1, 1);

const Address blankAddress = Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

const Address sampleAddress = Address(
  street: 'Kerkstraat',
  houseNumber: '1',
  postalCode: '9000',
  city: 'Gent',
  country: 'België',
);

/// The default config used by the tests: prefix `SSM`, base domain
/// `school.example` (so student UPNs live under `student.school.example`), a
/// fixed password, and the default uid builder.
StudentActionConfig config({
  String schoolPrefix = 'SSM',
  String azureDomain = 'school.example',
}) =>
    StudentActionConfig(
      schoolPrefix: schoolPrefix,
      azureDomain: azureDomain,
      newAccountPassword: () => 'FakeP4ss!',
    );

wapi.WisaStudent wisaStudent({
  String wisaId = 'W1',
  String firstName = 'Jan',
  String name = 'Peeters',
  String preferredName = '',
  String classGroup = '3A',
  String stemId = '123',
  String nationalId = '',
  String birthPlace = 'Gent',
  Address address = sampleAddress,
}) =>
    wapi.WisaStudent(
      wisaId: WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '00',
      name: name,
      firstName: firstName,
      preferredName: preferredName,
      birthDate: _fixedDate,
      stemId: stemId,
      gender: Gender.male,
      nationalId: nationalId,
      birthPlace: birthPlace,
      nationality: '',
      address: address,
      classChange: _fixedDate,
      schoolId: 1,
    );

ss.SmartschoolAccount ssAccount({
  String uid = 'jan.peeters',
  String accountId = 'W1',
  String mail = 'jan.peeters@student.school.example',
  int stemId = 123,
  String preferredName = '',
  String birthPlace = 'Gent',
  Address address = sampleAddress,
  String status = 'actief',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: stemId,
      role: PersonRole.student,
      givenName: 'Jan',
      surname: 'Peeters',
      extraNames: '',
      initials: '',
      preferredName: preferredName,
      gender: Gender.male,
      birthDate: _fixedDate,
      birthPlace: birthPlace,
      birthCountry: '',
      address: address,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: status,
    );

az.AzureUser azureUser({
  String id = 'az-1',
  String upn = 'jan.peeters@student.school.example',
  String? employeeId = 'W1',
  String displayName = 'Jan Peeters',
  String? companyName = 'SSM',
  String? department = '3A',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: displayName,
      givenName: 'Jan',
      surname: 'Peeters',
      companyName: companyName,
      department: department,
    );

/// Builds a [LinkedAccount] from optional per-system records. Omit a system to
/// simulate it missing (drives the lifecycle-action branch).
///
/// [wisaPresence] controls the ours-vs-group classification (#134): the default
/// [WisaPresence.ours] means a WISA-present student is one of ours (pre-#134
/// behaviour), while [WisaPresence.groupOnly] models a student who moved to a
/// sibling group school we don't manage. [wisaClassGroups] is the per-school
/// membership behind it — school id → the class that school's row holds this
/// person in (#334).
LinkedAccount linked({
  wapi.WisaStudent? wisa,
  ss.SmartschoolAccount? smartschool,
  az.AzureUser? azure,
  String id = 'p0',
  WisaPresence wisaPresence = WisaPresence.ours,
  Map<int, String> wisaClassGroups = const <int, String>{},
}) =>
    LinkedAccount(
      id: LinkedAccountId(id),
      role: PersonRole.student,
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      confidence: LinkConfidence.high,
      wisaPresence: wisaPresence,
      wisaClassGroups: wisaClassGroups,
    );

/// A fully-synced student present in all three systems with matching fields —
/// no student action should apply to it.
LinkedAccount fullySynced() => linked(
      wisa: wisaStudent(),
      smartschool: ssAccount(),
      azure: azureUser(),
    );

// ---------------------------------------------------------------------------
// Class-placement fixtures (#55).
// ---------------------------------------------------------------------------

/// A non-official Smartschool group node (e.g. the "Leerlingen" student root),
/// which `saveUserToClass` rejects as a move target.
Group ssGroupNode({
  String code = 'leerlingen',
  String name = 'Leerlingen',
}) =>
    Group(
      id: GroupId(code),
      name: name,
      description: '',
      type: GroupType.group,
      official: false,
      origin: Origin.smartschool,
    );

/// A [ClassPlacement] for a student. [tree] is the set of Smartschool groups
/// [ClassPlacement.resolveClass] searches by name (default: the official `3A`
/// class). [currentClass] is the student's current official class — omit for a
/// student in no class yet (a fresh account).
///
/// [ourClasses] is the WISA class inventory [ClassPlacement.isOurClass] answers
/// from (#333). It defaults to `{className}` — the placement's own target is
/// one of ours — so a test that is not about the guard reads as it did before
/// the guard existed. Pass it explicitly (`const {}`, or another school's
/// classes) to build a placement naming a class we do not have.
ClassPlacement classPlacement({
  String className = '3A',
  Group? currentClass,
  List<Group> tree = const [],
  Set<String>? ourClasses,
}) {
  final resolved = tree.isEmpty ? [ssGroup(code: '3A', name: '3A')] : tree;
  final byName = {for (final g in resolved) g.name: g};
  final ours = ourClasses ?? {className};
  return ClassPlacement(
    className: className,
    currentClass: currentClass,
    resolveClass: (name) => byName[name],
    isOurClass: ours.contains,
  );
}

// ---------------------------------------------------------------------------
// Staff fixtures.
// ---------------------------------------------------------------------------

/// The default staff config: prefix `SSM`, base domain `school.example` (staff
/// live on the base domain, unlike students), a fixed password, default uid
/// builder.
StaffActionConfig staffConfig({
  String schoolPrefix = 'SSM',
  String azureDomain = 'school.example',
}) =>
    StaffActionConfig(
      schoolPrefix: schoolPrefix,
      azureDomain: azureDomain,
      newAccountPassword: () => 'FakeP4ss!',
    );

wapi.WisaStaff wisaStaff({
  String code = 'SMIT',
  String? wisaId = '42',
  String firstName = 'Anna',
  String lastName = 'Smit',
}) =>
    wapi.WisaStaff(
      code: WisaStaffCode(code),
      wisaId: wisaId == null ? null : WisaId(wisaId),
      firstName: firstName,
      lastName: lastName,
    );

/// A Smartschool staff account (role `teacher`). Defaults line up with
/// [wisaStaff] / [azureStaff] so a [fullySyncedStaff] triggers no action:
/// `accountId` == staff code, `fax` == the zero-padded `wisaId`, `mail` == UPN.
ss.SmartschoolAccount ssStaff({
  String uid = 'anna.smit',
  String accountId = 'SMIT',
  String mail = 'anna.smit@school.example',
  String fax = '0042',
  String status = 'actief',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: PersonRole.teacher,
      givenName: 'Anna',
      surname: 'Smit',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: blankAddress,
      mobilePhone: '',
      homePhone: '',
      fax: fax,
      untisId: '',
      status: status,
    );

az.AzureUser azureStaff({
  String id = 'az-s1',
  String upn = 'anna.smit@school.example',
  String? employeeId = '42',
  String displayName = 'Anna Smit',
  String? department = 'SSM',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: displayName,
      givenName: 'Anna',
      surname: 'Smit',
      department: department,
    );

/// Builds a [LinkedStaff] from optional per-system records. Omit a system to
/// simulate it missing (drives the lifecycle-action branch).
LinkedStaff linkedStaff({
  wapi.WisaStaff? wisa,
  ss.SmartschoolAccount? smartschool,
  az.AzureUser? azure,
  String id = 's0',
}) =>
    LinkedStaff(
      id: LinkedAccountId(id),
      role: PersonRole.teacher,
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      confidence: LinkConfidence.high,
    );

/// A fully-synced staff member present in all three systems with matching
/// fields — no staff action should apply to it.
LinkedStaff fullySyncedStaff() => linkedStaff(
      wisa: wisaStaff(),
      smartschool: ssStaff(),
      azure: azureStaff(),
    );

// ---------------------------------------------------------------------------
// Group fixtures.
// ---------------------------------------------------------------------------

/// A WISA-side canonical [Group], as the linker's `_wisaToCoreGroup` projects a
/// class group: named by its `fullName`, always an official class, `schoolCode`
/// as the institute number, `adminCode` as the admin number, no tree edge and
/// no Untis code.
Group wisaGroup({
  String name = '3A',
  String description = 'Klas 3A',
  String? instituteNumber = '123456',
  int? adminNumber = 7,
}) =>
    Group(
      id: GroupId(name),
      name: name,
      description: description,
      type: GroupType.classGroup,
      official: true,
      instituteNumber: instituteNumber,
      adminNumber: adminNumber,
      origin: Origin.wisa,
    );

/// A Smartschool-side canonical [Group] (an official class), with a tree parent
/// and admin number the WISA side lacks. Defaults line up with [wisaGroup] so a
/// [fullySyncedGroup] triggers no action — including [untis], which defaults to
/// [name] (no Untis drift); pass a different value to force drift.
Group ssGroup({
  String code = '3A',
  String name = '3A',
  String description = 'Klas 3A',
  String? instituteNumber = '123456',
  int? adminNumber = 7,
  String? parentId = 'jaar-3',
  String? untis,
  int? sourceId,
}) =>
    Group(
      id: GroupId(code),
      name: name,
      description: description,
      type: GroupType.classGroup,
      official: true,
      parentId: parentId == null ? null : GroupId(parentId),
      instituteNumber: instituteNumber,
      adminNumber: adminNumber,
      untis: untis ?? name,
      sourceId: sourceId,
      origin: Origin.smartschool,
    );

/// The logical parent [AddToSmartschool] hangs a new class under — legacy
/// `GroupManager.GetLogicalParent` resolved through `Root.FindByCode`. A
/// non-official year/grade node in the Smartschool tree.
Group ssParentGroup({String code = 'jaar-3', String name = 'Derde jaar'}) =>
    Group(
      id: GroupId(code),
      name: name,
      description: '',
      type: GroupType.group,
      official: false,
      origin: Origin.smartschool,
    );

/// A [GroupPlacement] for a WISA-only class. Defaults to a populated class
/// (`containsStudents: true`) with a resolvable parent — the [AddToSmartschool]
/// happy path. Pass `containsStudents: false` for the [CreateInSmartschool]
/// case, or `withParent: false` to simulate an unresolvable parent.
GroupPlacement groupPlacement({
  bool containsStudents = true,
  Group? parent,
  bool withParent = true,
}) =>
    GroupPlacement(
      containsStudents: containsStudents,
      parent: parent ?? (withParent ? ssParentGroup() : null),
    );

/// Builds a [LinkedGroup] from optional per-system records. Omit a system to
/// simulate the class missing there. [className] is the **bare** class name the
/// Office 365 group is named after (#228); it defaults to the WISA name, which
/// is right for every class that has no sub-groups.
LinkedGroup linkedGroup({
  Group? wisa,
  Group? smartschool,
  Group? smartschoolNamesake,
  az.AzureGroup? azure,
  String? className,
  LinkConfidence confidence = LinkConfidence.high,
}) =>
    LinkedGroup(
      wisa: wisa,
      smartschool: smartschool,
      smartschoolNamesake: smartschoolNamesake,
      azure: azure,
      className: className ?? wisa?.name,
      confidence: confidence,
    );

/// An Office 365 **class** group as this app creates one (#228): a mail-enabled
/// unified group whose display name and mail nickname are both
/// `<prefix>-<class>`.
az.AzureGroup azureClassGroup(
  String className, {
  String prefix = 'SSM',
  String domain = 'student.school.example',
  String? id,
  List<String> memberIds = const [],
}) =>
    az.AzureGroup(
      id: id ?? 'az-$prefix-$className',
      displayName: '$prefix-$className',
      mail: '$prefix-$className@$domain',
      mailNickname: '$prefix-$className',
      mailEnabled: true,
      groupTypes: const ['Unified'],
      memberIds: memberIds,
    );

/// An Office 365 class group somebody made by hand as a **mail-enabled security
/// group** (#331) — `SSM-1A` in the live tenant, and the one shape among the
/// school's 372 prefixed groups whose membership Graph refuses to write.
///
/// Identical to [azureClassGroup] in everything an operator can see: same name,
/// same nickname, same address. Only `securityEnabled` + the empty `groupTypes`
/// tell them apart, which is exactly why the app proposed a roster sync on it
/// every pass and every one of the 38 changes came back refused.
az.AzureGroup azureMailEnabledSecurityClassGroup(
  String className, {
  String prefix = 'SSM',
  String domain = 'student.school.example',
  String? id,
  List<String> memberIds = const [],
}) =>
    az.AzureGroup(
      id: id ?? 'az-$prefix-$className',
      displayName: '$prefix-$className',
      mail: '$prefix-$className@$domain',
      mailNickname: '$prefix-$className',
      mailEnabled: true,
      securityEnabled: true,
      memberIds: memberIds,
    );

/// An [AzureClassGroupPlan] for one class. Defaults to the owner record of a
/// populated class with membership already in sync; pass [membersToAdd] /
/// [membersToRemove] to make the roster differ, or `owner: false` for a
/// sub-group record that must raise nothing.
AzureClassGroupPlan azurePlan({
  String className = '3A',
  String prefix = 'SSM',
  String domain = 'student.school.example',
  bool owner = true,
  bool containsStudents = true,
  List<String> membersToAdd = const [],
  List<String> membersToRemove = const [],
}) =>
    AzureClassGroupPlan(
      className: className,
      displayName: '$prefix-$className',
      mailNickname: '$prefix-$className',
      mail: '$prefix-$className@$domain',
      owner: owner,
      containsStudents: containsStudents,
      membersToAdd: membersToAdd,
      membersToRemove: membersToRemove,
    );

/// A class present and in sync in both WISA and Smartschool — no group action
/// should apply to it.
LinkedGroup fullySyncedGroup() => linkedGroup(
      wisa: wisaGroup(),
      smartschool: ssGroup(),
    );

// ---------------------------------------------------------------------------
// Recording fake transports.
// ---------------------------------------------------------------------------

/// Records every Smartschool SOAP call and replies with a configurable integer
/// result (default `0` = success), so `apply` can run offline.
class RecordingSmartschoolTransport implements ss.SmartschoolSoapTransport {
  /// The `SOAPAction` header of every call, in order (contains the method
  /// name). Empty after a dry run.
  final List<String> soapActions = [];

  /// The request envelope of every call, in order — so a test can assert which
  /// record a write was addressed to, not merely that a write happened.
  final List<String> envelopes = [];

  /// When set, the integer result to return (non-zero = failure). Applied to
  /// every write for which [resultFor] returns null.
  final int resultCode;

  /// Optional per-call override: given a `SOAPAction` header, returns the
  /// integer result for that call (non-zero = failure), or null to fall back to
  /// [resultCode]. Lets a test make one method succeed and another fail (e.g.
  /// `saveAccount` ok but `saveUserToClass` failing).
  final int? Function(String soapAction)? resultFor;

  /// Optional per-call override that makes a call **throw** instead of
  /// answering at all: given a `SOAPAction` header, returns the error to throw,
  /// or null to answer normally (#343).
  ///
  /// A result code models Smartschool saying "no"; this models the wire coming
  /// apart — a dropped connection, a gateway error, XML that does not parse.
  /// The two take different branches in the caller, and only this one used to
  /// escape a best-effort step and fail the action around it.
  final Object? Function(String soapAction)? throwFor;

  RecordingSmartschoolTransport({
    this.resultCode = 0,
    this.resultFor,
    this.throwFor,
  });

  bool calledMethod(String method) =>
      soapActions.any((a) => a.contains(method));

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    soapActions.add(soapAction);
    envelopes.add(envelope);
    // Recorded first: the call went out, it just never came back — a test must
    // still be able to assert that the write was attempted.
    final failure = throwFor?.call(soapAction);
    if (failure != null) throw failure;
    final code = resultFor?.call(soapAction) ?? resultCode;
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope '
        'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><response><return>$code</return></response>'
        '</soap:Body></soap:Envelope>';
  }
}

/// Records every Graph request and replies from an injected [handler] (default:
/// `204 No Content`, Graph's reply to PATCH/DELETE).
class RecordingGraphTransport implements az.GraphTransport {
  final List<az.GraphRequest> requests = [];
  final az.GraphResponse Function(az.GraphRequest request)? handler;

  RecordingGraphTransport({this.handler});

  bool sent(String method, {String? pathContains}) => requests.any(
        (r) =>
            r.method == method &&
            (pathContains == null || r.url.path.contains(pathContains)),
      );

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    if (handler != null) return handler!(request);
    return const az.GraphResponse(statusCode: 204);
  }
}

ss.SmartschoolConnector smartschoolConnector(
  RecordingSmartschoolTransport transport,
) =>
    ss.SmartschoolConnector.fromParts(
      site: 'demo',
      accessCode: 'secret',
      transport: transport,
    );

az.AzureConnector azureConnector(RecordingGraphTransport transport) =>
    az.AzureConnector(
      credentials: az.AzureCredentials(
        clientId: 'c',
        tenantId: 't',
        azureDomain: 'school.example',
        schoolPrefix: 'SSM',
      ),
      authProvider: const az.StaticAuthProvider('token'),
      transport: transport,
    );
