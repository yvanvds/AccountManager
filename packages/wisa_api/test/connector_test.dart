import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';
import 'package:xml/xml.dart';

/// In-memory transport that maps a `(queryCode)` to a pre-recorded CSV
/// blob and wraps the blob in a base64-encoded `GetCSVDataResponse`
/// envelope.
class _FakeTransport implements WisaSoapTransport {
  final Map<String, String> csvByQuery;
  final List<({String queryCode, List<({String name, String value})> params})>
      calls = [];

  _FakeTransport(this.csvByQuery);

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final doc = XmlDocument.parse(envelope);
    final queryCode = doc.findAllElements('QueryCode').first.innerText.trim();
    final params = <({String name, String value})>[];
    for (final item in doc.findAllElements('item')) {
      final name = item.findElements('Name').firstOrNull?.innerText ?? '';
      final value = item.findElements('Value').firstOrNull?.innerText ?? '';
      params.add((name: name, value: value));
    }
    calls.add((queryCode: queryCode, params: params));

    final csv = csvByQuery[queryCode];
    if (csv == null) {
      throw StateError('No fixture for query "$queryCode"');
    }
    final encoded = base64.encode(latin1.encode(csv));
    return '''<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body>
    <NS1:GetCSVDataResponse xmlns:NS1="urn:WisaAPIService-WisaAPIService">
      <Result xsi:type="xsd:base64Binary" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">$encoded</Result>
    </NS1:GetCSVDataResponse>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>''';
  }
}

