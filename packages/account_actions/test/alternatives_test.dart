import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

/// A stand-in for anything carrying the two alternative keys — the point of
/// [collapseAlternatives] is that it knows nothing about actions or candidates,
/// so the reconcile controller's live options and the materialized view's
/// persisted candidates get the same partition (#251).
class _Option {
  const _Option(
    this.kind, {
    this.group,
    this.isDefault = false,
    this.noticeFor,
  });
  final String kind;
  final String? group;
  final bool isDefault;
  final String? noticeFor;
}

List<Alternatives<_Option>> _collapse(List<_Option> options) =>
    collapseAlternatives<_Option>(
      options,
      groupOf: (o) => o.group,
      isDefault: (o) => o.isDefault,
      noticeFor: (o) => o.noticeFor,
    );

void main() {
  group('collapseAlternatives (#110/#251)', () {
    test('an item with no group is a choice of one', () {
      final choices = _collapse(const [_Option('ModifyAzureName')]);
      expect(choices, hasLength(1));
      expect(choices.single.isChoice, isFalse);
      expect(choices.single.selected.kind, 'ModifyAzureName');
    });

    test('items sharing a key collapse into one choice on its default', () {
      final choices = _collapse(const [
        _Option('UnregisterStudentFromSmartschool',
            group: 'smartschool-departure', isDefault: true),
        _Option('DeleteStudentFromSmartschool', group: 'smartschool-departure'),
      ]);

      expect(choices, hasLength(1), reason: 'one situation, one decision');
      expect(choices.single.isChoice, isTrue);
      expect(choices.single.options.map((o) => o.kind), hasLength(2));
      expect(choices.single.selected.kind, 'UnregisterStudentFromSmartschool');
    });

    test('two different keys stay two choices', () {
      final choices = _collapse(const [
        _Option('AddToSmartschool', group: 'class-import', isDefault: true),
        _Option('DoNotImportFromWisa', group: 'class-import'),
        _Option('CreateAzureClassGroup', group: 'azure-class-group'),
      ]);
      expect(choices, hasLength(2));
    });

    test('a group with no declared default falls back to its first item', () {
      // Every dispatch keeps the provisioning half first, so the fallback is
      // never the "stop importing it" opt-out.
      final choices = _collapse(const [
        _Option('AddToSmartschool', group: 'class-import'),
        _Option('DoNotImportFromWisa', group: 'class-import'),
      ]);
      expect(choices.single.selected.kind, 'AddToSmartschool');
    });

    test('lone items keep their place and groups follow in first-seen order',
        () {
      final choices = _collapse(const [
        _Option('ModifySmartschoolData'),
        _Option('B1', group: 'b'),
        _Option('A1', group: 'a', isDefault: true),
        _Option('B2', group: 'b', isDefault: true),
        _Option('A2', group: 'a'),
      ]);

      expect(
        choices.map((c) => c.selected.kind),
        <String>['ModifySmartschoolData', 'B2', 'A1'],
      );
    });

    test('no items at all is no decisions', () {
      expect(_collapse(const []), isEmpty);
    });
  });

  group('a notice is context, not an alternative (#329)', () {
    test('it is lifted onto the decision it names, never into its options', () {
      final choices = _collapse(const [
        _Option('ClassExistsAsSmartschoolGroup', noticeFor: 'class-namesake'),
        _Option('DoNotImportFromWisa', group: 'class-namesake'),
      ]);

      expect(choices, hasLength(1),
          reason: 'the notice is not a decision of its own');
      final choice = choices.single;
      expect(choice.isChoice, isFalse,
          reason: 'one option, so no "Kies één oplossing:"');
      expect(
          choice.options.map((o) => o.kind), <String>['DoNotImportFromWisa']);
      expect(choice.selected.kind, 'DoNotImportFromWisa');
      expect(
        choice.notices.map((o) => o.kind),
        <String>['ClassExistsAsSmartschoolGroup'],
      );
    });

    test('a genuine either/or can carry one too, and keeps both options', () {
      final choices = _collapse(const [
        _Option('Context', noticeFor: 'class-import'),
        _Option('AddToSmartschool', group: 'class-import', isDefault: true),
        _Option('DoNotImportFromWisa', group: 'class-import'),
      ]);

      final choice = choices.single;
      expect(choice.isChoice, isTrue);
      expect(choice.selected.kind, 'AddToSmartschool');
      expect(choice.notices.map((o) => o.kind), <String>['Context']);
    });

    test('several notices on one decision keep their dispatch order', () {
      final choices = _collapse(const [
        _Option('First', noticeFor: 'k'),
        _Option('Second', noticeFor: 'k'),
        _Option('Decision', group: 'k'),
      ]);

      expect(
        choices.single.notices.map((o) => o.kind),
        <String>['First', 'Second'],
      );
    });

    test('a notice whose decision is absent is shown, not dropped', () {
      // Defensive: the dispatches pair every notice with the decision it names,
      // but a stored document could be partial — and a row that silently
      // vanishes is the one outcome that would not be honest.
      final choices = _collapse(const [
        _Option('ModifySmartschoolData'),
        _Option('Orphan', noticeFor: 'nobody'),
      ]);

      expect(
        choices.map((c) => c.selected.kind),
        <String>['ModifySmartschoolData', 'Orphan'],
      );
      expect(choices.last.notices, isEmpty);
    });

    test('decisions keep their order when a notice sits between them', () {
      final choices = _collapse(const [
        _Option('Lone'),
        _Option('Note', noticeFor: 'b'),
        _Option('B', group: 'b'),
        _Option('A', group: 'a'),
      ]);

      expect(choices.map((c) => c.selected.kind), <String>['Lone', 'B', 'A']);
      expect(choices[1].notices.map((o) => o.kind), <String>['Note']);
    });

    test('no noticeFor accessor leaves the old partition untouched', () {
      // Every caller that has no notion of notices — and every stored document
      // written before #329 — collapses exactly as it always did.
      final choices = collapseAlternatives<_Option>(
        const [
          _Option('A', group: 'g', isDefault: true),
          _Option('B', group: 'g'),
        ],
        groupOf: (o) => o.group,
        isDefault: (o) => o.isDefault,
      );

      expect(choices.single.options, hasLength(2));
      expect(choices.single.notices, isEmpty);
    });
  });
}
