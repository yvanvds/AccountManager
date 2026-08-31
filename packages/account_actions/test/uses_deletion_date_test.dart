/// Pins **which** actions are stamped with the uitschrijvingsdatum (#394).
///
/// The flag is a property of the action so no screen has to keep a list of
/// class names, which means this file is the one place the whole answer is
/// written down. Two mechanisms make declaring a new one a deliberate edit
/// here, exactly as `can_apply_to_all_test.dart` does for the bulk sanction:
///
/// - the `_dated` switches are **exhaustive over the sealed families**, so
///   adding a `StudentAction` / `StaffAction` / `GroupAction` subclass makes
///   this file fail to compile until the new action is classified;
/// - each family's instance list is size-pinned, so the new action also has to
///   be added to what the assertions actually run over.
///
/// The other half of the pin is at the wire: a declared action really does put
/// the date it was given into the envelope, and an undeclared one really does
/// ignore it. A flag that said "asks for a date" while the write dropped it
/// would be worse than no flag at all.
library;

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

// ---------------------------------------------------------------------------
// The dated set, one exhaustive switch per family.
// ---------------------------------------------------------------------------

/// Smartschool records an official date for the two resolutions of a departed
/// pupil, and for nothing else in the student family. `RemoveStudentFromAzure`
/// is destructive and carries none: Graph records no such thing.
bool _dated(StudentAction a) => switch (a) {
      UnregisterStudentFromSmartschool() => true,
      DeleteStudentFromSmartschool() => true,
      RemoveStudentFromAzure() => false,
      AddStudentToAzure() => false,
      AddStudentToSmartschool() => false,
      ModifyAzureStudentEmail() => false,
      ModifyAzureName() => false,
      ModifyAzureSchool() => false,
      ModifyAzureJobTitle() => false,
      ModifyAzureDepartment() => false,
      ModifySmartschoolStudentAddress() => false,
      ModifyAccountId() => false,
      ModifySmartschoolStemId() => false,
      ModifySmartschoolBirthPlace() => false,
      MoveToSmartschoolClassGroup() => false,
      ModifySmartschoolStudentEmail() => false,
      ModifySmartschoolName() => false,
      AzureClassGroupMembership() => false,
    };

/// One staff action deletes a Smartschool account, and it is the only one that
/// names an official date. The conservative half of the same departure
/// ([DeactivateStaffInSmartschool]) writes a status field.
bool _datedStaff(StaffAction a) => switch (a) {
      RemoveStaffFromSmartschool() => true,
      DeactivateStaffInSmartschool() => false,
      // The retirement *command* writes a WISA import rule. The Smartschool
      // half it unlocks may be dated; a chained follow-up is named, never
      // counted (see `ApplyScope.chained`), and this flag answers for the
      // action itself.
      RetireStaffMember() => false,
      AddStaffToAzure() => false,
      // Its group removal passes an explicit `now` (#374) and deliberately not
      // the uitschrijvingsdatum: it is a membership end inside a *creation*
      // chain, not an official departure. See the comment at the call site.
      AddStaffToSmartschool() => false,
      ReleaseStaffFromAzureSchool() => false,
      RemoveStaffFromAzure() => false,
      DontImportStaffFromWisa() => false,
      UpdateStaffWisaName() => false,
      ModifySmartschoolStaffEmail() => false,
      SetStaffCopyCode() => false,
      ClaimStaffForAzureSchool() => false,
    };

/// No group action is dated, and the switch exists so that stays a statement:
/// a class is a container, not a person, and Smartschool records no official
/// departure date for one.
bool _datedGroup(GroupAction a) => switch (a) {
      DoNotImportFromWisa() => false,
      AddToSmartschool() => false,
      CreateInSmartschool() => false,
      ClassExistsAsSmartschoolGroup() => false,
      DoNotImportFromSmartschool() => false,
      DeleteSmartschoolClass() => false,
      ModifySmartschoolData() => false,
      CreateAzureClassGroup() => false,
      SyncAzureClassGroupMembers() => false,
      AzureClassGroupNotManageable() => false,
      AzureClassGroupWithoutClass() => false,
      DeleteAzureClassGroup() => false,
    };

