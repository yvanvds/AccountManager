import 'package:account_core/account_core.dart' as core;

import 'csv/csv_parser.dart';
import 'csv/date_format.dart';
import 'csv/row_parsers.dart';
import 'models/wisa_class_group.dart';
import 'models/wisa_school.dart';
import 'models/wisa_staff.dart';
import 'models/wisa_student.dart';
import 'rules/import_rules.dart';
import 'snapshot.dart';
import 'soap/credentials.dart';
import 'soap/soap_envelope.dart';
import 'soap/soap_transport.dart';

/// SOAP query codes used by the connector. Exposed as constants so tests
/// can pattern-match on them.
class WisaQuery {
  WisaQuery._();
  static const String getSchools = 'SMAGetInst';
  static const String syncStudents = 'SmaSyncLln';
  static const String syncStaff = 'SmaSyncPer';
  static const String syncClassGroups = 'SyncKlas';
  static const String testConnection = 'SMATestCon';
  static const String testQuery = 'SMATestQ';
}

/// SOAPAction header value for `GetCSVData`, per the WSDL binding.
const String _getCsvDataSoapAction =
    'urn:WisaAPIService-WisaAPIService#GetCSVData';

/// One-instance WISA SOAP connector.
///
/// Mirrors legacy single-instance behaviour (`legacy-wpf/AccountApi/Wisa/Connector.cs`):
/// one connector per WISA host per app run. Re-use the same instance
/// across [sync] / [testConnection] calls.
class WisaConnector {
  final Uri _endpoint;
  final WisaCredentials _credentials;
  final WisaSoapTransport _transport;
  final core.ILog? _log;

  /// [endpoint] is the full SOAP endpoint URL (e.g. `http://host:port/SOAP/`).
  /// Prefer the [WisaConnector.fromParts] constructor when starting from
  /// the legacy server/port pair.
  WisaConnector({
    required Uri endpoint,
    required WisaCredentials credentials,
    WisaSoapTransport? transport,
    core.ILog? log,
  })  : _endpoint = endpoint,
        _credentials = credentials,
        _transport = transport ?? HttpWisaSoapTransport(),
        _log = log;

  /// Convenience constructor matching the legacy `Connector.Init(...)`
  /// parameter shape.
  factory WisaConnector.fromParts({
    required String server,
    required int port,
    required String database,
    required String username,
    required String password,
    WisaSoapTransport? transport,
    core.ILog? log,
  }) {
    return WisaConnector(
      endpoint: Uri.parse('http://$server:$port/SOAP/'),
      credentials: WisaCredentials(
        username: username,
        password: password,
        database: database,
      ),
      transport: transport,
      log: log,
    );
  }

  /// Issues a `SMATestCon` query. Returns `true` if the response is
  /// non-empty (matches legacy semantics).
  Future<bool> testConnection() async {
    try {
      final csv = await _performQuery(WisaQuery.testConnection, const []);
      if (csv.isEmpty) {
        _log?.addError(
          core.Origin.wisa,
          'Verbindingstest leverde geen resultaat op.',
        );
        return false;
      }
      _log?.addMessage(core.Origin.wisa, 'Verbinding geslaagd.');
      return true;
    } on Exception catch (e) {
      _log?.addError(core.Origin.wisa, e.toString());
      return false;
    }
  }

  /// Pulls every school the credentials grant access to. Returns the
  /// list as it would appear in a snapshot — but **without** the
  /// [MarkAsVirtual] rule applied. Call [sync] for the rule-applied
  /// view.
  Future<List<WisaSchool>> loadSchools() async {
    final csv = await _performQuery(WisaQuery.getSchools, const []);
    if (csv.isEmpty) {
      // "Scholen", the word Instellingen names them with (its **Scholen
      // ophalen** button drives this very call), rather than WISA's own
      // "instellingen" — which in this app is the settings screen.
      _log?.addError(core.Origin.wisa, 'Scholen: leeg resultaat.');
      return const [];
    }
    final parsed = splitCsvWithHeader(csv, schoolCsvHeader);
    return [
      for (final row in parsed.rows)
        if (row.isNotEmpty) parseSchoolRow(row),
    ];
  }

  /// Runs a full sync for [schools].
  ///
  /// For each school:
  ///   - Class groups are pulled via `SyncKlas`.
  ///   - Students are pulled via `SmaSyncLln`.
  ///   - Staff are pulled via `SmaSyncPer`.
  ///
  /// [workDate] is used as the "Werkdatum" parameter for each query
  /// **unless** the school's `isVirtual` flag is set, in which case
  /// [virtualWorkDate] is used (falls back to [workDate] when null).
  /// Apply [MarkAsVirtual] rules to [schools] before passing them in
  /// (see [applySchoolRules]).
  ///
  /// [rules] is the full set of import rules — `ReplaceInstitute`,
  /// `DontImportClass`, and `DontImportUserFromWisa` are applied during
  /// snapshot construction here; `MarkAsVirtual` should already be
  /// reflected in the `isVirtual` flag of each school.
  Future<WisaSnapshot> sync({
    required Iterable<WisaSchool> schools,
    required DateTime workDate,
    DateTime? virtualWorkDate,
    Iterable<WisaImportRule> rules = const [],
  }) async {
    final allStudents = <WisaStudent>[];
    final allStaff = <WisaStaff>[];
    final allClassGroups = <WisaClassGroup>[];
    final seenStaffCodes = <String>{};

    for (final school in schools) {
      final wd = school.isVirtual ? (virtualWorkDate ?? workDate) : workDate;
      final wdParam = WisaParam('Werkdatum', formatWerkdatum(wd));
      final isIdParam = WisaParam('IS_ID', school.id.toString());
      final params = [isIdParam, wdParam];

      final classGroups = await _loadClassGroups(school, params);
      allClassGroups.addAll(_dedupeClassGroups(classGroups));

      final students = await _loadStudents(school, params);
      allStudents.addAll(students);

      final staff = await _loadStaff(school, params);
      for (final s in staff) {
        if (seenStaffCodes.add(s.code.value)) {
          allStaff.add(s);
        }
      }
    }

    return WisaSnapshot(
      fetchedAt: DateTime.now(),
      // The roster is only meaningful together with the date it is *as of*, so
      // the snapshot carries it out of here rather than leaving the caller to
      // re-derive a date that may already have moved on (#247).
      workDate: workDate,
      students: allStudents,
      staff: applyRulesToStaff(allStaff, rules),
      classGroups: applyRulesToClassGroups(allClassGroups, rules),
      schools: schools.toList(),
    );
  }

