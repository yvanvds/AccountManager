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
    final queryCode =
        doc.findAllElements('QueryCode').first.innerText.trim();
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
    test('returns parsed schools with isVirtual=false', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      expect(schools, hasLength(2));
      expect(schools.first.id, 25);
      expect(schools.first.name, 'Sint-Maria-Aalst');
      expect(schools.first.description, 'SMA');
      expect(schools.every((s) => !s.isVirtual), isTrue);
    });
  });

  group('sync', () {
    test('produces a snapshot from fixtures', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final snapshot = await c.sync(
        schools: [schools.first],
        workDate: DateTime(2024, 9, 1),
      );
      expect(snapshot.origin, core.Origin.wisa);
      expect(snapshot.students, hasLength(3));
      expect(snapshot.staff, hasLength(3));
      // Class groups: the dedupe drops the "00" row of 3C because 3C also
      // has a non-"00" row, leaving 1A, 2B, and 3C/Alpha.
      expect(
        snapshot.classGroups.map((g) => g.fullName),
        containsAll(<String>['1A', '2B', '3C Alpha']),
      );
      expect(snapshot.schools, hasLength(1));
    });

    test('sends Werkdatum=dd/MM/yyyy', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      await c.sync(
        schools: [schools.first],
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
      final markedVirtual = WisaConnector.applySchoolRules(
        schools,
        const [MarkAsVirtual('Sint-Maria-Aalst')],
      );
      await c.sync(
        schools: [markedVirtual.first],
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

    test('applies ReplaceInstitute to class group schoolCodes', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final snapshot = await c.sync(
        schools: [schools.first],
        workDate: DateTime(2024, 9, 1),
        rules: const [
          ReplaceInstitute(original: '111111', replacement: '999999'),
        ],
      );
      expect(
        snapshot.classGroups.every((g) => g.schoolCode == '999999'),
        isTrue,
      );
    });

    test('applies DontImportClass at snapshot construction', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final snapshot = await c.sync(
        schools: [schools.first],
        workDate: DateTime(2024, 9, 1),
        rules: const [DontImportClass('2B')],
      );
      expect(
        snapshot.classGroups.any((g) => g.name == '2B'),
        isFalse,
      );
    });

    test('applies DontImportUserFromWisa at snapshot construction', () async {
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final snapshot = await c.sync(
        schools: [schools.first],
        workDate: DateTime(2024, 9, 1),
        rules: const [DontImportUserFromWisa('AAAAA')],
      );
      expect(
        snapshot.staff.any((s) => s.code.value == 'AAAAA'),
        isFalse,
      );
      expect(snapshot.staff, hasLength(2));
    });

    test('dedupes staff across schools by code', () async {
      // Two schools, same staff CSV — duplicate codes must be dropped.
      final t = _FakeTransport(fixtures);
      final c = buildConnector(t);
      final schools = await c.loadSchools();
      final snapshot = await c.sync(
        schools: schools, // both schools share the same staff fixture
        workDate: DateTime(2024, 9, 1),
      );
      expect(snapshot.staff, hasLength(3));
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
