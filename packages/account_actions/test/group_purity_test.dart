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

    test('ModifySmartschoolData reports Untis drift converging to the name',
        () {
      // Institute + description agree; only the Untis code drifted.
      final action = ModifySmartschoolData(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(untis: 'stale-untis'),
        ),
      );
      final field = action.describeChanges().fields.single;
      expect(field.field, 'untis');
      expect(field.before, 'stale-untis');
      expect(field.after, '3A');
    });

    test(
        'AddToSmartschool.describeChanges is deterministic and names the parent',
        () {
      final action = AddToSmartschool(
        linkedGroup(wisa: wisaGroup(name: '3A')),
        groupPlacement(),
      );
      final a = action.describeChanges();
      final b = action.describeChanges();
      expect(a.system, Origin.smartschool);
      expect(
        a.fields.map((f) => '${f.field}:${f.after}'),
        b.fields.map((f) => '${f.field}:${f.after}'),
      );
      expect(
        a.fields.firstWhere((f) => f.field == 'parent').after,
        'jaar-3',
      );
    });

    test('AddToSmartschool.evaluate keys on the membership signal', () {
      final group = linkedGroup(wisa: wisaGroup());
      expect(
        AddToSmartschool(group, groupPlacement(containsStudents: true))
            .evaluate(),
        isTrue,
      );
      expect(
        AddToSmartschool(group, groupPlacement(containsStudents: false))
            .evaluate(),
        isFalse,
      );
    });

    test('CreateInSmartschool.evaluate is the empty-class complement', () {
      final group = linkedGroup(wisa: wisaGroup());
      expect(
        CreateInSmartschool(group, groupPlacement(containsStudents: false))
            .evaluate(),
        isTrue,
      );
      expect(
        CreateInSmartschool(group, groupPlacement(containsStudents: true))
            .evaluate(),
        isFalse,
      );
    });

    test('neither create action evaluates once Smartschool has the name (#225)',
        () {
      final group = linkedGroup(
        wisa: wisaGroup(name: '2G'),
        smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
      );
      expect(
        AddToSmartschool(group, groupPlacement(containsStudents: true))
            .evaluate(),
        isFalse,
        reason: 'creating it would ask Smartschool for a duplicate name',
      );
      expect(
        CreateInSmartschool(group, groupPlacement(containsStudents: false))
            .evaluate(),
        isFalse,
      );
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
