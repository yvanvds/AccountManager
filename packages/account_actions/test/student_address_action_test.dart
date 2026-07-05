import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// A WISA-shaped home address: `country` hardcoded to 'BE' (as the WISA CSV
/// parser does) and an empty bus number mapped to `null`.
Address _wisaAddr({
  String street = 'Koophandelstraat',
  String houseNumber = '32',
  String? add,
  String postalCode = '3270',
  String city = 'Scherpenheuvel',
}) =>
    Address(
      street: street,
      houseNumber: houseNumber,
      houseNumberAdd: add,
      postalCode: postalCode,
      city: city,
      country: 'BE',
    );

/// The Smartschool-shaped counterpart of [_wisaAddr]: a free-text `country`
/// and an empty (never-null) bus number — the exact representational shape the
/// Smartschool connector produces.
Address _ssAddr({
  String street = 'Koophandelstraat',
  String houseNumber = '32',
  String add = '',
  String postalCode = '3270',
  String city = 'Scherpenheuvel',
  String country = 'België',
}) =>
    Address(
      street: street,
      houseNumber: houseNumber,
      houseNumberAdd: add,
      postalCode: postalCode,
      city: city,
      country: country,
    );

ModifySmartschoolStudentAddress _action({
  required Address ss,
  required Address wisa,
}) =>
    ModifySmartschoolStudentAddress(
      linked(
        wisa: wisaStudent(address: wisa),
        smartschool: ssAccount(address: ss),
        azure: azureUser(),
      ),
      config(),
    );

void main() {
  group('ModifySmartschoolStudentAddress.evaluate (#153)', () {
    test(
        'does NOT fire when the addresses differ only on country / empty bus '
        'number (the systematic false positive)', () {
      // Same street/number/postcode/city; Smartschool has country "België" and
      // an empty bus number, WISA has "BE" and a null bus number.
      final action = _action(ss: _ssAddr(), wisa: _wisaAddr());
      expect(action.evaluate(), isFalse);
    });

    test('fires on a genuine postalCode difference', () {
      final action = _action(
          ss: _ssAddr(postalCode: '3270'), wisa: _wisaAddr(postalCode: '3271'));
      expect(action.evaluate(), isTrue);
    });

    test('fires on a genuine houseNumberAdd difference', () {
      final action = _action(ss: _ssAddr(add: ''), wisa: _wisaAddr(add: 'A'));
      expect(action.evaluate(), isTrue);
    });
  });

  group('ModifySmartschoolStudentAddress.describeChanges (#153)', () {
    Map<String, FieldChange> byField(ChangeSet cs) =>
        {for (final f in cs.fields) f.field: f};

    test('surfaces a postalCode-only difference (previously hidden)', () {
      final cs = _action(
        ss: _ssAddr(postalCode: '3270'),
        wisa: _wisaAddr(postalCode: '3271'),
      ).describeChanges();
      final fields = byField(cs);

      expect(fields.containsKey('postalCode'), isTrue,
          reason: 'the differing field must be visible');
      expect(fields['postalCode']!.before, '3270');
      expect(fields['postalCode']!.after, '3271');

      // No misleading identical rows for the fields that did not change…
      expect(fields.containsKey('street'), isFalse);
      expect(fields.containsKey('city'), isFalse);
      // …and country is never surfaced (it is intentionally not synced).
      expect(fields.containsKey('country'), isFalse);
    });

    test('surfaces a houseNumberAdd-only difference', () {
      final cs = _action(
        ss: _ssAddr(add: ''),
        wisa: _wisaAddr(add: 'A'),
      ).describeChanges();
      final fields = byField(cs);

      expect(fields.containsKey('houseNumberAdd'), isTrue);
      expect(fields['houseNumberAdd']!.after, 'A');
      // The empty bus number shows as ∅ (null), not as a spurious other field.
      expect(fields.length, 1);
    });

    test('surfaces street and houseNumber components independently', () {
      final cs = _action(
        ss: _ssAddr(street: 'Kerkstraat', houseNumber: '5'),
        wisa: _wisaAddr(street: 'Koophandelstraat', houseNumber: '32'),
      ).describeChanges();
      final fields = byField(cs);

      expect(fields['street']!.after, 'Koophandelstraat');
      expect(fields['houseNumber']!.after, '32');
    });
  });

  group('ModifySmartschoolStudentAddress.apply (#153)', () {
    test('writes WISA home fields but preserves the Smartschool country',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = _action(
        ss: _ssAddr(postalCode: '3270', country: 'België'),
        wisa: _wisaAddr(postalCode: '3271'),
      );

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(transport.soapActions, isNotEmpty);
      final written = (result.smartschool! as ss.SmartschoolAccount).address;
      expect(written.postalCode, '3271', reason: 'WISA value is pushed');
      expect(written.country, 'België',
          reason: 'Smartschool country is preserved, not overwritten with BE');
    });
  });
}
