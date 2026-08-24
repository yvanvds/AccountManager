import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
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

    test('Smartschool-only staff → the departure either/or (#349)', () {
      // Deactivate *or* delete, conservative half first — the staff twin of the
      // student departure pair. Before #349 the delete stood alone.
      final actions = staffActionsFor(
        linkedStaff(smartschool: ssStaff()),
        cfg,
      );
      expect(types(actions),
          [DeactivateStaffInSmartschool, RemoveStaffFromSmartschool]);
    });

    test(
        'an already-disabled Smartschool account offers only the delete (#349)',
        () {
      // Nothing left to deactivate, so the either/or collapses to its one
      // remaining answer rather than offering a no-op.
      final actions = staffActionsFor(
        linkedStaff(smartschool: ssStaff(status: 'uitgeschakeld')),
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
    });

    test(
        "an adopted account carrying another school's department raises the "
        'ordinary create, and nothing about the department (#237)', () {
      // WISA + Azure, no Smartschool — the state #231's back-fill leaves a
      // moved staff member in. `department` is the sibling school's to maintain
      // (it lists every school the teacher is active at), so the only thing
      // still missing here is the Smartschool account.
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(),
          azure: azureStaff(department: 'GBS'),
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

    test('an Azure department naming other schools raises nothing (#237)', () {
      // `department` is a comma-separated list of the schools the teacher is
      // active at, maintained by other software. Our prefix appearing second —
      // or not at all on a record the back-fill adopted by employeeId — is not
      // a defect we may "repair": the write that used to do it (#233) collapsed
      // the list to our prefix alone and destroyed the sibling school's claim.
      for (final department in <String?>[
        'GBS,SSM',
        'SSM,GBS',
        'GBS',
        'OTHER - Wiskunde',
        null,
      ]) {
        final actions = staffActionsFor(
          linkedStaff(
            wisa: wisaStaff(),
            smartschool: ssStaff(),
            azure: azureStaff(department: department),
          ),
          cfg,
        );
        expect(actions, isEmpty, reason: 'department: $department');
      }
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

  group(
      'a WISA staff member with no Smartschool account is one choice, '
      'not two to-dos (#248)', () {
    test('the Azure create + do-not-import share one key, the create leading',
        () {
      final actions = staffActionsFor(linkedStaff(wisa: wisaStaff()), cfg);
      final create = actions.whereType<AddStaffToAzure>().single;
      final ignore = actions.whereType<DontImportStaffFromWisa>().single;

      // Same key ⇒ the pending list collapses them into one either/or choice
      // and an apply runs only the picked one. Both used to return null, so one
      // click provisioned the teacher *and* blacklisted their WISA code — and
      // the persisted rule dropped them from the very next pull.
      expect(create.alternativeGroup, staffImportAlternative);
      expect(ignore.alternativeGroup, create.alternativeGroup);

      // Polarity: provisioning leads, blacklisting is a deliberate pick.
      expect(create.isDefaultAlternative, isTrue);
      expect(ignore.isDefaultAlternative, isFalse);
      expect(actions.indexOf(create), lessThan(actions.indexOf(ignore)));
    });

    test('the Smartschool create takes the key in its own right', () {
      // WISA + Azure, no Smartschool — an account adopted by employeeId (#231),
      // or a #240 chain whose second write failed. The dispatch offers this
      // create beside the opt-out as the identical contradictory pair, so the
      // key cannot ride on AddStaffToAzure alone.
      final actions = staffActionsFor(
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        cfg,
      );
      final create = actions.whereType<AddStaffToSmartschool>().single;
      final ignore = actions.whereType<DontImportStaffFromWisa>().single;

      expect(create.alternativeGroup, staffImportAlternative);
      expect(ignore.alternativeGroup, staffImportAlternative);
      expect(create.isDefaultAlternative, isTrue,
          reason: 'it stands in for AddStaffToAzure, so it takes the default');
      expect(ignore.isDefaultAlternative, isFalse);
      expect(actions.indexOf(create), lessThan(actions.indexOf(ignore)));
    });

    test('exactly one default is ever offered — the creates never co-occur',
        () {
      for (final staff in <LinkedStaff>[
        linkedStaff(wisa: wisaStaff()),
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
      ]) {
        final alternatives = staffActionsFor(staff, cfg)
            .where((a) => a.alternativeGroup == staffImportAlternative)
            .toList();
        expect(alternatives, hasLength(2));
        expect(
          alternatives.where((a) => a.isDefaultAlternative),
          hasLength(1),
          reason: 'the azure == null test picks exactly one of the two creates',
        );
      }
    });

    test('every other staff action stands on its own', () {
      // A stray key would pool unrelated actions into one radio group and hide
      // all but the selected one from the operator. Two keys are legitimate —
      // the import either/or above and the departure either/or of #349 — and
      // each may only ever be carried by its own declared members.
      const known = <String, Set<Type>>{
        staffImportAlternative: {
          AddStaffToAzure,
          AddStaffToSmartschool,
          DontImportStaffFromWisa,
        },
        staffSmartschoolDepartureAlternative: {
          DeactivateStaffInSmartschool,
          RemoveStaffFromSmartschool,
        },
      };
      for (final staff in <LinkedStaff>[
        linkedStaff(wisa: wisaStaff()),
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        linkedStaff(smartschool: ssStaff()),
        linkedStaff(azure: azureStaff()),
        linkedStaff(smartschool: ssStaff(), azure: azureStaff()),
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT', wisaId: '42'),
          smartschool: ssStaff(accountId: 'OLD', fax: '9999'),
          azure: azureStaff(),
        ),
      ]) {
        for (final action in staffActionsFor(staff, cfg)) {
          final key = action.alternativeGroup;
          if (key == null) continue;
          expect(known.keys, contains(key), reason: '${action.runtimeType}');
          expect(known[key], contains(action.runtimeType),
              reason: '${action.runtimeType} carries $key');
        }
      }
    });

    test('the departure pair is one choice, keeping the account by default',
        () {
      final actions = staffActionsFor(linkedStaff(smartschool: ssStaff()), cfg);
      final keep = actions.whereType<DeactivateStaffInSmartschool>().single;
      final delete = actions.whereType<RemoveStaffFromSmartschool>().single;

      expect(keep.alternativeGroup, staffSmartschoolDepartureAlternative);
      expect(delete.alternativeGroup, keep.alternativeGroup);
      // Polarity: the conservative half leads and is pre-selected — the same way
      // round as the student departure, and deliberately the opposite of the
      // import choice above.
      expect(keep.isDefaultAlternative, isTrue);
      expect(delete.isDefaultAlternative, isFalse);
      expect(actions.indexOf(keep), lessThan(actions.indexOf(delete)));
    });
  });

  group('unlocked follow-ups (#240)', () {
    test('the WISA-only create declares its Smartschool follow-up', () {
      // Provisioning a new staff member is a chain the dispatcher cannot
      // express: AddStaffToSmartschool needs the Azure UPN as the new account's
      // mail, so it evaluates false until the Azure account exists. Naming the
      // follow-up here is what lets the State layer run it straight after the
      // create, against the relinked record — one click, both accounts.
      final actions = staffActionsFor(linkedStaff(wisa: wisaStaff()), cfg);
      final create = actions.whereType<AddStaffToAzure>().single;
      expect(create.unlocks, <Type>{AddStaffToSmartschool});
    });

    test('the WISA-only create names the system its follow-up writes (#234)',
        () {
      // The apply-confirmation dialog has to name Smartschool for this one
      // action, and it cannot read it off the follow-up: the follow-up does not
      // exist until the create has run and relinked. Pinned against the
      // follow-up's own ChangeSet so the two cannot drift apart.
      final create = staffActionsFor(linkedStaff(wisa: wisaStaff()), cfg)
          .whereType<AddStaffToAzure>()
          .single;
      final followUp = staffActionsFor(
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        cfg,
      ).whereType<AddStaffToSmartschool>().single;
      expect(create.unlockedSystems, <Origin>{Origin.smartschool});
      expect(
          create.unlockedSystems, <Origin>{followUp.describeChanges().system});
    });

    test('the Smartschool create ends the chain', () {
      // Nothing follows it: the record is complete afterwards, so the next pass
      // is the ordinary modify branch, not another link of this chain.
      final actions = staffActionsFor(
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        cfg,
      );
      final create = actions.whereType<AddStaffToSmartschool>().single;
      expect(create.unlocks, isEmpty);
      expect(create.unlockedSystems, isEmpty);
    });

    test('every other staff action unlocks nothing', () {
      // The chain is opt-in per action; a stray declaration would make the
      // applier write beyond what the operator selected. Two chains are
      // declared: provisioning (#240) and the departure of #349, whose
      // Smartschool half pulls the Office 365 half along behind it.
      const chaining = <Type>{
        AddStaffToAzure,
        DeactivateStaffInSmartschool,
        RemoveStaffFromSmartschool,
      };
      for (final staff in <LinkedStaff>[
        linkedStaff(wisa: wisaStaff()),
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        linkedStaff(smartschool: ssStaff()),
        linkedStaff(azure: azureStaff()),
        linkedStaff(smartschool: ssStaff(), azure: azureStaff()),
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT', wisaId: '42'),
          smartschool: ssStaff(accountId: 'OLD', fax: '9999'),
          azure: azureStaff(),
        ),
      ]) {
        for (final action in staffActionsFor(staff, cfg)) {
          if (chaining.contains(action.runtimeType)) continue;
          expect(action.unlocks, isEmpty, reason: '${action.runtimeType}');
          // …and so claims no second system on the confirmation dialog (#234).
          expect(action.unlockedSystems, isEmpty,
              reason: '${action.runtimeType}');
        }
      }
    });

    test('the Smartschool departure declares its Office 365 follow-up (#349)',
        () {
      // Retiring somebody is a chain for the same reason provisioning is: the
      // dispatch can only ever offer the first link, so one click would clean
      // Smartschool and leave the Office 365 account behind for a pass the
      // operator has to notice and trigger.
      final actions = staffActionsFor(
        linkedStaff(smartschool: ssStaff(), azure: azureStaff()),
        cfg,
      );
      for (final action in <StaffAction>[
        actions.whereType<DeactivateStaffInSmartschool>().single,
        actions.whereType<RemoveStaffFromSmartschool>().single,
      ]) {
        expect(
          action.unlocks,
          <Type>{ReleaseStaffFromAzureSchool, RemoveStaffFromAzure},
          reason: '${action.runtimeType}',
        );
        expect(action.unlockedSystems, <Origin>{Origin.azure},
            reason: '${action.runtimeType}');
      }
    });

    test('every staff action is applyable, and says so on the action', () {
      // The walk skips a `canApply == false` follow-up. No staff action is
      // informational today; the flag is read off the action rather than
      // assumed, so adding one cannot silently make the applier run it.
      for (final staff in <LinkedStaff>[
        linkedStaff(wisa: wisaStaff()),
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        linkedStaff(smartschool: ssStaff()),
        linkedStaff(azure: azureStaff()),
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT', wisaId: '42'),
          smartschool: ssStaff(accountId: 'OLD', fax: '9999'),
          azure: azureStaff(),
        ),
      ]) {
        for (final action in staffActionsFor(staff, cfg)) {
          expect(action.canApply, isTrue, reason: '${action.runtimeType}');
        }
      }
    });
  });

  group('the departure command is never dispatched (#349)', () {
    test('no staff shape raises RetireStaffMember', () {
      // The safety property the whole design rests on: WISA reports a leaver as
      // employed, so a state-derived dispatch cannot tell them from a colleague
      // who is staying. Returning the command here would put a standing
      // destructive to-do on every person in the staff room.
      for (final staff in <LinkedStaff>[
        fullySyncedStaff(),
        linkedStaff(wisa: wisaStaff()),
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        linkedStaff(wisa: wisaStaff(), smartschool: ssStaff()),
        linkedStaff(smartschool: ssStaff()),
        linkedStaff(azure: azureStaff()),
        linkedStaff(smartschool: ssStaff(), azure: azureStaff()),
      ]) {
        expect(staffActionsFor(staff, cfg).whereType<RetireStaffMember>(),
            isEmpty);
      }
    });

    test('a staff member the school still employs raises no departure action',
        () {
      // The counterpart guard: relaxing the removal gates to hasLeftOurSchool
      // must not make them fire for somebody who is simply here.
      for (final staff in <LinkedStaff>[
        fullySyncedStaff(),
        linkedStaff(wisa: wisaStaff(), smartschool: ssStaff()),
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
      ]) {
        final actions = staffActionsFor(staff, cfg);
        expect(actions.whereType<DeactivateStaffInSmartschool>(), isEmpty);
        expect(actions.whereType<RemoveStaffFromSmartschool>(), isEmpty);
        expect(actions.whereType<ReleaseStaffFromAzureSchool>(), isEmpty);
        expect(actions.whereType<RemoveStaffFromAzure>(), isEmpty);
      }
    });

    test('the command applies to a WISA-listed member and to nobody else', () {
      expect(RetireStaffMember(fullySyncedStaff(), cfg).evaluate(), isTrue);
      expect(
        RetireStaffMember(linkedStaff(wisa: wisaStaff()), cfg).evaluate(),
        isTrue,
      );
      // Already departed: the rule has nothing left to hide, and the dispatch
      // offers the removals directly.
      expect(
        RetireStaffMember(
          linkedStaff(smartschool: ssStaff(), azure: azureStaff()),
          cfg,
        ).evaluate(),
        isFalse,
      );
    });

    test('it declares the whole cleanup, Smartschool before Office 365', () {
      final command = RetireStaffMember(fullySyncedStaff(), cfg);
      expect(command.unlocks, <Type>{
        DeactivateStaffInSmartschool,
        RemoveStaffFromSmartschool,
        ReleaseStaffFromAzureSchool,
        RemoveStaffFromAzure,
      });
      // Both systems are named on the confirmation (#234), because one click
      // reaches both.
      expect(
          command.unlockedSystems, <Origin>{Origin.smartschool, Origin.azure});
      // And it is a WISA-targeted action, so it writes nothing itself.
      expect(command.describeChanges().system, Origin.wisa);
    });
  });

  group('the Office 365 half splits on the department list (#349)', () {
    LinkedStaff departed(String? department) => linkedStaff(
          smartschool: ssStaff(),
          azure: azureStaff(department: department),
        );

    test('another school still claims them → release, never delete', () {
      for (final department in <String>['GBS,SSM', 'SSM,GBS', 'GBS, SSM']) {
        final actions = staffActionsFor(departed(department), cfg);
        expect(actions.whereType<ReleaseStaffFromAzureSchool>(), hasLength(1),
            reason: department);
        expect(actions.whereType<RemoveStaffFromAzure>(), isEmpty,
            reason: department);
      }
    });

    test('nobody else claims them → delete, never release', () {
      for (final department in <String?>['SSM', 'ssm', '', null]) {
        final actions = staffActionsFor(departed(department), cfg);
        expect(actions.whereType<RemoveStaffFromAzure>(), hasLength(1),
            reason: '$department');
        expect(actions.whereType<ReleaseStaffFromAzureSchool>(), isEmpty,
            reason: '$department');
      }
    });

    test('a longer school code that merely contains our prefix is not ours',
        () {
      // The write side matches list *items*, unlike the substring test the read
      // side uses. `SSMB` is somebody else's school; striking it would be the
      // #237 bug committed a second time, and deleting the account on the
      // strength of it would be worse.
      final actions = staffActionsFor(departed('SSMB'), cfg);
      final release = actions.whereType<ReleaseStaffFromAzureSchool>().single;
      expect(actions.whereType<RemoveStaffFromAzure>(), isEmpty);
      expect(release.describeChanges().fields.single.after, 'SSMB');
    });

    test('the release keeps every other entry verbatim, in order', () {
      final release = staffActionsFor(departed('GBS,SSM,KAV'), cfg)
          .whereType<ReleaseStaffFromAzureSchool>()
          .single;
      final change = release.describeChanges().fields.single;
      expect(change.before, 'GBS,SSM,KAV');
      expect(change.after, 'GBS,KAV');
    });

    test('a teacher who moved to a sibling group school is departed too', () {
      // All three systems present, so before #349 this record was "complete"
      // and got nothing but field repairs — even though WISA places them
      // exclusively in a school we do not manage.
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(),
          smartschool: ssStaff(),
          azure: azureStaff(department: 'GBS,SSM'),
          wisaPresence: WisaPresence.groupOnly,
        ),
        cfg,
      );
      expect(types(actions), [
        DeactivateStaffInSmartschool,
        RemoveStaffFromSmartschool,
        ReleaseStaffFromAzureSchool,
      ]);
    });
  });
}
