import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = staffConfig();

  List<Type> types(Iterable<StaffAction> actions) =>
      actions.map((a) => a.runtimeType).toList();

  group('dispatch §6.3 — missing / present branches are mutually exclusive',
      () {
    test('a fully-synced staff member yields no actions', () {
      expect(staffActionsFor(fullySyncedStaff(), cfg), isEmpty);
    });

    test('WISA-only staff → AddStaffToAzure and DontImportStaffFromWisa', () {
      final actions = staffActionsFor(linkedStaff(wisa: wisaStaff()), cfg);
      expect(types(actions), [AddStaffToAzure, DontImportStaffFromWisa]);
    });

    test('WISA + Azure, no Smartschool → AddStaffToSmartschool and DontImport',
        () {
      final actions = staffActionsFor(
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        cfg,
      );
      expect(types(actions), [AddStaffToSmartschool, DontImportStaffFromWisa]);
    });

    test('Smartschool-only staff → only RemoveStaffFromSmartschool', () {
      final actions = staffActionsFor(
        linkedStaff(smartschool: ssStaff()),
        cfg,
      );
      expect(types(actions), [RemoveStaffFromSmartschool]);
    });

    test('Azure-only staff → only RemoveStaffFromAzure', () {
      final actions = staffActionsFor(
        linkedStaff(azure: azureStaff()),
        cfg,
      );
      expect(types(actions), [RemoveStaffFromAzure]);
    });

    test('missing-branch never emits a modify action', () {
      final actions = staffActionsFor(linkedStaff(wisa: wisaStaff()), cfg);
      expect(actions.whereType<UpdateStaffWisaName>(), isEmpty);
      expect(actions.whereType<ModifySmartschoolStaffEmail>(), isEmpty);
      expect(actions.whereType<SetStaffCopyCode>(), isEmpty);
      expect(actions.whereType<ModifyStaffAzureSchool>(), isEmpty);
    });

    test(
        'an adopted account with another school\'s department is not repaired '
        'until the record is complete (#233)', () {
      // WISA + Azure, no Smartschool — the state #231's back-fill leaves a
      // moved staff member in. The mutually exclusive branches (§6.3) mean the
      // department repair waits for the pass after AddStaffToSmartschool, the
      // same way the student `ModifyAzureSchool` does.
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(),
          azure: azureStaff(department: 'OTHER - Wiskunde'),
        ),
        cfg,
      );
      expect(types(actions), [AddStaffToSmartschool, DontImportStaffFromWisa]);
    });
  });

  group('dispatch §6.3 — present branch emits only the relevant modify action',
      () {
    test('wrong Smartschool internal number → only UpdateStaffWisaName', () {
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT'),
          smartschool: ssStaff(accountId: 'OLD'),
          azure: azureStaff(),
        ),
        cfg,
      );
      expect(types(actions), [UpdateStaffWisaName]);
    });

    test('Smartschool mail on the base domain but wrong → only email modify',
        () {
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(),
          smartschool: ssStaff(mail: 'anna.old@school.example'),
          azure: azureStaff(upn: 'anna.smit@school.example'),
        ),
        cfg,
      );
      expect(types(actions), [ModifySmartschoolStaffEmail]);
    });

    test('Smartschool mail on another domain → no email modify', () {
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(),
          smartschool: ssStaff(mail: 'anna.smit@other.example'),
          azure: azureStaff(),
        ),
        cfg,
      );
      expect(actions, isEmpty);
    });

    test('wrong copy code → only SetStaffCopyCode', () {
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(wisaId: '42'),
          smartschool: ssStaff(fax: '9999'),
          azure: azureStaff(),
        ),
        cfg,
      );
      expect(types(actions), [SetStaffCopyCode]);
    });

    test(
        "an Azure department naming another school → only "
        'ModifyStaffAzureSchool (#233)', () {
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(),
          smartschool: ssStaff(),
          azure: azureStaff(department: 'OTHER - Wiskunde'),
        ),
        cfg,
      );
      expect(types(actions), [ModifyStaffAzureSchool]);
    });

    test('a fully-synced staff member with our prefix raises no repair (#233)',
        () {
      // The default fixture's `department` is exactly the prefix, so the new
      // action must not turn every clean staff record into a pending item.
      expect(
        staffActionsFor(fullySyncedStaff(), cfg)
            .whereType<ModifyStaffAzureSchool>(),
        isEmpty,
      );
    });

    test('present-branch never emits a lifecycle action', () {
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT'),
          smartschool: ssStaff(accountId: 'OLD'),
          azure: azureStaff(),
        ),
        cfg,
      );
      expect(actions.whereType<AddStaffToAzure>(), isEmpty);
      expect(actions.whereType<RemoveStaffFromSmartschool>(), isEmpty);
      expect(actions.whereType<DontImportStaffFromWisa>(), isEmpty);
    });
  });
}
