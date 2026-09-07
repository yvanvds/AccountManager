import 'package:account_core/account_core.dart' as core;
import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  /// The healthy case: one student, in one official class that carries the
  /// Presence group id.
  ScanResolver healthyResolver({
    Map<String, core.PersonId> personIdsByUid = const {},
  }) =>
      ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account(
              'jane.doe',
              accountId: '123456',
              givenName: 'Johanna',
              preferredName: 'Jane',
              surname: 'Doe',
              referenceIdentifier: '4069_12016_0',
            ),
          ],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
        personIdsByUid: personIdsByUid,
      );

  group('ScanResolver.resolve — hit', () {
    test('resolves a scanned code to a registerable student', () {
      final result = healthyResolver().resolve('123456');

      expect(result, isA<ScanRegisterable>());
      final hit = result as ScanRegisterable;
      expect(hit.student.displayName, 'Jane Doe');
      expect(hit.student.className, '1A');
      expect(hit.student.classCode, const core.GroupId('SSM1A'));
      expect(hit.student.smartschoolUid, 'jane.doe');
      expect(hit.student.wisaId, '123456');
      expect(hit.internalUserId, 12016);
      expect(hit.classGroupId, 298);
      expect(hit.student.isRegisterable, isTrue);
    });

    test('falls back to the given name when there is no roepnaam', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account(
              'jane.doe',
              accountId: '123456',
              givenName: 'Johanna',
              surname: 'Doe',
            ),
          ],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
      );

      final hit = resolver.resolve('123456') as ScanRegisterable;
      expect(hit.student.displayName, 'Johanna Doe');
    });

    test('carries the person id when the caller supplies one', () {
      final resolver = healthyResolver(
        personIdsByUid: const {'jane.doe': core.PersonId('p-1')},
      );

      final hit = resolver.resolve('123456') as ScanRegisterable;
      expect(hit.student.personId, const core.PersonId('p-1'));
    });

    test('leaves the person id null when the caller has none', () {
      final hit = healthyResolver().resolve('123456') as ScanRegisterable;
      expect(hit.student.personId, isNull);
    });

    test('the presence class id is the connector group id, passed through', () {
      // #400: the connector's `sourceId` *is* the Presence module's `groupID`,
      // so no mapping table stands between them. Guarded here because a future
      // change that reintroduces one would silently register against the wrong
      // class.
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [account('jane.doe', accountId: '123456')],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 4242)],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
      );

      expect(
        (resolver.resolve('123456') as ScanRegisterable).classGroupId,
        4242,
      );
    });
  });

  group('ScanResolver.resolve — scanned input normalisation', () {
    test('ignores the trailing Enter the scanner presses', () {
      expect(healthyResolver().resolve('123456\r\n'), isA<ScanRegisterable>());
    });

    test('ignores padding around a hand-typed code', () {
      expect(healthyResolver().resolve('  123456 '), isA<ScanRegisterable>());
    });

    test('indexes the account id with the same normalisation', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [account('jane.doe', accountId: ' 123456 ')],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
      );

      final hit = resolver.resolve('123456') as ScanRegisterable;
      // The key is normalised; the displayed WISA id is the value verbatim.
      expect(hit.student.scanCode, '123456');
      expect(hit.student.wisaId, ' 123456 ');
    });

    test('a burst of pure noise is empty, not an unknown student', () {
      expect(healthyResolver().resolve('\r\n'), isA<ScanEmpty>());
      expect(healthyResolver().resolve('   '), isA<ScanEmpty>());
    });
  });

  group('ScanResolver.resolve — unknown', () {
    test('reports a code no student carries', () {
      final result = healthyResolver().resolve('999999');
      expect(result, isA<ScanUnknown>());
      expect((result as ScanUnknown).code, '999999');
    });

    test('a staff card is unknown, not a late arrival', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account(
              'ann.teacher',
              accountId: '777777',
              role: core.PersonRole.teacher,
            ),
          ],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [membership('ann.teacher', 'SSM1A')],
        ),
      );

      expect(resolver.resolve('777777'), isA<ScanUnknown>());
      expect(resolver.studentCount, 0);
    });

    test('an account with a blank Internnummer is not indexed', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [account('jane.doe', accountId: '   ')],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
      );

      expect(resolver.studentCount, 0);
      expect(resolver.resolve('   '), isA<ScanEmpty>());
    });
  });

  group('ScanResolver.resolve — known but not registerable', () {
    test('a missing internal user id is not an unknown student', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account(
              'jane.doe',
              accountId: '123456',
              referenceIdentifier: null,
            ),
          ],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
      );

      final result = resolver.resolve('123456');
      expect(result, isA<ScanIncomplete>());
      final incomplete = result as ScanIncomplete;
      expect(incomplete.blockers, {ScanBlocker.noInternalUserId});
      // The desk can still name the student — that is the whole distinction.
      expect(incomplete.student.displayName, 'Jane Doe');
      expect(incomplete.student.className, '1A');
      expect(incomplete.student.isRegisterable, isFalse);
    });

    test('a malformed referenceIdentifier blocks the same way', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account('jane.doe', accountId: '123456', referenceIdentifier: 'x'),
          ],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
      );

      expect(
        (resolver.resolve('123456') as ScanIncomplete).blockers,
        {ScanBlocker.noInternalUserId},
      );
    });

    test('a class with no sourceId is resolvable by name, not registerable',
        () {
      // The 8 member-less official classes of #400: the name is known, the
      // Presence group id is not, and the operator must be told which of the
      // two failures this is.
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [account('jane.doe', accountId: '123456')],
          groups: [ssGroup('SSM3BO1', name: '3BO1')],
          memberships: [membership('jane.doe', 'SSM3BO1')],
        ),
      );

      final result = resolver.resolve('123456');
      expect(result, isA<ScanIncomplete>());
      final incomplete = result as ScanIncomplete;
      expect(incomplete.blockers, {ScanBlocker.noClassGroupId});
      expect(incomplete.student.className, '3BO1');
      expect(incomplete.student.classGroupId, isNull);
    });

    test('no official class at all is a different blocker', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [account('jane.doe', accountId: '123456')],
          groups: [
            ssGroup('SSMKOOR', name: 'Koor', official: false, sourceId: 900),
          ],
          memberships: [membership('jane.doe', 'SSMKOOR')],
        ),
      );

      final incomplete = resolver.resolve('123456') as ScanIncomplete;
      expect(incomplete.blockers, {ScanBlocker.noOfficialClass});
      expect(incomplete.student.className, isEmpty);
      expect(incomplete.student.classCode, isNull);
    });

    test('both failures at once are reported together', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account(
              'jane.doe',
              accountId: '123456',
              referenceIdentifier: null,
            ),
          ],
          groups: [ssGroup('SSM3BO1', name: '3BO1')],
          memberships: [membership('jane.doe', 'SSM3BO1')],
        ),
      );

      expect(
        (resolver.resolve('123456') as ScanIncomplete).blockers,
        {ScanBlocker.noInternalUserId, ScanBlocker.noClassGroupId},
      );
    });
  });

  group('ScanResolver — class selection', () {
    test('picks the official class out of several memberships (PAIN-1)', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [account('jane.doe', accountId: '123456')],
          groups: [
            ssGroup('SSMKOOR', name: 'Koor', official: false, sourceId: 900),
            ssGroup('SSM1A', name: '1A', sourceId: 298),
            ssGroup('SSMSPORT', name: 'Sport', official: false, sourceId: 901),
          ],
          memberships: [
            membership('jane.doe', 'SSMKOOR'),
            membership('jane.doe', 'SSM1A'),
            membership('jane.doe', 'SSMSPORT'),
          ],
        ),
      );

      final hit = resolver.resolve('123456') as ScanRegisterable;
      expect(hit.student.className, '1A');
      expect(hit.classGroupId, 298);
    });

    test('breaks a two-official-class tie the same way every time', () {
      core.Group first() => ssGroup('SSM1A', name: '1A', sourceId: 298);
      core.Group second() => ssGroup('SSM1C', name: '1C', sourceId: 301);

      String classOf(List<core.Group> groups) {
        final resolver = ScanResolver.fromSmartschool(
          snapshot(
            accounts: [account('jane.doe', accountId: '123456')],
            groups: groups,
            memberships: [
              membership('jane.doe', 'SSM1C'),
              membership('jane.doe', 'SSM1A'),
            ],
          ),
        );
        return (resolver.resolve('123456') as ScanRegisterable)
            .student
            .className;
      }

      expect(classOf([first(), second()]), '1A');
      expect(classOf([second(), first()]), '1A');
    });

    test('ignores a membership whose group is not in the snapshot', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [account('jane.doe', accountId: '123456')],
          groups: const [],
          memberships: [membership('jane.doe', 'SSM1A')],
        ),
      );

      expect(
        (resolver.resolve('123456') as ScanIncomplete).blockers,
        {ScanBlocker.noOfficialClass},
      );
    });
  });

  group('ScanResolver — a code two students share', () {
    test('refuses rather than picking one', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account('jane.doe', accountId: '123456'),
            account('john.roe', accountId: '123456'),
          ],
          groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
          memberships: [
            membership('jane.doe', 'SSM1A'),
            membership('john.roe', 'SSM1A'),
          ],
        ),
      );

      final result = resolver.resolve('123456');
      expect(result, isA<ScanAmbiguous>());
      final ambiguous = result as ScanAmbiguous;
      expect(ambiguous.code, '123456');
      expect(ambiguous.smartschoolUids, ['jane.doe', 'john.roe']);
      expect(resolver.ambiguousCodes, ['123456']);
    });

    test('names every colliding account, not just the first two', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account('a', accountId: '123456'),
            account('b', accountId: '123456'),
            account('c', accountId: '123456'),
          ],
        ),
      );

      expect(
        (resolver.resolve('123456') as ScanAmbiguous).smartschoolUids,
        ['a', 'b', 'c'],
      );
    });

    test('a healthy tenant reports no collisions', () {
      expect(healthyResolver().ambiguousCodes, isEmpty);
    });
  });

  group('ScanResolver — index', () {
    test('counts the students it can answer for', () {
      final resolver = ScanResolver.fromSmartschool(
        snapshot(
          accounts: [
            account('a', accountId: '1'),
            account('b', accountId: '2'),
            account('c', accountId: '3', role: core.PersonRole.teacher),
            account('d', accountId: ''),
            account('e', accountId: '4', role: null),
          ],
        ),
      );

      // Only `a` and `b`: the teacher, the blank Internnummer, and the row
      // whose Basisrol did not map to a role are all left out.
      expect(resolver.studentCount, 2);
    });

    test('an empty snapshot resolves everything as unknown', () {
      final resolver = ScanResolver.fromSmartschool(snapshot());
      expect(resolver.studentCount, 0);
      expect(resolver.resolve('123456'), isA<ScanUnknown>());
    });
  });
}
