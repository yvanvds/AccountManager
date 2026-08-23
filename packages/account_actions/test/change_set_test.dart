import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

/// The three shapes a [FieldChange] comes in (#300, #305).
///
/// A `ChangeSet` describes three different kinds of thing, and until #300 it
/// had only one way to say any of them: a value moving from one thing to
/// another, a quantity the action acts on, and a fact about the record an
/// informational notice is describing. Rendered through the one template the
/// second read "leden toevoegen: ∅ → 21" — a field that used to be empty and is
/// becoming 21 — and the third "mail: GBS-9Z@… → ∅", an address being cleared
/// by an action whose heading says it writes nothing at all.
void main() {
  group('FieldChange (#300, #305)', () {
    test('a transition keeps both halves and reads as one', () {
      const f = FieldChange('mail', after: 'GBS-3A@student.school.example');
      expect(f.shape, FieldChangeShape.transition);
      expect(f.before, isNull);
      expect(
        f.toString(),
        'FieldChange(mail: ∅ → GBS-3A@student.school.example)',
      );
    });

    test('a count states one number and has no before half', () {
      final f = FieldChange.count('leden toevoegen', 21);
      expect(f.field, 'leden toevoegen');
      expect(f.shape, FieldChangeShape.count);
      expect(f.before, isNull);
      expect(f.after, '21',
          reason: 'the number rides in the value slot, so '
              'every consumer that reads a field value keeps working');
      expect(f.toString(), 'FieldChange(leden toevoegen: 21)');
    });

    test('a count with a before half is a contradiction and is refused', () {
      expect(
        () => FieldChange('leden',
            before: '17', after: '21', shape: FieldChangeShape.count),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a statement states what is, and has nothing it moves to (#305)', () {
      const f = FieldChange.statement('mail', 'GBS-9Z@student.school.example');
      expect(f.field, 'mail');
      expect(f.shape, FieldChangeShape.statement);
      expect(f.before, 'GBS-9Z@student.school.example',
          reason: 'the value rides in the slot that has always meant '
              '"what the record holds now"');
      expect(f.after, isNull);
      expect(f.toString(), 'FieldChange(mail: GBS-9Z@student.school.example)');
    });

    test('a statement with an after half is a contradiction and is refused',
        () {
      expect(
        () => FieldChange('mail',
            before: 'a@b.example',
            after: 'c@d.example',
            shape: FieldChangeShape.statement),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
