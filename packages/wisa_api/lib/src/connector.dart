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

/// The `KLASGROEP` code WISA gives the administrative shell row that every
/// class carries — it names no real sub-group. See [WisaClassGroup.fullName],
/// which applies the same guard on the model side.
const String _noSubGroupSentinel = '00';

/// Whether a class-group row's `KLASGROEP` names a real sub-group — i.e. it is
/// neither blank nor the [_noSubGroupSentinel] shell. A blank would otherwise
/// survive [WisaConnector._dedupeClassGroups] and give the class the trailing
/// name `'2G '`.
bool _namesSubGroup(String groupName) {
  final trimmed = groupName.trim();
  return trimmed.isNotEmpty && trimmed != _noSubGroupSentinel;
}

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
  /// list as it would appear in a snapshot — but with every school
  /// non-virtual: which of them is virtual is the operator's per-school
  /// mark in Instellingen, stamped on by the app before [sync] (#277).
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
  /// Every population is concatenated across [schools] and each record carries
  /// the school it came from. A staff member the group employs at two schools
  /// comes back from two pulls under one `code`: the rows are folded into one
  /// record whose [WisaStaff.schoolIds] holds both (#340), the staff twin of how
  /// the linker merges a dual-enrolled student's second row (#318). The pull
  /// itself stays deliberately group-wide — a teacher still listed by a sibling
  /// school is the reason the staff removal actions do not fire on them.
  ///
  /// [workDate] is used as the "Werkdatum" parameter for each query
  /// **unless** the school's `isVirtual` flag is set, in which case
  /// [virtualWorkDate] is used (falls back to [workDate] when null).
  /// Flag [schools] from the operator's per-school virtual marks before
  /// passing them in — the app's `markVirtualSchools` does that (#277).
  ///
  /// [rules] is the full set of import rules — `ReplaceInstitute`,
  /// `DontImportClass`, and `DontImportUserFromWisa` — all applied during
  /// snapshot construction here. No rule touches a school any more.
  Future<WisaSnapshot> sync({
    required Iterable<WisaSchool> schools,
    required DateTime workDate,
    DateTime? virtualWorkDate,
    Iterable<WisaImportRule> rules = const [],
  }) async {
    final allStudents = <WisaStudent>[];
    final allStaff = <WisaStaff>[];
    final allClassGroups = <WisaClassGroup>[];
    // Staff `code` -> where that member's row sits in [allStaff], so a second
    // school's row merges its school id into the row already held instead of
    // being dropped (#340). Before that this was a plain seen-set and the
    // second occurrence was thrown away whole — which was harmless while a
    // staff row carried nothing school-specific, and is not any more.
    final staffRowByCode = <String, int>{};

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
        final at = staffRowByCode[s.code.value];
        if (at == null) {
          staffRowByCode[s.code.value] = allStaff.length;
          allStaff.add(s);
        } else {
          allStaff[at] = allStaff[at].withSchoolIds(s.schoolIds);
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
        staff.add(parseStaffRow(row, schoolId: school.id));
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
  ///
  /// The discriminator is the **existence of a named KLASGROEP row**, not the
  /// number of distinct `ADMINGROEP` codes (#362). Legacy
  /// `ClassGroupManager.UseSubGroups` counted admin codes and required `> 1`,
  /// and this was a faithful port of that — but the two only agree while every
  /// sub-group of a class happens to sit in its own administrative group.
  /// ISMAB's `2G` (rows `00` + `LAT`, both `ADMINGROEP 040092`) is the case
  /// where they part: one admin code made the count-based test say "no
  /// sub-groups", the `00` row won, and the class came in as a bare `2G`
  /// instead of `2G LAT` — dropping the only klasgroep its twelve students are
  /// actually enrolled in, and proposing the deletion of the real Smartschool
  /// class `2G LAT`. The number of sub-classes (one vs four) must not change
  /// how a class is named.
  ///
  /// Note this is also what the paragraph above always claimed the rule was;
  /// only the code disagreed. The state layer's twin test
  /// (`PlacementResolver._subGroupClasses`, which decides whether a student's
  /// `KLASGROEP` is appended to their target class name) moves with it — split
  /// them and the class is renamed while its students stay behind.
  ///
  /// A class with no named row at all keeps its `00` row(s) unchanged, so the
  /// overwhelmingly common single-group class is untouched.
  List<WisaClassGroup> _dedupeClassGroups(List<WisaClassGroup> groups) {
    final subGrouped = <String>{
      for (final g in groups)
        if (_namesSubGroup(g.groupName)) g.name,
    };
    return [
      for (final g in groups)
        // Keep the named rows of a sub-grouped class, and the shell rows of
        // every other class — i.e. exactly one of the two shapes per class.
        if (subGrouped.contains(g.name) == _namesSubGroup(g.groupName)) g,
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
