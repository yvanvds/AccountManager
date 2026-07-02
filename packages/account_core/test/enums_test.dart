import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

void main() {
  group('Enum JSON round-trip', () {
    test('PersonRole', () {
      for (final v in PersonRole.values) {
        expect(PersonRole.fromJson(v.toJson()), equals(v));
      }
    });

    test('Gender', () {
      for (final v in Gender.values) {
        expect(Gender.fromJson(v.toJson()), equals(v));
      }
    });

    test('GroupType', () {
      for (final v in GroupType.values) {
        expect(GroupType.fromJson(v.toJson()), equals(v));
      }
    });

    test('AccountType', () {
      for (final v in AccountType.values) {
        expect(AccountType.fromJson(v.toJson()), equals(v));
      }
    });

    test('AccountState', () {
      for (final v in AccountState.values) {
        expect(AccountState.fromJson(v.toJson()), equals(v));
      }
    });

    test('ConnectionState', () {
      for (final v in ConnectionState.values) {
        expect(ConnectionState.fromJson(v.toJson()), equals(v));
      }
    });

    test('Origin', () {
      for (final v in Origin.values) {
        expect(Origin.fromJson(v.toJson()), equals(v));
      }
    });

    test('Rule', () {
      for (final v in Rule.values) {
        expect(Rule.fromJson(v.toJson()), equals(v));
      }
    });

    test('RuleType', () {
      for (final v in RuleType.values) {
        expect(RuleType.fromJson(v.toJson()), equals(v));
      }
    });

    test('RuleAction', () {
      for (final v in RuleAction.values) {
        expect(RuleAction.fromJson(v.toJson()), equals(v));
      }
    });

    test('LinkConfidence', () {
      for (final v in LinkConfidence.values) {
        expect(LinkConfidence.fromJson(v.toJson()), equals(v));
      }
    });
  });

  group('AccountType numeric mapping', () {
    test('Smartschool API values match legacy 0..6', () {
      // Legacy AccountApi.Enums.AccountType: Student = 0, CoAccount1..6 = 1..6.
      expect(AccountType.student.smartschoolValue, 0);
      expect(AccountType.coAccount1.smartschoolValue, 1);
      expect(AccountType.coAccount2.smartschoolValue, 2);
      expect(AccountType.coAccount3.smartschoolValue, 3);
      expect(AccountType.coAccount4.smartschoolValue, 4);
      expect(AccountType.coAccount5.smartschoolValue, 5);
      expect(AccountType.coAccount6.smartschoolValue, 6);
    });

    test('round-trip through fromSmartschoolValue', () {
      for (final v in AccountType.values) {
        expect(AccountType.fromSmartschoolValue(v.smartschoolValue), equals(v));
      }
    });
  });

  test('Gender enum drops legacy Transgender in favour of x (spec §3.1)', () {
    // The new domain uses x where legacy Enums.cs uses Transgender; the
    // names are not preserved on purpose.
    expect(
      Gender.values.map((g) => g.name),
      unorderedEquals(<String>['male', 'female', 'x']),
    );
  });
}
