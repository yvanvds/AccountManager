import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

void main() {
  group('StringId equality', () {
    test('same type + same value are equal', () {
      expect(const PersonId('abc'), equals(const PersonId('abc')));
      expect(
        const PersonId('abc').hashCode,
        equals(const PersonId('abc').hashCode),
      );
    });

    test('same type + different value are not equal', () {
      expect(const PersonId('abc'), isNot(equals(const PersonId('xyz'))));
    });

    test('different concrete types are never equal, even for the same value',
        () {
      // The defining invariant: typed identity prevents accidental
      // cross-system reuse. PersonId("x") and WisaId("x") must be distinct.
      expect(const PersonId('x'), isNot(equals(const WisaId('x'))));
      expect(const WisaId('x'), isNot(equals(const WisaStaffCode('x'))));
      expect(const GroupId('x'), isNot(equals(const PersonId('x'))));
      expect(const LinkedAccountId('x'), isNot(equals(const PersonId('x'))));
    });

    test('hashCode differs across concrete types for the same value', () {
      // Not strictly required by the contract (equal objects must share
      // hashCode; unequal objects *may* share it), but our impl folds the
      // runtimeType in so collisions across types are unlikely. This catches
      // accidental regressions where hashCode only looked at value.
      expect(
        const PersonId('x').hashCode,
        isNot(equals(const WisaId('x').hashCode)),
      );
    });

    test('toString includes the runtime type', () {
      expect(const PersonId('abc').toString(), equals('PersonId(abc)'));
      expect(const WisaId('w-1').toString(), equals('WisaId(w-1)'));
    });

    test('toJson returns the wrapped string', () {
      expect(const PersonId('abc').toJson(), equals('abc'));
      expect(const WisaStaffCode('s-7').toJson(), equals('s-7'));
    });

    test('identical(a, a) short-circuits to true', () {
      const id = PersonId('abc');
      // ignore: unrelated_type_equality_checks
      expect(id == id, isTrue);
    });
  });
}
