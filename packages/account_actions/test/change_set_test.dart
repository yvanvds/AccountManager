import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

/// The two shapes a [FieldChange] comes in (#300).
///
/// A `ChangeSet` describes two different kinds of thing, and until #300 it had
/// only one way to say either: a value moving from one thing to another, and a
/// quantity the action acts on. Rendered through the one template the second
/// read "leden toevoegen: ∅ → 21" — a field that used to be empty and is
/// becoming 21, true of nothing that happens to a class group.
void main() {
  group('FieldChange (#300)', () {
    test('a transition keeps both halves and reads as one', () {
      const f = FieldChange('mail', after: 'GBS-3A@student.school.example');
      expect(f.isCount, isFalse);
      expect(f.before, isNull);
      expect(
        f.toString(),
        'FieldChange(mail: ∅ → GBS-3A@student.school.example)',
      );
    });

    test('a count states one number and has no before half', () {
      final f = FieldChange.count('leden toevoegen', 21);
      expect(f.field, 'leden toevoegen');
      expect(f.isCount, isTrue);
      expect(f.before, isNull);
      expect(f.after, '21',
          reason: 'the number rides in the value slot, so '
              'every consumer that reads a field value keeps working');
      expect(f.toString(), 'FieldChange(leden toevoegen: 21)');
    });

    test('a count with a before half is a contradiction and is refused', () {
      expect(
        () => FieldChange('leden', before: '17', after: '21', isCount: true),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
