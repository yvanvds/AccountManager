import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  group('smartschoolRole', () {
    final cases = {
      core.PersonRole.student: 'Leerling',
      core.PersonRole.teacher: 'Leerkracht',
      core.PersonRole.support: 'Leerkracht',
      core.PersonRole.it: 'Leerkracht',
      core.PersonRole.maintenance: 'Leerkracht',
      core.PersonRole.director: 'Directie',
    };
    cases.forEach((role, expected) {
      test('$role -> $expected', () {
        expect(smartschoolRole(role), expected);
      });
    });

    test('Other is refused', () {
      expect(
        () => smartschoolRole(core.PersonRole.other),
        throwsA(isA<UnsupportedSmartschoolRole>()),
      );
    });
  });

  group('personRoleFromBasisrol', () {
    final cases = {
      '1': core.PersonRole.student,
      '0': core.PersonRole.teacher,
      '13': core.PersonRole.teacher,
      '30': core.PersonRole.director,
    };
    cases.forEach((code, expected) {
      test('$code -> $expected', () {
        expect(personRoleFromBasisrol(code), expected);
      });
    });

    test('unknown code -> null', () {
      expect(personRoleFromBasisrol('99'), isNull);
      expect(personRoleFromBasisrol(null), isNull);
    });
  });

  group('gender', () {
    test('write: Male -> m, others -> f', () {
      expect(smartschoolGender(core.Gender.male), 'm');
      expect(smartschoolGender(core.Gender.female), 'f');
      expect(smartschoolGender(core.Gender.x), 'f');
    });

    test('read: m -> Male, f -> Female, other -> x', () {
      expect(genderFromSmartschool('m'), core.Gender.male);
      expect(genderFromSmartschool('f'), core.Gender.female);
      expect(genderFromSmartschool('?'), core.Gender.x);
      expect(genderFromSmartschool(null), core.Gender.x);
    });
  });

  group('formatStamboek', () {
    final cases = {
      0: '',
      123456: '0123456',
      999999: '0999999',
      1000000: '1000000',
      1234567: '1234567',
    };
    cases.forEach((input, expected) {
      test('$input -> "$expected"', () {
        expect(formatStamboek(input), expected);
      });
    });
  });

  group('parseStamboek', () {
    test('parses ints, defaults to 0', () {
      expect(parseStamboek('123456'), 123456);
      expect(parseStamboek(' 42 '), 42);
      expect(parseStamboek(''), 0);
      expect(parseStamboek(null), 0);
      expect(parseStamboek('abc'), 0);
    });
  });

  group('accountStateFromStatus', () {
    final cases = {
      'actief': core.AccountState.active,
      'active': core.AccountState.active,
      'enabled': core.AccountState.active,
      'uitgeschakeld': core.AccountState.inactive,
      'administratief': core.AccountState.administrative,
      'administrative': core.AccountState.administrative,
      'weird': core.AccountState.invalid,
    };
    cases.forEach((status, expected) {
      test('"$status" -> $expected', () {
        expect(accountStateFromStatus(status), expected);
      });
    });
  });

  group('statusFromAccountState', () {
    test('maps each state to its string', () {
      expect(statusFromAccountState(core.AccountState.active), 'active');
      expect(statusFromAccountState(core.AccountState.inactive), 'inactive');
      expect(
        statusFromAccountState(core.AccountState.administrative),
        'administrative',
      );
      expect(statusFromAccountState(core.AccountState.invalid), 'invalid');
    });
  });

  group('smartschoolUserIdFrom', () {
    test('takes the middle segment of a referenceIdentifier (#138)', () {
      expect(smartschoolUserIdFrom('4069_12016_0'), 12016);
      // Co-account rows carry the same user id with a non-zero slot index.
      expect(smartschoolUserIdFrom('4069_12016_2'), 12016);
      expect(smartschoolUserIdFrom('  4069_1001_0  '), 1001);
    });

    test('returns null for a missing or malformed value', () {
      expect(smartschoolUserIdFrom(null), isNull);
      expect(smartschoolUserIdFrom(''), isNull);
      expect(smartschoolUserIdFrom('   '), isNull);
      // Too few / too many segments, or a non-numeric user segment.
      expect(smartschoolUserIdFrom('4069'), isNull);
      expect(smartschoolUserIdFrom('4069_12016'), isNull);
      expect(smartschoolUserIdFrom('4069_12016_0_1'), isNull);
      expect(smartschoolUserIdFrom('4069__0'), isNull);
      expect(smartschoolUserIdFrom('4069_abc_0'), isNull);
    });
  });
}
