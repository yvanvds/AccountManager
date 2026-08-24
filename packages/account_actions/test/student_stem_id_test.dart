/// The stamboeknummer write and the class move it has to wait for (#338).
///
/// Smartschool keeps one stamnummer **per schoolloopbaan row** while `saveUser`
/// carries it with no school-year parameter, so the value lands on the *last*
/// row. Written before the class move into next year's class, that last row is
/// still the **running** year's — and a student switching between two of the
/// group's schools has this year's row overwritten with next year's institute
/// number. Only switchers show it: for everyone else the number is unchanged and
/// the overwrite is a no-op.
library;

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = config();

  // The pair from the audit's `heremk` row: WISA already reports the *new*
  // school's number for next year, Smartschool still carries the one the running
  // year's career row belongs to.
  const String nextYearStem = '2300033';
  const int currentStem = 2200123;

  /// A student moving from `4NW2` to `5ADB` — and, with it, from one of the
  /// group's schools to the other.
  LinkedAccount switcher() => linked(
        wisa: wisaStudent(classGroup: '5ADB', stemId: nextYearStem),
        smartschool: ssAccount(stemId: currentStem),
        azure: azureUser(),
      );

  Group runningYearClass() => ssGroup(code: '4nw2_ss', name: '4NW2');
  Group nextYearClass() => ssGroup(code: '5adb_ss', name: '5ADB');

  ClassPlacement rollover({Group? currentClass}) => classPlacement(
        className: '5ADB',
        currentClass: currentClass,
        tree: <Group>[runningYearClass(), nextYearClass()],
        ourClasses: const <String>{'4NW2', '5ADB'},
      );

  List<Type> types(Iterable<StudentAction> actions) =>
      actions.map((a) => a.runtimeType).toList();

  /// The `stamboeknummer` the (single) `saveUser` in [transport] carried, or
  /// null when no `saveUser` went out. Exact match on the method: the
  /// `saveUserParameter` calls `saveAccount` chains afterwards share the prefix.
  String? savedStamboek(RecordingSmartschoolTransport transport) {
    for (var i = 0; i < transport.soapActions.length; i++) {
      if (!transport.soapActions[i].endsWith('#saveUser')) continue;
      final match = RegExp(r'<stamboeknummer[^>]*>([^<]*)</stamboeknummer>')
          .firstMatch(transport.envelopes[i]);
      if (match != null) return match.group(1);
    }
    return null;
  }

  group('the stamboeknummer waits for the class move (#338)', () {
    test('held back while the student still sits in the running year class',
        () {
      // The damaging pass: WISA names next year's school, Smartschool's last
      // career row is still this year's. Only the move may run now.
      final actions = studentActionsFor(
        switcher(),
        cfg,
        placementFor: (_) => rollover(currentClass: runningYearClass()),
      );
      expect(types(actions), <Type>[MoveToSmartschoolClassGroup]);
    });

    test('written again once the move has created next year\'s row', () {
      // Same student after the move: their Smartschool class is the target, so
      // no move is pending and the last career row is the new year's.
      final actions = studentActionsFor(
        switcher(),
        cfg,
        placementFor: (_) => rollover(currentClass: nextYearClass()),
      );
      expect(types(actions), <Type>[ModifySmartschoolStemId]);
    });

    test('an account with no class yet keeps its write — and moves first', () {
      // The condition is per account, never per school: a student who holds no
      // official class (a virtual school's intake, a freshly created account)
      // has no career row to damage. Both actions apply, and the move is offered
      // first so the row exists before the number is written.
      final actions = studentActionsFor(
        switcher(),
        cfg,
        placementFor: (_) => rollover(),
      );
      expect(
        types(actions),
        <Type>[MoveToSmartschoolClassGroup, ModifySmartschoolStemId],
      );
    });

    test('without a placement the write is unconditional (pre-#338)', () {
      // No membership context was wired, so nothing is known about a pending
      // move and the dispatch behaves exactly as it did before.
      expect(
        types(studentActionsFor(switcher(), cfg)),
        <Type>[ModifySmartschoolStemId],
      );
    });

    test('a student who is not moving is unaffected', () {
      // The overwhelming majority: same class, same school, same number. The
      // guard must not touch a plain correction.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '3A', stemId: nextYearStem),
          smartschool: ssAccount(stemId: currentStem),
          azure: azureUser(),
        ),
        cfg,
        placementFor: (_) => classPlacement(
          currentClass: ssGroup(code: '3A_ss', name: '3A'),
        ),
      );
      expect(types(actions), <Type>[ModifySmartschoolStemId]);
    });
  });

  group('no other action smuggles a stamboeknummer through saveUser (#338)',
      () {
    test('ModifySmartschoolBirthPlace re-sends the number Smartschool holds',
        () async {
      // `saveUser` sends the whole account, so every field modifier carries a
      // stamboeknummer it has no opinion about. It must be the one Smartschool
      // holds right now, which makes that half of the payload a no-op.
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = ModifySmartschoolBirthPlace(
        linked(
          wisa: wisaStudent(birthPlace: 'Brugge', stemId: nextYearStem),
          smartschool: ssAccount(birthPlace: 'Gent', stemId: currentStem),
          azure: azureUser(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(savedStamboek(transport), '$currentStem');
      final saved = result.smartschool! as ss.SmartschoolAccount;
      expect(saved.stemId, currentStem);
      expect(saved.birthPlace, 'Brugge');
    });

    test('ModifySmartschoolStemId is the one action that changes it', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = ModifySmartschoolStemId(switcher(), cfg);

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(savedStamboek(transport), nextYearStem);
      expect(
        (result.smartschool! as ss.SmartschoolAccount).stemId,
        int.parse(nextYearStem),
      );
    });
  });
}
