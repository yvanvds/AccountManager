import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = config();

  List<Type> types(Iterable<StudentAction> actions) =>
      actions.map((a) => a.runtimeType).toList();

  group('dispatch §6.3 — missing / present branches are mutually exclusive',
      () {
    test('a fully-synced account yields no actions', () {
      expect(studentActionsFor(fullySynced(), cfg), isEmpty);
    });

    test('WISA-only student → only AddStudentToAzure', () {
      final actions = studentActionsFor(linked(wisa: wisaStudent()), cfg);
      expect(types(actions), [AddStudentToAzure]);
    });

    test('WISA + Azure, no Smartschool → only AddStudentToSmartschool', () {
      final actions = studentActionsFor(
        linked(wisa: wisaStudent(), azure: azureUser()),
        cfg,
      );
      expect(types(actions), [AddStudentToSmartschool]);
    });

    test('active Smartschool-only account → Unregister *and* Delete', () {
      final actions = studentActionsFor(
        linked(smartschool: ssAccount(status: 'actief')),
        cfg,
      );
      expect(
        types(actions),
        [UnregisterStudentFromSmartschool, DeleteStudentFromSmartschool],
      );
    });

    test('unregister and delete are mutually exclusive alternatives (#110)',
        () {
      final actions = studentActionsFor(
        linked(smartschool: ssAccount(status: 'actief')),
        cfg,
      );
      final unregister =
          actions.whereType<UnregisterStudentFromSmartschool>().single;
      final delete = actions.whereType<DeleteStudentFromSmartschool>().single;

      // Both expose the same non-null alternative group, so the UI can pair them.
      expect(unregister.alternativeGroup, smartschoolDepartureAlternative);
      expect(delete.alternativeGroup, smartschoolDepartureAlternative);
      expect(unregister.alternativeGroup, delete.alternativeGroup);

      // Unregister (keep the account) is the safe default; delete is not.
      expect(unregister.isDefaultAlternative, isTrue);
      expect(delete.isDefaultAlternative, isFalse);
    });

    test('a lone action carries no alternative group (#110)', () {
      final actions = studentActionsFor(linked(wisa: wisaStudent()), cfg);
      expect(actions.single.alternativeGroup, isNull);
    });

    test('disabled Smartschool-only account → Delete only (not Unregister)',
        () {
      final actions = studentActionsFor(
        linked(smartschool: ssAccount(status: 'uitgeschakeld')),
        cfg,
      );
      expect(types(actions), [DeleteStudentFromSmartschool]);
    });

    test('Azure-only account with the school prefix → RemoveStudentFromAzure',
        () {
      final actions = studentActionsFor(
        linked(azure: azureUser(companyName: 'SSM')),
        cfg,
      );
      expect(types(actions), [RemoveStudentFromAzure]);
    });

    test('Azure-only account for another school → no action', () {
      final actions = studentActionsFor(
        linked(azure: azureUser(companyName: 'OTHER')),
        cfg,
      );
      expect(actions, isEmpty);
    });

    test('missing-branch never emits a modify action', () {
      final actions = studentActionsFor(linked(wisa: wisaStudent()), cfg);
      expect(actions.whereType<ModifyAccountId>(), isEmpty);
      expect(actions.whereType<ModifyAzureStudentEmail>(), isEmpty);
    });
  });

  group('dispatch §6.3 — present branch emits only the relevant modify action',
      () {
    test('wrong Smartschool internal number → only ModifyAccountId', () {
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: ssAccount(accountId: 'W9'),
          azure: azureUser(),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAccountId]);
    });

    test('Azure UPN still on the base domain → only ModifyAzureStudentEmail',
        () {
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(upn: 'jan.peeters@school.example'),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAzureStudentEmail]);
    });

    test('wrong companyName → only ModifyAzureSchool', () {
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(companyName: 'WRONG'),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAzureSchool]);
    });

    test('present-branch never emits a lifecycle action', () {
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: ssAccount(accountId: 'W9'),
          azure: azureUser(),
        ),
        cfg,
      );
      expect(actions.whereType<AddStudentToAzure>(), isEmpty);
      expect(actions.whereType<DeleteStudentFromSmartschool>(), isEmpty);
    });
  });
}
