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