// ---------------------------------------------------------------------------
// One instance of every action in each family. The bound records are
// irrelevant: `usesDeletionDate` is a constant of the class, never of the
// target.
// ---------------------------------------------------------------------------

List<StudentAction> _studentActions() {
  final cfg = config();
  final account = fullySynced();
  final placement = classPlacement();
  const azurePlacement = AzureClassPlacement(className: '3A');
  return <StudentAction>[
    AddStudentToAzure(account, cfg),
    AddStudentToSmartschool(account, cfg, placement: placement),
    UnregisterStudentFromSmartschool(account, cfg),
    DeleteStudentFromSmartschool(account, cfg),
    RemoveStudentFromAzure(account, cfg),
    ModifyAzureStudentEmail(account, cfg),
    ModifyAzureName(account, cfg),
    ModifyAzureSchool(account, cfg),
    ModifyAzureJobTitle(account, cfg),
    ModifyAzureDepartment(account, cfg),
    ModifySmartschoolStudentAddress(account, cfg),
    ModifyAccountId(account, cfg),
    ModifySmartschoolStemId(account, cfg),
    ModifySmartschoolBirthPlace(account, cfg),
    MoveToSmartschoolClassGroup(account, cfg, placement),
    AzureClassGroupMembership(account, cfg, azurePlacement),
    ModifySmartschoolStudentEmail(account, cfg),
    ModifySmartschoolName(account, cfg),
  ];
}

List<StaffAction> _staffActions() {
  final cfg = staffConfig();
  final staff = fullySyncedStaff();
  return <StaffAction>[
    AddStaffToAzure(staff, cfg),
    AddStaffToSmartschool(staff, cfg),
    RetireStaffMember(staff, cfg),
    DeactivateStaffInSmartschool(staff, cfg),
    RemoveStaffFromSmartschool(staff, cfg),
    ReleaseStaffFromAzureSchool(staff, cfg),
    RemoveStaffFromAzure(staff, cfg),
    DontImportStaffFromWisa(staff, cfg),
    UpdateStaffWisaName(staff, cfg),
    ModifySmartschoolStaffEmail(staff, cfg),
    SetStaffCopyCode(staff, cfg),
    ClaimStaffForAzureSchool(staff, cfg),
  ];
}

List<GroupAction> _groupActions() {
  final linked = linkedGroup(
    wisa: wisaGroup(),
    smartschool: ssGroup(),
    smartschoolNamesake: ssGroup(),
    azure: azureClassGroup('3A'),
  );
  final placement = groupPlacement();
  final plan = azurePlan();
  return <GroupAction>[
    DoNotImportFromWisa(linked),
    AddToSmartschool(linked, placement),
    CreateInSmartschool(linked, placement),
    ClassExistsAsSmartschoolGroup(linked),
    DoNotImportFromSmartschool(linked),
    DeleteSmartschoolClass(linked),
    ModifySmartschoolData(linked),
    CreateAzureClassGroup(linked, plan),
    SyncAzureClassGroupMembers(linked, plan),
    AzureClassGroupNotManageable(linked, plan),
    AzureClassGroupWithoutClass(linked),
    DeleteAzureClassGroup(linked),
  ];
}

