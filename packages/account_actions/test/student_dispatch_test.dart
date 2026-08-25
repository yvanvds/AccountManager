import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
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

    test('the WISA-only create declares its Smartschool follow-up (#230)', () {
      // Provisioning a new student is a chain the dispatcher cannot express:
      // AddStudentToSmartschool needs the Azure UPN as the new account's mail,
      // so it evaluates false until the Azure account exists. Naming the
      // follow-up here is what lets the State layer run it straight after the
      // create, against the relinked record — one click, both accounts.
      final actions = studentActionsFor(linked(wisa: wisaStudent()), cfg);
      final create = actions.single as AddStudentToAzure;
      expect(create.unlocks, <Type>{AddStudentToSmartschool});
    });

    test('the WISA-only create names the system its follow-up writes (#234)',
        () {
      // The apply-confirmation dialog has to name Smartschool for this one
      // action, and it cannot read it off the follow-up: the follow-up does not
      // exist until the create has run and relinked. So the action declares it
      // — and this pins the declaration against the follow-up's own ChangeSet,
      // which is the thing that would otherwise silently drift.
      final create = studentActionsFor(linked(wisa: wisaStudent()), cfg).single
          as AddStudentToAzure;
      final followUp = studentActionsFor(
        linked(wisa: wisaStudent(), azure: azureUser()),
        cfg,
      ).single as AddStudentToSmartschool;
      expect(create.unlockedSystems, <Origin>{Origin.smartschool});
      expect(
          create.unlockedSystems, <Origin>{followUp.describeChanges().system});
    });

    test('the Smartschool create ends the chain (#230)', () {
      // Nothing follows it: the record is complete afterwards, so the next pass
      // is the ordinary modify branch, not another link of this chain.
      final actions = studentActionsFor(
        linked(wisa: wisaStudent(), azure: azureUser()),
        cfg,
      );
      expect(actions.single.unlocks, isEmpty);
      expect(actions.single.unlockedSystems, isEmpty);
    });

    test('every other student action unlocks nothing (#230)', () {
      // The chain is opt-in per action; a stray declaration would make the
      // applier write beyond what the operator selected.
      for (final account in <LinkedAccount>[
        linked(smartschool: ssAccount(status: 'actief')),
        linked(azure: azureUser(companyName: 'SSM')),
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: ssAccount(accountId: 'W9'),
          azure: azureUser(),
        ),
      ]) {
        for (final action in studentActionsFor(account, cfg)) {
          if (action is AddStudentToAzure) continue;
          expect(action.unlocks, isEmpty, reason: '${action.runtimeType}');
          // …and so claims no second system on the confirmation dialog (#234).
          expect(action.unlockedSystems, isEmpty,
              reason: '${action.runtimeType}');
        }
      }
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

    test('a missing companyName fires ModifyAzureSchool too (#224)', () {
      // The adopted transfer account: `companyName` was never stamped by the
      // school it came from. The old `company != null` guard made this the one
      // case the repair refused to fire on — which kept the account invisible
      // to the next sync's `$filter` and made the whole problem recur forever.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(companyName: null, department: 'OTHER-3A'),
        ),
        cfg,
      );
      // The class the other school stamped is repaired in the same pass since
      // #359 — adoption means taking over the whole profile, not just the field
      // the `$filter` reads.
      expect(types(actions), [ModifyAzureSchool, ModifyAzureDepartment]);
      final change = actions.first.describeChanges();
      expect(change.fields.single.before, isNull);
      expect(change.fields.single.after, 'SSM');
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

  group('dispatch §6.3 — group-wide leave detection (#134)', () {
    test(
        'a student moved to a sibling group school → Smartschool departure, '
        'NOT RemoveStudentFromAzure (Azure is kept)', () {
      // All three systems carry the student, but their WISA record is only in a
      // sibling school we do not manage (groupOnly). Pre-#134 this looked
      // "complete" and yielded no departure at all.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(status: 'actief'),
          azure: azureUser(companyName: 'SSM'),
          wisaPresence: WisaPresence.groupOnly,
          wisaClassGroups: const {2: '3A'},
        ),
        cfg,
      );
      expect(
        types(actions),
        [UnregisterStudentFromSmartschool, DeleteStudentFromSmartschool],
      );
      expect(actions.whereType<RemoveStudentFromAzure>(), isEmpty,
          reason: 'still in the group ⇒ Azure removal is suppressed');
      // Nor any modify action: a departure is never the modify branch.
      expect(actions.whereType<ModifyAzureName>(), isEmpty);
    });

    test(
        'a sibling-school student already removed from our Smartschool keeps '
        'Azure: no action at all', () {
      // The settled keep-Azure end state: gone from our Smartschool, WISA still
      // in a sibling school, Azure retained. Nothing further must fire — in
      // particular not AddStudentToSmartschool (never re-add a departed student)
      // nor RemoveStudentFromAzure.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          azure: azureUser(companyName: 'SSM'),
          wisaPresence: WisaPresence.groupOnly,
          wisaClassGroups: const {2: '3A'},
        ),
        cfg,
      );
      expect(actions, isEmpty);
    });

    test(
        'a student gone from the whole group (still in our Smartschool) → '
        'Smartschool departure, Azure removal deferred until SS is gone', () {
      // No WISA anywhere (absent). Smartschool + Azure still present. Legacy
      // gates Azure removal behind !Smartschool.Exists, so this pass yields only
      // the Smartschool departure.
      final actions = studentActionsFor(
        linked(
          smartschool: ssAccount(status: 'actief'),
          azure: azureUser(companyName: 'SSM'),
        ),
        cfg,
      );
      expect(
        types(actions),
        [UnregisterStudentFromSmartschool, DeleteStudentFromSmartschool],
      );
      expect(actions.whereType<RemoveStudentFromAzure>(), isEmpty);
    });

    test(
        'a student gone from the whole group with only Azure left → '
        'RemoveStudentFromAzure (delete-both completes)', () {
      final actions = studentActionsFor(
        linked(azure: azureUser(companyName: 'SSM')),
        cfg,
      );
      expect(types(actions), [RemoveStudentFromAzure]);
    });

    test(
        'a WISA-only sibling-school student is never provisioned into our '
        'systems (no AddStudentToAzure)', () {
      // A student present only in a sibling group school, with nothing of ours
      // yet. They are not ours, so we must not create Azure/Smartschool accounts.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          wisaPresence: WisaPresence.groupOnly,
          wisaClassGroups: const {2: '3A'},
        ),
        cfg,
      );
      expect(actions, isEmpty);
    });
  });
}
