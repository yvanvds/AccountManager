import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

String? _readFixtureOrNull(String name) {
  final tryPaths = <String>[
    Uri.base.resolve('test/fixtures/$name').toFilePath(),
    'test/fixtures/$name',
    'packages/smartschool_api/test/fixtures/$name',
  ];
  for (final p in tryPaths) {
    final f = File(p);
    if (f.existsSync()) return f.readAsStringSync();
  }
  return null;
}

String _readFixture(String name) {
  final v = _readFixtureOrNull(name);
  if (v == null) throw FileSystemException('fixture not found', name);
  return v;
}

// ---------------------------------------------------------------------------
// Fake transport: replays fixtures, records write calls, configurable codes.
// ---------------------------------------------------------------------------

class _Call {
  final String method;
  final Map<String, String> args;
  _Call(this.method, this.args);
}

class _FakeTransport implements SmartschoolSoapTransport {
  /// Per-method override for the integer result of write operations.
  final Map<String, int> writeResults;
  final List<_Call> calls = [];

  _FakeTransport({this.writeResults = const {}});

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final doc = XmlDocument.parse(envelope);
    final method = doc
        .rootElement // Envelope
        .childElements
        .first // Body
        .childElements
        .first; // method
    final name = method.name.local;
    final args = <String, String>{
      for (final a in method.childElements) a.name.local: a.innerText,
    };
    calls.add(_Call(name, args));

    switch (name) {
      case SmartschoolMethod.getAllGroupsAndClasses:
        final b64 = base64.encode(utf8.encode(_readFixture('group_tree.xml')));
        return _wrap(name, b64, 'xsd:base64Binary');
      case SmartschoolMethod.getAllAccountsExtended:
        final code = args['code'] ?? '';
        final json = _readFixtureOrNull('accounts_$code.json');
        if (json == null) return _wrap(name, '19', 'xsd:int');
        return _wrap(name, json, 'xsd:string');
      case SmartschoolMethod.returnJsonErrorCodes:
        return _wrap(name, _readFixture('error_codes.json'), 'xsd:string');
      default:
        final code = writeResults[name] ?? 0;
        return _wrap(name, '$code', 'xsd:int');
    }
  }

  /// Builds an RPC response envelope with a single `<return>`; XmlBuilder
  /// escapes the (possibly JSON) text automatically.
  String _wrap(String method, String value, String type) {
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="utf-8"');
    b.element(
      'soap:Envelope',
      namespaces: {
        'http://schemas.xmlsoap.org/soap/envelope/': 'soap',
        'http://www.w3.org/2001/XMLSchema-instance': 'xsi',
      },
      nest: () {
        b.element(
          'soap:Body',
          nest: () {
            b.element(
              '${method}Response',
              nest: () {
                b.element(
                  'return',
                  nest: () {
                    b.attribute(
                      'type',
                      type,
                      namespace: 'http://www.w3.org/2001/XMLSchema-instance',
                    );
                    b.text(value);
                  },
                );
              },
            );
          },
        );
      },
    );
    return b.buildDocument().toXmlString();
  }

  _Call callTo(String method) => calls.firstWhere((c) => c.method == method);
  bool sentTo(String method) => calls.any((c) => c.method == method);
}

class _RecordingLog implements core.ILog {
  final List<String> messages = [];
  final List<String> errors = [];
  @override
  void addMessage(core.Origin origin, String message) => messages.add(message);
  @override
  void addError(core.Origin origin, String message) => errors.add(message);
}

SmartschoolConnector _connector(
  _FakeTransport transport, {
  core.ILog? log,
}) =>
    SmartschoolConnector.fromParts(
      site: 'demo',
      accessCode: 'secret',
      transport: transport,
      log: log,
    );

SmartschoolAccount _student() => SmartschoolAccount(
      uid: 'jand',
      accountId: 'W001',
      mail: 'jan@school.be',
      registerId: '10030512345',
      stemId: 123456,
      role: core.PersonRole.student,
      givenName: 'Jan',
      surname: 'Desmet',
      extraNames: 'Jan Baptist',
      initials: 'J.B.',
      preferredName: 'Jantje',
      gender: core.Gender.male,
      birthDate: DateTime(2010, 3, 5),
      birthPlace: 'Leuven',
      birthCountry: 'België',
      address: const core.Address(
        street: 'Kerkstraat',
        houseNumber: '12',
        houseNumberAdd: 'A',
        postalCode: '3000',
        city: 'Leuven',
        country: 'België',
      ),
      mobilePhone: '0470111222',
      homePhone: '016111222',
      fax: '',
      untisId: '',
      status: 'actief',
    );

