/// Pins **which** actions may be bulk-applied (#293) — the port of legacy's
/// `AccountAction.canBeAppliedToAll`.
///
/// The point of the flag is that the sanction is a property of the action, so
/// this file is the one place the whole answer is written down. Two mechanisms
/// make granting a new one a deliberate edit here:
///
/// - the `_bulkApplyable` switches are **exhaustive over the sealed families**,
///   so adding a `StudentAction` / `StaffAction` / `GroupAction` subclass makes
///   this file fail to compile until the new action is classified;
/// - each family's instance list is size-pinned, so the new action also has to
///   be added to what the assertions actually run over.
library;

import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

// ---------------------------------------------------------------------------
// The sanctioned set, one exhaustive switch per family.
// ---------------------------------------------------------------------------

/// Legacy `Action\StudentAccount\*`: the eight grants of `canBeAppliedToAll`,
/// plus `ModifyAzureSchool` and `ModifyAzureStudentEmail` — legacy passes
/// `true, true` to both, and `ModifyAzureStudentEmail` is also where the dead
/// `ChangeEmail` class's identical grant lands in this port.
bool _bulkApplyable(StudentAction a) => switch (a) {
      AddStudentToAzure() => true,
      AddStudentToSmartschool() => true,
      ModifyAzureStudentEmail() => true,
      ModifyAzureSchool() => true,
      ModifyAccountId() => true,
      ModifySmartschoolStemId() => true,
      ModifySmartschoolBirthPlace() => true,
      ModifySmartschoolStudentEmail() => true,
      MoveToSmartschoolClassGroup() => true,
      // Judgement: the operator is meant to look at the record.
      ModifyAzureName() => false,
      ModifySmartschoolName() => false,
      ModifySmartschoolStudentAddress() => false,
      // Destructive.
      UnregisterStudentFromSmartschool() => false,
      DeleteStudentFromSmartschool() => false,
      RemoveStudentFromAzure() => false,
      // Informational — cannot be applied at all.
      AzureClassGroupMembership() => false,
    };

/// Legacy `Action\StaffAccount\*` granted three; `AddToStaffGroup` is not
/// ported (the deferred `-Personeel` placement), leaving two.
bool _bulkApplyableStaff(StaffAction a) => switch (a) {
      AddStaffToAzure() => true,
      ModifySmartschoolStaffEmail() => true,
      // Legacy passes `true, false` here, unlike the student twin.
      AddStaffToSmartschool() => false,
      UpdateStaffWisaName() => false,
      SetStaffCopyCode() => false,
      DontImportStaffFromWisa() => false,
      RemoveStaffFromSmartschool() => false,
      RemoveStaffFromAzure() => false,
    };

/// The group family has no legacy answer to port — legacy's Klassen view had no
/// bulk apply — so every one of these is a decision made in #293.
bool _bulkApplyableGroup(GroupAction a) => switch (a) {
      AddToSmartschool() => true,
      ModifySmartschoolData() => true,
      CreateAzureClassGroup() => true,
      SyncAzureClassGroupMembers() => true,
      // Withheld: a blacklist is a per-class judgement, a delete takes the
      // mailbox, Team and files with it.
      DoNotImportFromWisa() => false,
      DeleteAzureClassGroup() => false,
      // Informational — cannot be applied at all.
      CreateInSmartschool() => false,
      ClassExistsAsSmartschoolGroup() => false,
      DoNotImportFromSmartschool() => false,
      AzureClassGroupWithoutClass() => false,
    };

// ---------------------------------------------------------------------------
// One instance of every action in each family. The bound records are
// irrelevant: `canApplyToAll` is a constant of the class, never of the target.
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
    RemoveStaffFromSmartschool(staff, cfg),
    RemoveStaffFromAzure(staff, cfg),
    DontImportStaffFromWisa(staff, cfg),
    UpdateStaffWisaName(staff, cfg),
    ModifySmartschoolStaffEmail(staff, cfg),
    SetStaffCopyCode(staff, cfg),
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
    ModifySmartschoolData(linked),
    CreateAzureClassGroup(linked, plan),
    SyncAzureClassGroupMembers(linked, plan),
    AzureClassGroupWithoutClass(linked),
    DeleteAzureClassGroup(linked),
  ];
}

Set<Type> _granted<T>(List<T> actions, bool Function(T) flag) => {
      for (final a in actions)
        if (flag(a)) a.runtimeType,
    };

