/// Opt-in integration test: drives the connector against a real WISA
/// host. Skipped when `WISA_USERNAME` is empty so `dart test` stays
/// offline by default.
///
/// Asserts only structural invariants — connection, presence of the
/// configured school, non-empty sync — and logs counts/booleans only.
/// Never logs row contents, never echoes the request envelope.
///
/// CI runs this in the `live-test` job of `.github/workflows/dart.yml`.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

void main() {
  final config = WisaLiveConfig.fromEnvironment();
  final skipReason = config == null
      ? 'WISA_USERNAME not set; skipping live integration tests.'
      : null;

  group('wisa_api live integration', skip: skipReason, () {
    late WisaConnector connector;

    setUpAll(() {
      // config is non-null here because the group is unskipped.
      connector = config!.connector();
    });

    test('testConnection succeeds', () async {
      bool ok;
      try {
        ok = await connector.testConnection();
      } on Exception catch (e) {
        // Defensive: redact before rethrowing so the test report cannot
        // echo a request envelope with credentials.
        throw Exception(
          'testConnection threw: ${redactCredentials(e.toString())}',
        );
      }
      expect(ok, isTrue, reason: 'WISA testConnection returned false');
    });

    test('loadSchools returns the configured school', () async {
      List<WisaSchool> schools;
      try {
        schools = await connector.loadSchools();
      } on Exception catch (e) {
        throw Exception(
          'loadSchools threw: ${redactCredentials(e.toString())}',
        );
      }
      expect(
        schools,
        isNotEmpty,
        reason: 'loadSchools returned no schools at all',
      );
      final ids = schools.map((s) => s.id).toSet();
      expect(
        ids,
        contains(config!.schoolId),
        reason: 'WISA_SCHOOL_ID=${config.schoolId} not present in schools '
            '(${schools.length} returned)',
      );
    });

    test('sync of the configured school is non-empty', () async {
      List<WisaSchool> schools;
      try {
        schools = await connector.loadSchools();
      } on Exception catch (e) {
        throw Exception(
          'loadSchools threw: ${redactCredentials(e.toString())}',
        );
      }
      final target = schools.where((s) => s.id == config!.schoolId).toList();
      expect(
        target,
        isNotEmpty,
        reason: 'WISA_SCHOOL_ID not in schools list',
      );

      // Not DateTime.now(): with a summer Werkdatum the export is
      // legitimately empty and the test false-fails all holiday (#57).
      final workDate = config!.resolveWorkDate(DateTime.now());
      stdout.writeln(
        '  workDate=${workDate.toIso8601String().split('T').first}',
      );

      WisaSnapshot snapshot;
      try {
        snapshot = await connector.sync(
          schools: target,
          workDate: workDate,
        );
      } on Exception catch (e) {
        throw Exception(
          'sync threw: ${redactCredentials(e.toString())}',
        );
      }

      // Counts only — never the rows themselves.
      stdout.writeln(
        '  students=${snapshot.students.length} '
        'staff=${snapshot.staff.length} '
        'classGroups=${snapshot.classGroups.length}',
      );

      expect(
        snapshot.students,
        isNotEmpty,
        reason: 'sync returned zero students',
      );
      expect(
        snapshot.staff,
        isNotEmpty,
        reason: 'sync returned zero staff',
      );
      expect(
        snapshot.classGroups,
        isNotEmpty,
        reason: 'sync returned zero class groups',
      );
    });
  });
}
