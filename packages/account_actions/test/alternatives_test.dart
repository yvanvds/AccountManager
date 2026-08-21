import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

/// A stand-in for anything carrying the two alternative keys — the point of
/// [collapseAlternatives] is that it knows nothing about actions or candidates,
/// so the reconcile controller's live options and the materialized view's
/// persisted candidates get the same partition (#251).
class _Option {
  const _Option(this.kind, {this.group, this.isDefault = false});
  final String kind;
  final String? group;
  final bool isDefault;
}

List<Alternatives<_Option>> _collapse(List<_Option> options) =>
    collapseAlternatives<_Option>(
      options,
      groupOf: (o) => o.group,
      isDefault: (o) => o.isDefault,
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
}