void main() {
  group('sync', () {
    test('flattens the group tree with parentId edges', () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      expect(
        snap.groups.map((g) => g.id.value),
        ['SCH', 'C1A', 'C1B', 'GSPORT'],
      );
      final c1a = snap.groups.firstWhere((g) => g.id.value == 'C1A');
      expect(c1a.parentId, const core.GroupId('SCH'));
      expect(c1a.official, isTrue);
      expect(snap.groups.first.parentId, isNull);
    });

    test('dedupes account records by uid and filters disabled accounts',
        () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      final uids = snap.accounts.map((a) => a.uid).toList();
      expect(uids..sort(), ['jand', 'miek', 'saral']);
      expect(uids, isNot(contains('olduser')));
    });

    test('preserves multi-membership (PAIN-1)', () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      final jandGroups = snap.memberships
          .where((m) => m.uid == 'jand')
          .map((m) => m.groupId.value)
          .toList();
      expect(jandGroups, containsAll(['C1A', 'GSPORT']));
      expect(jandGroups, hasLength(2));
      expect(snap.memberships, hasLength(4));
    });

    test('keeps both accounts that share a mail (INV-13/23)', () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      final shared =
          snap.accounts.where((a) => a.mail == 'shared@school.be').toList();
      expect(shared.map((a) => a.uid).toList()..sort(), ['miek', 'saral']);
    });

    test('surfaces co-account slots, dropping empty ones', () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      final saral = snap.accounts.firstWhere((a) => a.uid == 'saral');
      expect(saral.coAccounts.map((c) => c.slot), [1, 3]);
      expect(saral.coAccounts.first.type, 'Moeder');
      expect(saral.preferredName, 'Sarah');
    });

    test('parses stamboeknummer to int', () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      final jand = snap.accounts.firstWhere((a) => a.uid == 'jand');
      expect(jand.stemId, 123456);
    });

    test('carries the referenceIdentifier and internal user id (#138)',
        () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      final jand = snap.accounts.firstWhere((a) => a.uid == 'jand');
      expect(jand.referenceIdentifier, '4069_1001_0');
      expect(jand.internalUserId, 1001);

      // A truncated value (older tenants) survives the sync as-is; only the
      // derived id is null. The account is not dropped or degraded.
      final saral = snap.accounts.firstWhere((a) => a.uid == 'saral');
      expect(saral.referenceIdentifier, '4069');
      expect(saral.internalUserId, isNull);
    });

    test('backfills Smartschool group ids onto the snapshot groups (#138)',
        () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync();
      final byCode = {for (final g in snap.groups) g.id.value: g.sourceId};
      // C1A/C1B come from their own account payloads; GSPORT's id is also
      // named by jand's C1A payload, so the join is a union over every
      // response, not a per-group read.
      expect(byCode['C1A'], 101);
      expect(byCode['C1B'], 102);
      expect(byCode['GSPORT'], 401);
      // SCH has no direct accounts (code 19), so nothing names its id.
      expect(byCode['SCH'], isNull);
      // No extra API call was made to resolve them.
      expect(t.sentTo('getClassListJson'), isFalse);
    });

    test('leaves group ids null when no payload names them (#138)', () async {
      // Discarding Sport removes the only payload that names GSPORT *and*
      // GSPORT itself; C1A is still resolved from its own payload.
      final t = _FakeTransport();
      final snap = await _connector(t).sync(
        rules: const [DiscardSmartschoolGroup('Sport')],
      );
      final byCode = {for (final g in snap.groups) g.id.value: g.sourceId};
      expect(byCode.keys, ['SCH', 'C1A', 'C1B']);
      expect(byCode['C1A'], 101);
      expect(byCode['SCH'], isNull);
    });

    test('applies DiscardSmartschoolGroup before loading accounts', () async {
      final t = _FakeTransport();
      final snap = await _connector(t).sync(
        rules: const [DiscardSmartschoolGroup('Sport')],
      );
      expect(
        snap.groups.map((g) => g.id.value),
        ['SCH', 'C1A', 'C1B'],
      );
      expect(
          snap.accounts.map((a) => a.uid).toList()..sort(), ['jand', 'miek']);
      expect(snap.memberships, hasLength(2));
      expect(t.sentTo(SmartschoolMethod.getAllAccountsExtended), isTrue);
      // GSPORT accounts must never be requested.
      final codes = t.calls
          .where((c) => c.method == SmartschoolMethod.getAllAccountsExtended)
          .map((c) => c.args['code'])
          .toList();
      expect(codes, isNot(contains('GSPORT')));
    });
  });

  group('saveAccount', () {
    test('maps fields, writes QR + preferred name, returns true', () async {
      final t = _FakeTransport();
      final log = _RecordingLog();
      final ok = await _connector(t, log: log).saveAccount(
        _student(),
        password: 'pw1',
        coAccountPasswords: const ['cpw1'],
      );
      expect(ok, isTrue);

      final save = t.callTo(SmartschoolMethod.saveUser).args;
      expect(save['internnumber'], 'W001');
      expect(save['username'], 'jand');
      expect(save['passwd1'], 'pw1');
      expect(save['passwd2'], 'cpw1');
      expect(save['passwd3'], '');
      expect(save['sex'], 'm');
      expect(save['birthday'], '2010-3-5');
      expect(save['address'], 'Kerkstraat 12/A');
      expect(save['stamboeknummer'], '0123456');
      expect(save['basisrol'], 'Leerling');
      expect(save['prn'], '10030512345');

      // QR code parameter write.
      final params = t.calls
          .where((c) => c.method == SmartschoolMethod.saveUserParameter)
          .map((c) => c.args['paramName'])
          .toList();
      expect(params, contains('Interne nummer QR-code'));
      expect(params, contains('Roepnaam'));
    });

    test('refuses an account with no role', () async {
      final t = _FakeTransport();
      const account = SmartschoolAccount(
        uid: 'x',
        accountId: '',
        mail: '',
        registerId: '',
        stemId: 0,
        role: null,
        givenName: '',
        surname: '',
        extraNames: '',
        initials: '',
        preferredName: '',
        gender: core.Gender.x,
        birthDate: null,
        birthPlace: '',
        birthCountry: '',
        address: core.Address(
          street: '',
          houseNumber: '',
          postalCode: '',
          city: '',
          country: '',
        ),
        mobilePhone: '',
        homePhone: '',
        fax: '',
        untisId: '',
        status: 'actief',
      );
      final ok = await _connector(t).saveAccount(account, password: 'p');
      expect(ok, isFalse);
      expect(t.sentTo(SmartschoolMethod.saveUser), isFalse);
    });

    test('returns false and logs when saveUser fails', () async {
      final t = _FakeTransport(
        writeResults: const {SmartschoolMethod.saveUser: 7},
      );
      final log = _RecordingLog();
      final ok = await _connector(t, log: log).saveAccount(
        _student(),
        password: 'p',
      );
      expect(ok, isFalse);
      expect(log.errors.join(), contains('Gebruiker bestaat niet'));
    });
  });

  group('password writes', () {
    test('setPassword passes the slot as an int', () async {
      final t = _FakeTransport();
      final ok = await _connector(t)
          .setPassword('jand', core.AccountType.coAccount1, 'pw');
      expect(ok, isTrue);
      final args = t.callTo(SmartschoolMethod.savePassword).args;
      expect(args['userIdentifier'], 'jand');
      expect(args['password'], 'pw');
      expect(args['accountType'], '1');
    });

    test('forcePasswordReset passes the slot as an int', () async {
      final t = _FakeTransport();
      final ok = await _connector(t)
          .forcePasswordReset('jand', core.AccountType.student);
      expect(ok, isTrue);
      expect(
        t.callTo(SmartschoolMethod.forcePasswordReset).args['accountType'],
        '0',
      );
    });
  });

  group('group writes', () {
    test('saveGroup', () async {
      final t = _FakeTransport();
      final ok = await _connector(t).saveGroup(
        name: 'Sport',
        description: 'Sportgroep',
        code: 'GSPORT',
        parentCode: 'SCH',
        untis: 'U',
      );
      expect(ok, isTrue);
      final args = t.callTo(SmartschoolMethod.saveGroup).args;
      expect(args['parent'], 'SCH');
      expect(args['desc'], 'Sportgroep');
    });

    test('saveClass carries institute and admin numbers', () async {
      final t = _FakeTransport();
      final ok = await _connector(t).saveClass(
        name: '1A',
        description: 'Klas 1A',
        code: 'C1A',
        parentCode: 'SCH',
        instituteNumber: '30024',
        adminNumber: 12345,
      );
      expect(ok, isTrue);
      final args = t.callTo(SmartschoolMethod.saveClass).args;
      expect(args['instituteNumber'], '30024');
      expect(args['adminNumber'], '12345');
    });

    test('deleteClass', () async {
      final t = _FakeTransport();
      expect(await _connector(t).deleteClass('C1A'), isTrue);
      expect(t.callTo(SmartschoolMethod.delClass).args['code'], 'C1A');
    });
  });

  group('membership writes', () {
    test('moveUserToClass sends the official date and class code', () async {
      final t = _FakeTransport();
      final ok = await _connector(t)
          .moveUserToClass('jand', 'C1B', DateTime(2026, 9, 1));
      expect(ok, isTrue);
      final args = t.callTo(SmartschoolMethod.saveUserToClass).args;
      expect(args['class'], 'C1B');
      expect(args['officialDate'], '2026-9-1');
    });

    test('addUserToGroup keeps existing memberships', () async {
      final t = _FakeTransport();
      expect(await _connector(t).addUserToGroup('jand', 'GSPORT'), isTrue);
      final args = t.callTo(SmartschoolMethod.saveUserToClassesAndGroups).args;
      expect(args['csvList'], 'GSPORT');
      expect(args['keepOld'], '1');
    });

    test('removeUserFromGroup identifies the group by name', () async {
      final t = _FakeTransport();
      final ok = await _connector(t)
          .removeUserFromGroup('jand', 'Sport', DateTime(2026, 1, 2));
      expect(ok, isTrue);
      expect(
        t.callTo(SmartschoolMethod.removeUserFromGroup).args['class'],
        'Sport',
      );
    });
  });

  group('lifecycle writes', () {
    test('deleteUser uses the 1-1-1 sentinel by default', () async {
      final t = _FakeTransport();
      await _connector(t).deleteUser('jand');
      expect(
        t.callTo(SmartschoolMethod.delUser).args['officialDate'],
        '1-1-1',
      );
    });

    test('deleteUser formats an official date when given', () async {
      final t = _FakeTransport();
      await _connector(t)
          .deleteUser('jand', officialDate: DateTime(2026, 6, 5));
      expect(
        t.callTo(SmartschoolMethod.delUser).args['officialDate'],
        '2026-6-5',
      );
    });

    test('unregisterStudent', () async {
      final t = _FakeTransport();
      await _connector(t).unregisterStudent('jand', DateTime(2026, 6, 5));
      expect(t.sentTo(SmartschoolMethod.unregisterStudent), isTrue);
    });

    test('changeUid addresses by internal number', () async {
      final t = _FakeTransport();
      await _connector(t).changeUid('W001', 'jand2');
      final args = t.callTo(SmartschoolMethod.changeUsername).args;
      expect(args['internNumber'], 'W001');
      expect(args['newUsername'], 'jand2');
    });

    test('changeAccountId addresses by username', () async {
      final t = _FakeTransport();
      await _connector(t).changeAccountId('jand', 'W999');
      final args = t.callTo(SmartschoolMethod.changeInternNumber).args;
      expect(args['username'], 'jand');
      expect(args['newInternNumber'], 'W999');
    });

    test('setAccountStatus maps the state to a string', () async {
      final t = _FakeTransport();
      await _connector(t).setAccountStatus('jand', core.AccountState.inactive);
      expect(
        t.callTo(SmartschoolMethod.setAccountStatus).args['accountStatus'],
        'inactive',
      );
    });
  });

  test('injected error codes avoid a network round-trip', () async {
    final t = _FakeTransport(
      writeResults: const {SmartschoolMethod.delClass: 1},
    );
    final log = _RecordingLog();
    final connector = SmartschoolConnector.fromParts(
      site: 'demo',
      accessCode: 'secret',
      transport: t,
      log: log,
      errorCodes: const SmartschoolErrorCodes({'1': 'Injected message'}),
    );
    final ok = await connector.deleteClass('C1A');
    expect(ok, isFalse);
    expect(log.errors.join(), contains('Injected message'));
    expect(t.sentTo(SmartschoolMethod.returnJsonErrorCodes), isFalse);
  });
}
