import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('evaluate / describeChanges are pure (INV-40)', () {
    test('ModifySmartschoolData.describeChanges is deterministic', () {
      final action = ModifySmartschoolData(
        linkedGroup(
          wisa: wisaGroup(instituteNumber: '999999', description: 'Nieuw'),
          smartschool: ssGroup(instituteNumber: '123456', description: 'Oud'),
        ),
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

    test('describeChanges reports only the fields that drift', () {
      // Only the description drifts; the institute number already agrees.
      final action = ModifySmartschoolData(
        linkedGroup(
          wisa: wisaGroup(instituteNumber: '123456', description: 'Nieuw'),
          smartschool: ssGroup(instituteNumber: '123456', description: 'Oud'),
        ),
      );
      final change = action.describeChanges();
      expect(change.system, Origin.smartschool);
      final field = change.fields.single;
      expect(field.field, 'description');
      expect(field.before, 'Oud');
      expect(field.after, 'Nieuw');
    });

    test('DoNotImportFromWisa describes the rule it would add', () {
      final change =
          DoNotImportFromWisa(linkedGroup(wisa: wisaGroup(name: '3A')))
              .describeChanges();
      expect(change.system, Origin.wisa);
      expect(change.fields.single.field, 'DontImportClass');
      expect(change.fields.single.after, '3A');
    });

    test('evaluate does not mutate the bound record (INV-42)', () {
      final ss = ssGroup(instituteNumber: '123456', description: 'Oud');
      final group = linkedGroup(
        wisa: wisaGroup(instituteNumber: '999999', description: 'Nieuw'),
        smartschool: ss,
      );
      ModifySmartschoolData(group).evaluate();
      // The bound record is untouched.
      expect(identical(group.smartschool, ss), isTrue);
      expect(ss.instituteNumber, '123456');
      expect(ss.description, 'Oud');
    });
  });
}