void main() {
  group('usesDeletionDate (#394)', () {
    test('exactly three actions across all three families declare it', () {
      final declared = <Type>{
        for (final a in _studentActions())
          if (a.usesDeletionDate) a.runtimeType,
        for (final a in _staffActions())
          if (a.usesDeletionDate) a.runtimeType,
        for (final a in _groupActions())
          if (a.usesDeletionDate) a.runtimeType,
      };
      expect(
        declared,
        <Type>{
          UnregisterStudentFromSmartschool,
          DeleteStudentFromSmartschool,
          RemoveStaffFromSmartschool,
        },
        reason: 'these are the three writes that read options.deletionDate — '
            'declaring a new one is a deliberate edit to this test',
      );
    });

    test('every action matches its recorded classification', () {
      for (final a in _studentActions()) {
        expect(a.usesDeletionDate, _dated(a), reason: '${a.runtimeType}');
      }
      for (final a in _staffActions()) {
        expect(a.usesDeletionDate, _datedStaff(a), reason: '${a.runtimeType}');
      }
      for (final a in _groupActions()) {
        expect(a.usesDeletionDate, _datedGroup(a), reason: '${a.runtimeType}');
      }
    });

    test('the default is false, so a new action is silent about dates', () {
      expect(_studentActions().where((a) => a.usesDeletionDate), hasLength(2));
      expect(_staffActions().where((a) => a.usesDeletionDate), hasLength(1));
      expect(_groupActions().where((a) => a.usesDeletionDate), isEmpty);
    });

    test('each family list covers its whole sealed family', () {
      // A count, because the exhaustive switches above catch a *new* subclass
      // at compile time but cannot tell that it was also added here.
      expect(_studentActions().map((a) => a.runtimeType).toSet(), hasLength(18),
          reason: 'StudentAction has 18 members');
      expect(_staffActions().map((a) => a.runtimeType).toSet(), hasLength(12),
          reason: 'StaffAction has 12 members');
      expect(_groupActions().map((a) => a.runtimeType).toSet(), hasLength(12),
          reason: 'GroupAction has 12 members');
    });
  });

  group('the declared date reaches the wire (#394)', () {
    // The flag is only worth anything if the write really carries the date it
    // was handed. Smartschool's own `Y-M-D`, unpadded.
    final DateTime departed = DateTime(2026, 3, 14);

    test('unregisterStudent sends the answered date, not today', () async {
      final soap = RecordingSmartschoolTransport();
      final connectors = Connectors(smartschool: smartschoolConnector(soap));
      final account = linked(
        wisa: wisaStudent(),
        smartschool: ssAccount(status: 'actief'),
        azure: azureUser(companyName: 'SSM'),
        wisaPresence: WisaPresence.groupOnly,
        wisaClassGroups: const {2: '3A'},
      );
      final unregister = studentActionsFor(account, config())
          .whereType<UnregisterStudentFromSmartschool>()
          .single;

      final result = await unregister.apply(
        connectors,
        ApplyOptions(deletionDate: departed),
      );

      expect(result.outcome, ActionOutcome.applied);
      expect(
        soap.envelopes.single,
        contains('>2026-3-14</officialDate>'),
      );
    });

    test('an unanswered date still falls back to today', () async {
      final soap = RecordingSmartschoolTransport();
      final connectors = Connectors(smartschool: smartschoolConnector(soap));
      final account = linked(
        wisa: wisaStudent(),
        smartschool: ssAccount(status: 'actief'),
        azure: azureUser(companyName: 'SSM'),
        wisaPresence: WisaPresence.groupOnly,
        wisaClassGroups: const {2: '3A'},
      );
      final unregister = studentActionsFor(account, config())
          .whereType<UnregisterStudentFromSmartschool>()
          .single;
      final DateTime now = DateTime.now();

      await unregister.apply(connectors, const ApplyOptions());

      expect(
        soap.envelopes.single,
        contains('>${now.year}-${now.month}-${now.day}</officialDate>'),
        reason: 'the pre-#394 behaviour survives for a pass that asked nothing',
      );
    });

    test('deleteUser sends the answered date instead of the 1-1-1 sentinel',
        () async {
      final soap = RecordingSmartschoolTransport();
      final connectors = Connectors(smartschool: smartschoolConnector(soap));
      final account = linked(
        wisa: wisaStudent(),
        smartschool: ssAccount(status: 'actief'),
        azure: azureUser(companyName: 'SSM'),
        wisaPresence: WisaPresence.groupOnly,
        wisaClassGroups: const {2: '3A'},
      );
      final delete = studentActionsFor(account, config())
          .whereType<DeleteStudentFromSmartschool>()
          .single;

      final result = await delete.apply(
        connectors,
        ApplyOptions(deletionDate: departed),
      );

      expect(result.outcome, ActionOutcome.applied);
      expect(
        soap.envelopes.single,
        contains('>2026-3-14</officialDate>'),
      );
    });
  });
}