void main() {
  group('canApplyToAll (#293)', () {
    test('the student family grants it to exactly nine actions', () {
      expect(
        _granted<StudentAction>(_studentActions(), (a) => a.canApplyToAll),
        <Type>{
          AddStudentToAzure,
          AddStudentToSmartschool,
          ModifyAzureStudentEmail,
          ModifyAzureSchool,
          ModifyAccountId,
          ModifySmartschoolStemId,
          ModifySmartschoolBirthPlace,
          ModifySmartschoolStudentEmail,
          MoveToSmartschoolClassGroup,
        },
        reason: 'legacy AccountAction(…, canBeAppliedToAll: true) — granting a '
            'new one is a deliberate edit to this test',
      );
    });

    test('the staff family grants it to exactly two actions', () {
      expect(
        _granted<StaffAction>(_staffActions(), (a) => a.canApplyToAll),
        <Type>{AddStaffToAzure, ModifySmartschoolStaffEmail},
        reason: 'legacy granted AddToAzure, ModifySmartschoolStaffEmail and '
            'AddToStaffGroup; the last is not ported',
      );
    });

    test('the group family grants it to exactly four actions', () {
      expect(
        _granted<GroupAction>(_groupActions(), (a) => a.canApplyToAll),
        <Type>{
          AddToSmartschool,
          ModifySmartschoolData,
          CreateAzureClassGroup,
          SyncAzureClassGroupMembers,
        },
        reason: 'no legacy answer to port — each of these was decided in #293',
      );
    });

    test('every action matches its recorded classification', () {
      for (final a in _studentActions()) {
        expect(a.canApplyToAll, _bulkApplyable(a), reason: '${a.runtimeType}');
      }
      for (final a in _staffActions()) {
        expect(a.canApplyToAll, _bulkApplyableStaff(a),
            reason: '${a.runtimeType}');
      }
      for (final a in _groupActions()) {
        expect(a.canApplyToAll, _bulkApplyableGroup(a),
            reason: '${a.runtimeType}');
      }
    });

    test('an informational action is never bulk-applyable', () {
      // The sanction presupposes the mechanism: canApplyToAll ⇒ canApply.
      for (final a in _studentActions()) {
        if (!a.canApply) {
          expect(a.canApplyToAll, isFalse, reason: '${a.runtimeType}');
        }
      }
      for (final a in _staffActions()) {
        if (!a.canApply) {
          expect(a.canApplyToAll, isFalse, reason: '${a.runtimeType}');
        }
      }
      for (final a in _groupActions()) {
        if (!a.canApply) {
          expect(a.canApplyToAll, isFalse, reason: '${a.runtimeType}');
        }
      }
      // Guard the guard: the families really do carry informational members, so
      // the loops above are not vacuous.
      expect(_studentActions().where((a) => !a.canApply), isNotEmpty);
      expect(_groupActions().where((a) => !a.canApply), isNotEmpty);
    });

    test('destructive actions are withheld across every family', () {
      final withheld = <Type>{
        // Students.
        UnregisterStudentFromSmartschool,
        DeleteStudentFromSmartschool,
        RemoveStudentFromAzure,
        // Staff.
        RemoveStaffFromSmartschool,
        RemoveStaffFromAzure,
        // Groups.
        DeleteAzureClassGroup,
        // The blacklists, which are destructive in effect: the record drops out
        // of the next WISA snapshot while what exists downstream survives.
        DontImportStaffFromWisa,
        DoNotImportFromWisa,
      };
      final granted = <Type>{
        ..._granted<StudentAction>(_studentActions(), (a) => a.canApplyToAll),
        ..._granted<StaffAction>(_staffActions(), (a) => a.canApplyToAll),
        ..._granted<GroupAction>(_groupActions(), (a) => a.canApplyToAll),
      };
      expect(granted.intersection(withheld), isEmpty);
    });

    test('the default is false, so a new action is conservative', () {
      // Nothing pins this but the base classes themselves; the families below
      // are the proof that "not overridden" reads as withheld.
      expect(
        _studentActions().where((a) => a.canApplyToAll),
        hasLength(9),
      );
      expect(_staffActions().where((a) => a.canApplyToAll), hasLength(2));
      expect(_groupActions().where((a) => a.canApplyToAll), hasLength(4));
    });

    test('each family list covers its whole sealed family', () {
      // A count, because the exhaustive switches above catch a *new* subclass
      // at compile time but cannot tell that it was also added here.
      expect(_studentActions().map((a) => a.runtimeType).toSet(), hasLength(16),
          reason: 'StudentAction has 16 members');
      expect(_staffActions().map((a) => a.runtimeType).toSet(), hasLength(8),
          reason: 'StaffAction has 8 members');
      expect(_groupActions().map((a) => a.runtimeType).toSet(), hasLength(10),
          reason: 'GroupAction has 10 members');
    });
  });
}
