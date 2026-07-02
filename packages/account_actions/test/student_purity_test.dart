import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = config();

  group('evaluate / describeChanges are pure (INV-40)', () {
    test('describeChanges is deterministic', () {
      final action = ModifyAccountId(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: ssAccount(accountId: 'W9'),
          azure: azureUser(),
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

    test('describeChanges reports the before/after of the change', () {
      final action = ModifyAccountId(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: ssAccount(accountId: 'W9'),
          azure: azureUser(),
        ),
        cfg,
      );
      final change = action.describeChanges();
      expect(change.system, Origin.smartschool);
      final field = change.fields.single;
      expect(field.field, 'accountId');
      expect(field.before, 'W9');
      expect(field.after, 'W1');
    });

    test('evaluate does not mutate the bound record', () {
      final ss = ssAccount(accountId: 'W9');
      final account = linked(
        wisa: wisaStudent(wisaId: 'W1'),
        smartschool: ss,
        azure: azureUser(),
      );
      ModifyAccountId(account, cfg).evaluate();
      // The bound record is untouched (INV-42).
      expect(identical(account.smartschool, ss), isTrue);
      expect(ss.accountId, 'W9');
    });
  });

  group('studentActions over a LinkedSnapshot', () {
    test('emits actions per student record, in snapshot order', () {
      final snapshot = LinkedSnapshot.fromRecords(
        accounts: [
          linked(wisa: wisaStudent(wisaId: 'A'), id: 'a'), // WISA-only → add
          fullySynced(), // clean → none
          linked(
            wisa: wisaStudent(wisaId: 'C1'),
            smartschool: ssAccount(accountId: 'C9'),
            azure: azureUser(),
            id: 'c',
          ), // wrong id → modify
        ],
        staff: const [],
        groups: const [],
      );

      final actions = studentActions(snapshot, cfg);
      expect(
        actions.map((a) => a.runtimeType),
        [AddStudentToAzure, ModifyAccountId],
      );
    });
  });
}
