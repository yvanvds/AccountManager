import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = staffConfig();

  group('evaluate / describeChanges are pure (INV-40)', () {
    test('describeChanges is deterministic', () {
      final action = UpdateStaffWisaName(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT'),
          smartschool: ssStaff(accountId: 'OLD'),
          azure: azureStaff(),
        ),
        cfg,
      );
      final a = action.describeChanges();
      final b = action.describeChanges();
      expect(a.system, b.system);
      expect(a.summary, b.summary);
      expect(
        a.fields.map((f) => '${f.field}:${f.before}>${f.after}'),
        b.fields.map((f) => '${f.field}:${f.before}>${f.after}'),
      );
    });

    test('UpdateStaffWisaName reports the accountId ← WISA code change', () {
      final action = UpdateStaffWisaName(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT'),
          smartschool: ssStaff(accountId: 'OLD'),
          azure: azureStaff(),
        ),
        cfg,
      );
      final change = action.describeChanges();
      expect(change.system, Origin.smartschool);
      final field = change.fields.single;
      expect(field.field, 'accountId');
      expect(field.before, 'OLD');
      expect(field.after, 'SMIT');
    });

    test('SetStaffCopyCode pads the WISA id to four digits', () {
      final action = SetStaffCopyCode(
        linkedStaff(
          wisa: wisaStaff(wisaId: '42'),
          smartschool: ssStaff(fax: '9999'),
          azure: azureStaff(),
        ),
        cfg,
      );
      expect(action.evaluate(), isTrue);
      final field = action.describeChanges().fields.single;
      expect(field.field, 'fax');
      expect(field.after, '0042');
    });

    test(
        'SetStaffCopyCode is idempotent — an already-padded code re-evaluates '
        'to false (fixes the legacy non-convergence)', () {
      final action = SetStaffCopyCode(
        linkedStaff(
          wisa: wisaStaff(wisaId: '42'),
          smartschool: ssStaff(fax: '0042'),
          azure: azureStaff(),
        ),
        cfg,
      );
      expect(action.evaluate(), isFalse);
    });

    test('DontImportStaffFromWisa describes a WISA rule keyed on the code', () {
      final action = DontImportStaffFromWisa(
        linkedStaff(wisa: wisaStaff(code: 'SMIT')),
        cfg,
      );
      final change = action.describeChanges();
      expect(change.system, Origin.wisa);
      expect(change.fields.single.after, 'SMIT');
    });

    test('evaluate does not mutate the bound record', () {
      final ss = ssStaff(accountId: 'OLD');
      final staff = linkedStaff(
        wisa: wisaStaff(code: 'SMIT'),
        smartschool: ss,
        azure: azureStaff(),
      );
      UpdateStaffWisaName(staff, cfg).evaluate();
      // The bound record is untouched (INV-42).
      expect(identical(staff.smartschool, ss), isTrue);
      expect(ss.accountId, 'OLD');
    });
  });

  group('ModifyStaffAzureSchool stamps our prefix on `department` (#233)', () {
    ModifyStaffAzureSchool actionFor(String? department) =>
        ModifyStaffAzureSchool(
          linkedStaff(
            wisa: wisaStaff(),
            smartschool: ssStaff(),
            azure: azureStaff(department: department),
          ),
          cfg,
        );

    test('a missing department counts as differing and becomes the prefix', () {
      // The self-perpetuating case: an account with no `department` is
      // invisible to the next sync's `$filter`, so if the one action that would
      // stamp our prefix refused to fire on null, the adoption could never
      // stick. Same lesson #224 taught the student `companyName` repair.
      final action = actionFor(null);
      expect(action.evaluate(), isTrue);
      final change = action.describeChanges();
      expect(change.system, Origin.azure);
      final field = change.fields.single;
      expect(field.field, 'department');
      expect(field.before, isNull);
      expect(field.after, 'SSM');
    });

    test('another school + a subject suffix keeps the suffix', () {
      // What a move from a sibling group school leaves behind. Overwriting the
      // whole field with the bare prefix would throw away 'Wiskunde', which the
      // other school wrote and WISA cannot tell us.
      final action = actionFor('OTHER - Wiskunde');
      expect(action.evaluate(), isTrue);
      expect(action.describeChanges().fields.single.after, 'SSM - Wiskunde');
    });

    test('another school with no suffix is replaced whole', () {
      final action = actionFor('OTHER');
      expect(action.evaluate(), isTrue);
      expect(action.describeChanges().fields.single.after, 'SSM');
    });

    test('a department already carrying our prefix does not fire', () {
      expect(actionFor('SSM').evaluate(), isFalse);
      expect(actionFor('SSM - Wiskunde').evaluate(), isFalse);
      // Trimmed + case-insensitive, like every other comparison (INV-12).
      expect(actionFor('  ssm - Wiskunde ').evaluate(), isFalse);
    });

    test('it converges: the repaired value re-evaluates to false', () {
      final repaired =
          actionFor('OTHER - Wiskunde').describeChanges().fields.single.after;
      expect(actionFor(repaired).evaluate(), isFalse);
    });

    test('no configured prefix → nothing to stamp, so it never fires', () {
      // Blanking the field would only make the account harder to find than the
      // misconfiguration already makes it.
      final action = ModifyStaffAzureSchool(
        linkedStaff(
          wisa: wisaStaff(),
          smartschool: ssStaff(),
          azure: azureStaff(department: 'OTHER'),
        ),
        staffConfig(schoolPrefix: '  '),
      );
      expect(action.evaluate(), isFalse);
    });

    test('describeChanges leaves the bound Azure record untouched (INV-42)',
        () {
      final azure = azureStaff(department: 'OTHER - Wiskunde');
      final staff = linkedStaff(
        wisa: wisaStaff(),
        smartschool: ssStaff(),
        azure: azure,
      );
      ModifyStaffAzureSchool(staff, cfg).describeChanges();
      expect(identical(staff.azure, azure), isTrue);
      expect(azure.department, 'OTHER - Wiskunde');
    });
  });

  group('staffActions over a LinkedSnapshot', () {
    test('emits actions per staff record, in snapshot order', () {
      final snapshot = LinkedSnapshot.fromRecords(
        accounts: const [],
        staff: [
          linkedStaff(wisa: wisaStaff(code: 'A'), id: 'a'), // WISA-only
          fullySyncedStaff(), // clean → none
          linkedStaff(
            wisa: wisaStaff(code: 'C'),
            smartschool: ssStaff(accountId: 'OLD'),
            azure: azureStaff(),
            id: 'c',
          ), // wrong id → modify
        ],
        groups: const [],
      );

      final actions = staffActions(snapshot, cfg);
      expect(
        actions.map((a) => a.runtimeType),
        [AddStaffToAzure, DontImportStaffFromWisa, UpdateStaffWisaName],
      );
    });
  });
}