String _readFixture(String name) {
  // Resolve fixtures relative to this file's URI so the test works
  // whether `dart test` is invoked from the package root or the
  // workspace root.
  final uri = Uri.base.resolve('test/fixtures/$name');
  final tryPaths = <String>[
    uri.toFilePath(),
    'test/fixtures/$name',
    'packages/wisa_api/test/fixtures/$name',
  ];
  for (final p in tryPaths) {
    final f = File(p);
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw FileSystemException('fixture not found: $name', tryPaths.join(', '));
}

void main() {
  final fixtures = {
    WisaQuery.testConnection: _readFixture('sma_test_con.csv'),
    WisaQuery.getSchools: _readFixture('sma_get_inst.csv'),
    WisaQuery.syncClassGroups: _readFixture('sync_klas.csv'),
    WisaQuery.syncStudents: _readFixture('sma_sync_lln.csv'),
    WisaQuery.syncStaff: _readFixture('sma_sync_per.csv'),
  };

  WisaConnector buildConnector(_FakeTransport transport) =>
      WisaConnector.fromParts(
        server: 'fake-host',
        port: 80,
        database: 'db',
        username: 'user',
        password: 'pw',
        transport: transport,
      );

  group('testConnection', () {
    test('returns true when fixture is non-empty', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      expect(await c.testConnection(), isTrue);
      expect(t.calls.single.queryCode, 'SMATestCon');
    });

    test('returns false when fixture is empty', () async {
      final t = _FakeTransport({...fixtures, WisaQuery.testConnection: ''});
      final c = buildConnector(t);
      expect(await c.testConnection(), isFalse);
    });
  });

  group('loadSchools', () {
    test('parses every school in the fixture with isVirtual=false', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      expect(schools, isNotEmpty);
      expect(schools.every((s) => !s.isVirtual), isTrue);
      // The redacted fixture preserves the legacy edge case of a "?"
      // placeholder school at id 0 — a row with no long name, only a code.
      expect(schools.any((s) => s.id == 0 && s.name == '' && s.code == '?'),
          isTrue);
      // ISMAA (id 25) is the primary active school in the fixture. Its two
      // halves land on the fields that claim them: the long name on `name`,
      // the short code on `code` (#208).
      final ismaa = schools.firstWhere((s) => s.id == 25);
      expect(ismaa.name, 'Instituut Sancta Maria-A');
      expect(ismaa.code, 'ISMAA');
    });
  });

  group('sync', () {
    test('produces a snapshot from the active school', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final school = schools.firstWhere((s) => s.id == 25);
      final snapshot = await c.sync(
        schools: [school],
        workDate: DateTime(2024, 9, 1),
      );
      expect(snapshot.origin, core.Origin.wisa);
      expect(snapshot.students, isNotEmpty);
      expect(snapshot.staff, isNotEmpty);
      expect(snapshot.classGroups, isNotEmpty);
      expect(snapshot.schools, hasLength(1));
      // The fixture has real multi-subgroup classes (e.g. 2A with MAW,
      // MOW, STEMW, ECO subgroups). The dedupe drops the "00" row when
      // any non-"00" row exists, so we expect at least one subgroup
      // class.
      expect(
        snapshot.classGroups.any((g) => g.groupName != '00'),
        isTrue,
      );
    });

    test('parses a student whose ROEPNAAM has an unquoted comma (issue #148)',
        () async {
      // The fixture carries one row with a comma-bearing call name
      // ("Pref9999, Servais"), emitted unquoted like real WISA data. The
      // whole sync used to abort on it; now it flows through with every
      // column aligned.
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final snapshot = await c.sync(
        schools: [schools.firstWhere((s) => s.id == 25)],
        workDate: DateTime(2024, 9, 1),
      );
      final student = snapshot.students
          .firstWhere((s) => s.wisaId == const core.WisaId('99999'));
      expect(student.name, 'Anon9999');
      expect(student.firstName, 'First9999');
      expect(student.preferredName, 'Pref9999, Servais');
      expect(student.birthDate, DateTime(2011, 5, 7));
      expect(student.address.city, 'ANON_CITY');
      expect(student.classChange, DateTime(2025, 9, 1));
    });

    test('sends Werkdatum=dd/MM/yyyy', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      await c.sync(
        schools: [schools.firstWhere((s) => s.id == 25)],
        workDate: DateTime(2024, 9, 1),
      );
      final werkdates = t.calls
          .expand((c) => c.params)
          .where((p) => p.name == 'Werkdatum')
          .map((p) => p.value)
          .toSet();
      expect(werkdates, {'01/09/2024'});
    });

    test('uses virtualWorkDate when school.isVirtual is true', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final ismaa = schools.firstWhere((s) => s.id == 25);
      final markedVirtual = WisaConnector.applySchoolRules(
        [ismaa],
        const [MarkAsVirtual('ISMAA')],
      );
      await c.sync(
        schools: markedVirtual,
        workDate: DateTime(2024, 9, 1),
        virtualWorkDate: DateTime(2025, 9, 1),
      );
      final werkdates = t.calls
          .expand((c) => c.params)
          .where((p) => p.name == 'Werkdatum')
          .map((p) => p.value)
          .toSet();
      expect(werkdates, {'01/09/2025'});
    });

    test(
        'sends each school its own Werkdatum: the virtual date for virtual '
        'schools, the ordinary one for the rest (#203)', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      // ISMAA is pulled as a virtual school, ISMAB as an ordinary one, in the
      // same sync — the mixed case the per-school work date exists for.
      final virtual = schools.firstWhere((s) => s.id == 25);
      final ordinary = schools.firstWhere((s) => s.id == 27);
      await c.sync(
        schools: [virtual.copyWith(isVirtual: true), ordinary],
        workDate: DateTime(2024, 9, 1),
        virtualWorkDate: DateTime(2025, 9, 1),
      );

      String? paramOf(
        List<({String name, String value})> params,
        String name,
      ) {
        for (final p in params) {
          if (p.name == name) return p.value;
        }
        return null;
      }

      final bySchool = <String, Set<String>>{};
      for (final call in t.calls) {
        final id = paramOf(call.params, 'IS_ID');
        final wd = paramOf(call.params, 'Werkdatum');
        if (id == null || wd == null) continue;
        bySchool.putIfAbsent(id, () => <String>{}).add(wd);
      }
      // Every query for the virtual school (classes, students, staff) carried
      // the virtual date; every query for the ordinary school carried the
      // ordinary one.
      expect(bySchool['25'], {'01/09/2025'});
      expect(bySchool['27'], {'01/09/2024'});
    });

    test('applies ReplaceInstitute to matching class group schoolCodes',
        () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      // The fixture uses real institute number '125252' for ISMAA's
      // class groups.
      final beforeMatch = (await c.sync(
        schools: [schools.firstWhere((s) => s.id == 25)],
        workDate: DateTime(2024, 9, 1),
      ))
          .classGroups
          .where((g) => g.schoolCode == '125252')
          .length;
      expect(beforeMatch, greaterThan(0));

      final afterSnapshot = await c.sync(
        schools: [schools.firstWhere((s) => s.id == 25)],
        workDate: DateTime(2024, 9, 1),
        rules: const [
          ReplaceInstitute(original: '125252', replacement: '999999'),
        ],
      );
      expect(
        afterSnapshot.classGroups.any((g) => g.schoolCode == '125252'),
        isFalse,
      );
      expect(
        afterSnapshot.classGroups.where((g) => g.schoolCode == '999999').length,
        beforeMatch,
      );
    });

    test('applies DontImportClass at snapshot construction', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final school = schools.firstWhere((s) => s.id == 25);
      final before = (await c.sync(
        schools: [school],
        workDate: DateTime(2024, 9, 1),
      ))
          .classGroups;
      // Pick any class group present in the snapshot and drop it.
      final target = before.first.name;
      final after = (await c.sync(
        schools: [school],
        workDate: DateTime(2024, 9, 1),
        rules: [DontImportClass(target)],
      ))
          .classGroups;
      expect(after.any((g) => g.name == target), isFalse);
      expect(after.length, lessThan(before.length));
    });

    test('applies DontImportUserFromWisa at snapshot construction', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final school = schools.firstWhere((s) => s.id == 25);
      final before = (await c.sync(
        schools: [school],
        workDate: DateTime(2024, 9, 1),
      ))
          .staff;
      // 'AAAAA' is the first generated code in the redacted fixture.
      final after = (await c.sync(
        schools: [school],
        workDate: DateTime(2024, 9, 1),
        rules: const [DontImportUserFromWisa('AAAAA')],
      ))
          .staff;
      expect(after.any((s) => s.code.value == 'AAAAA'), isFalse);
      expect(after.length, before.length - 1);
    });

    test('dedupes staff across schools by code', () async {
      // Two schools, same staff CSV (the fake transport returns the
      // same fixture regardless of IS_ID) — duplicate codes must be
      // dropped on the second load.
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final twoSchools = [
        schools.firstWhere((s) => s.id == 25),
        schools.firstWhere((s) => s.id == 27),
      ];
      final oneSchool = await c.sync(
        schools: [twoSchools.first],
        workDate: DateTime(2024, 9, 1),
      );
      final t2 = _FakeTransport(fixtures);
      final c2 = buildConnector(t2);
      final bothSchools = await c2.sync(
        schools: twoSchools,
        workDate: DateTime(2024, 9, 1),
      );
      expect(bothSchools.staff.length, oneSchool.staff.length);
    });
  });

  group('SOAP fault handling', () {
    test('testConnection returns false on SOAP fault', () async {
      final t = _FaultingTransport();
      final c = buildConnector(t as _FakeTransport);
      // _FaultingTransport extends _FakeTransport with a different send
      // implementation, so this works through dynamic dispatch.
      expect(await c.testConnection(), isFalse);
    });
  });
}

class _FaultingTransport extends _FakeTransport {
  _FaultingTransport() : super(const {});
  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    throw WisaSoapFault('SOAP-ENV:Server', 'Database is offline');
  }
}