  /// Applies [MarkAsVirtual] rules to a freshly-loaded list of schools.
  /// Convenience for callers that want to compute the post-rule school
  /// list before passing it to [sync].
  static List<WisaSchool> applySchoolRules(
    Iterable<WisaSchool> schools,
    Iterable<WisaImportRule> rules,
  ) =>
      applyRulesToSchools(schools, rules);

  Future<List<WisaClassGroup>> _loadClassGroups(
    WisaSchool school,
    List<WisaParam> params,
  ) async {
    final csv = await _performQuery(WisaQuery.syncClassGroups, params);
    if (csv.isEmpty) {
      _log?.addError(core.Origin.wisa, 'Klassen: leeg resultaat.');
      return const [];
    }
    final parsed = splitCsvWithHeader(csv, classGroupCsvHeader);
    final groups = <WisaClassGroup>[];
    for (final row in parsed.rows) {
      if (row.isEmpty) continue;
      try {
        groups.add(parseClassGroupRow(row, schoolId: school.id));
      } on CsvRowParseException catch (e) {
        _log?.addError(core.Origin.wisa, e.toString());
        rethrow;
      }
    }
    _log?.addMessage(
      core.Origin.wisa,
      // The short code, as the sync log has always named a school — before
      // #208 that half simply sat on `school.name`.
      'Klassen opgehaald uit ${school.code}.',
    );
    return groups;
  }

  Future<List<WisaStudent>> _loadStudents(
    WisaSchool school,
    List<WisaParam> params,
  ) async {
    final csv = await _performQuery(WisaQuery.syncStudents, params);
    if (csv.isEmpty) {
      _log?.addError(core.Origin.wisa, 'Leerlingen: leeg resultaat.');
      return const [];
    }
    final parsed = splitCsvWithHeader(csv, studentCsvHeader);
    final students = <WisaStudent>[];
    for (final row in parsed.rows) {
      if (row.isEmpty) continue;
      try {
        students.add(parseStudentRow(row, schoolId: school.id));
      } on CsvRowParseException catch (e) {
        _log?.addError(core.Origin.wisa, e.toString());
        rethrow;
      }
    }
    _log?.addMessage(
      core.Origin.wisa,
      '${students.length} leerling(en) opgehaald uit ${school.code}.',
    );
    return students;
  }

  Future<List<WisaStaff>> _loadStaff(
    WisaSchool school,
    List<WisaParam> params,
  ) async {
    final csv = await _performQuery(WisaQuery.syncStaff, params);
    if (csv.isEmpty) {
      _log?.addError(core.Origin.wisa, 'Personeel: leeg resultaat.');
      return const [];
    }
    final parsed = splitCsvWithHeader(csv, staffCsvHeader);
    final staff = <WisaStaff>[];
    for (final row in parsed.rows) {
      if (row.isEmpty) continue;
      try {
        staff.add(parseStaffRow(row));
      } on CsvRowParseException catch (e) {
        _log?.addError(core.Origin.wisa, e.toString());
        rethrow;
      }
    }
    _log?.addMessage(
      core.Origin.wisa,
      '${staff.length} personeelsleden opgehaald uit ${school.code}.',
    );
    return staff;
  }

  /// Dedupes class groups within a single school's load following
  /// legacy `ClassGroupManager.AddSchool` behaviour: when a class has any
  /// row with a non-`"00"` groupName, drop the `"00"` row; otherwise drop
  /// any non-`"00"` rows (defensive — shouldn't occur).
  List<WisaClassGroup> _dedupeClassGroups(List<WisaClassGroup> groups) {
    final adminCodesByClass = <String, Set<String>>{};
    for (final g in groups) {
      adminCodesByClass.putIfAbsent(g.name, () => <String>{}).add(g.adminCode);
    }
    bool useSubGroups(String className) =>
        (adminCodesByClass[className]?.length ?? 0) > 1;
    return [
      for (final g in groups)
        if ((useSubGroups(g.name) && g.groupName != '00') ||
            (!useSubGroups(g.name) && g.groupName == '00'))
          g,
    ];
  }

  Future<String> _performQuery(String queryCode, List<WisaParam> params) async {
    final envelope = buildGetCsvDataEnvelope(
      credentials: _credentials,
      queryCode: queryCode,
      params: params,
    );
    final responseXml = await _transport.send(
      endpoint: _endpoint,
      soapAction: _getCsvDataSoapAction,
      envelope: envelope,
    );
    return decodeGetCsvDataResponse(responseXml);
  }
}
