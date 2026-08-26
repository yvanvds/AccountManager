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
      // No legacy answer to port — decided in #358, alongside its
      // `ModifyAzureSchool` twin: the two halves of one licensing rule, both
      // mechanical consequences of the school the student is enrolled in.
      ModifyAzureJobTitle() => true,
      // No legacy answer either — decided in #359. Copying WISA's class onto
      // the profile field is judgement-free, and it arrives a whole class at a
      // time when a cohort moves up a year.
      ModifyAzureDepartment() => true,
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
/// ported (the deferred `-Personeel` placement), leaving two — plus one grant
/// made here, `ClaimStaffForAzureSchool` (#373), which has no legacy twin.
bool _bulkApplyableStaff(StaffAction a) => switch (a) {
      AddStaffToAzure() => true,
      ModifySmartschoolStaffEmail() => true,
      // Not a legacy grant: an intake of staff adopted from sibling group
      // schools is a real cohort, the trigger is a fact WISA already states, the
      // write is additive (every other `department` entry survives), and a
      // mistaken claim is undone by `ReleaseStaffFromAzureSchool` on the next
      // pass. It lands with `AddStaffToAzure`, which stamps the same prefix in
      // bulk on a create, and not with the #349 departure pair.
      ClaimStaffForAzureSchool() => true,
      // Legacy passes `true, false` here, unlike the student twin.
      AddStaffToSmartschool() => false,
      UpdateStaffWisaName() => false,
      SetStaffCopyCode() => false,
      DontImportStaffFromWisa() => false,
      // The departure family (#349). Every member is withheld on purpose: a
      // retirement has to be read and judged one name at a time, which is the
      // safety property the command was designed around.
      RetireStaffMember() => false,
      DeactivateStaffInSmartschool() => false,
      RemoveStaffFromSmartschool() => false,
      ReleaseStaffFromAzureSchool() => false,
      RemoveStaffFromAzure() => false,
    };

/// The group family has no legacy answer to port — legacy's Klassen view had no
/// bulk apply — so every one of these is a decision made in #293.
bool _bulkApplyableGroup(GroupAction a) => switch (a) {
      AddToSmartschool() => true,
      ModifySmartschoolData() => true,
      CreateAzureClassGroup() => true,
      SyncAzureClassGroupMembers() => true,
      // Withheld: a blacklist is a per-class judgement, and a delete takes the
      // mailbox, Team and files with it — or, in Smartschool, the class and
      // everyone's membership of it.
      DoNotImportFromWisa() => false,
      DeleteAzureClassGroup() => false,
      DeleteSmartschoolClass() => false,
      // Informational — cannot be applied at all.
      CreateInSmartschool() => false,
      ClassExistsAsSmartschoolGroup() => false,
      DoNotImportFromSmartschool() => false,
      AzureClassGroupWithoutClass() => false,
      AzureClassGroupNotManageable() => false,
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

Set<Type> _granted<T>(List<T> actions, bool Function(T) flag) => {
      for (final a in actions)
        if (flag(a)) a.runtimeType,
    };

void main() {
  group('canApplyToAll (#293)', () {
    test('the student family grants it to exactly eleven actions', () {
      expect(
        _granted<StudentAction>(_studentActions(), (a) => a.canApplyToAll),
        <Type>{
          AddStudentToAzure,
          AddStudentToSmartschool,
          ModifyAzureStudentEmail,
          ModifyAzureSchool,
          ModifyAzureJobTitle,
          ModifyAzureDepartment,
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

    test('the staff family grants it to exactly three actions', () {
      expect(
        _granted<StaffAction>(_staffActions(), (a) => a.canApplyToAll),
        <Type>{
          AddStaffToAzure,
          ModifySmartschoolStaffEmail,
          ClaimStaffForAzureSchool,
        },
        reason: 'legacy granted AddToAzure, ModifySmartschoolStaffEmail and '
            'AddToStaffGroup; the last is not ported. ClaimStaffForAzureSchool '
            'is a grant made in #373, not a legacy one',
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
        // Staff — the whole departure family (#349), destructive in effect even
        // where it keeps the account: a release strikes our claim out of a
        // shared Azure field, and a retirement opens the rest of the chain.
        RetireStaffMember,
        DeactivateStaffInSmartschool,
        RemoveStaffFromSmartschool,
        ReleaseStaffFromAzureSchool,
        RemoveStaffFromAzure,
        // Groups.
        DeleteAzureClassGroup,
        DeleteSmartschoolClass,
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
        hasLength(11),
      );
      expect(_staffActions().where((a) => a.canApplyToAll), hasLength(3));
      expect(_groupActions().where((a) => a.canApplyToAll), hasLength(4));
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
}
