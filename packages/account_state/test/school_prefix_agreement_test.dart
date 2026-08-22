// INV-22 has exactly one definition (#279), and this is the test that keeps it
// that way.
//
// The rule — student = exact `companyName`, staff = `department` *contains* our
// prefix — is asked from three places that must agree:
//
//   1. `azure_api`'s client-side reads (`loadClientFiltered`, the `/users/delta`
//      walk), which decide whether a row is kept **at all**;
//   2. `account_linker`'s `link()`, which decides whether an unmatched row is
//      kept as an orphan record;
//   3. `account_state`'s `retainedStaffEmployeeIds`, which decides whether a
//      departed staff member's id keeps being asked about.
//
// The asymmetry is what makes this worth a test: a read **wider** than the
// linker is merely wasteful, while a read **narrower** than the linker is
// silently lossy — the linker never gets to ask about a row the read already
// threw away, and no log line anywhere reports a row that never arrived. That is
// exactly how the copies drifted (`startsWith` in the connector vs `contains` in
// the linker) until #268, unnoticed.
//
// `account_state` is the only package that depends on all three, so the
// agreement is asserted here. Every assertion below is pinned to
// `core.studentBelongsToSchool` / `core.staffBelongsToSchool` rather than to a
// hard-coded expectation: re-inline a divergent copy of the rule in any one
// caller and this fails, whichever way the copy drifts.

import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:account_linker/account_linker.dart';
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

class _FakeGraphTransport implements GraphTransport {
  _FakeGraphTransport(this._route);

  final GraphResponse Function(GraphRequest) _route;

  @override
  Future<GraphResponse> send(GraphRequest request) async => _route(request);
}

GraphResponse _jsonOk(Object body) => GraphResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    );

class _SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

/// One tenant row, in the two shapes the test needs it: the Graph JSON the
/// connector parses, and the [AzureUser] the linker and the retention rule read.
class _Row {
  const _Row(this.id, {this.companyName, this.department, this.employeeId});

  final String id;
  final String? companyName;
  final String? department;
  final String? employeeId;

  Map<String, dynamic> get graphJson => <String, dynamic>{
        'id': id,
        'userPrincipalName': '$id@school.example',
        'displayName': id,
        if (employeeId != null) 'employeeId': employeeId,
        if (companyName != null) 'companyName': companyName,
        if (department != null) 'department': department,
      };

  AzureUser get user => AzureUser(
        id: id,
        upn: '$id@school.example',
        employeeId: employeeId,
        companyName: companyName,
        department: department,
      );
}

/// The tenant every case below reads: the drift cases (our prefix listed
/// second and third), their case/whitespace variants, the negative controls of
/// a genuinely foreign school, and the rows that carry no signal at all.
const _tenant = <_Row>[
  _Row('student-ours', companyName: 'GBS', employeeId: 'S1'),
  _Row('student-cased', companyName: ' gbs ', employeeId: 'S2'),
  _Row('student-other', companyName: 'SSM', employeeId: 'S3'),
  // `companyName` is ours to write and equality is the whole rule, so these two
  // are *not* ours however much they look like it.
  _Row('student-listish', companyName: 'GBS,SSM', employeeId: 'S4'),
  _Row('student-longer', companyName: 'GBSX', employeeId: 'S5'),
  _Row('staff-listed-first', department: 'GBS,SSM', employeeId: 'T1'),
  // The row the drift was about: `startswith` cannot see it, `contains` can.
  _Row('staff-listed-second', department: 'SSM,GBS', employeeId: 'T2'),
  _Row('staff-listed-third', department: 'SSM,ZAV,GBS', employeeId: 'T3'),
  _Row('staff-cased', department: ' ssm,gbs ', employeeId: 'T4'),
  _Row('staff-other', department: 'SSM,ZAV', employeeId: 'T5'),
  _Row('staff-no-employee-id', department: 'SSM,GBS'),
  _Row('staff-blank-employee-id', department: 'SSM,GBS', employeeId: '   '),
  _Row('both-signals', companyName: 'GBS', department: 'SSM,GBS'),
  _Row('no-signal-at-all', employeeId: 'X1'),
];

WisaSnapshot _emptyWisa() => WisaSnapshot(
      fetchedAt: DateTime.utc(2026),
      students: const [],
      staff: const [],
      classGroups: const [],
      schools: const [],
    );

SmartschoolSnapshot _emptySmartschool() => SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026),
      groups: const [],
      accounts: const [],
      memberships: const [],
    );

AzureSnapshot _azureSnapshot(Iterable<_Row> rows) => AzureSnapshot(
      fetchedAt: DateTime.utc(2026),
      users: [for (final row in rows) row.user],
      groups: const [],
    );

/// The Azure object ids `loadClientFiltered` keeps out of [_tenant].
Future<Set<String>> _readClientFiltered(String prefix) async {
  final transport = _FakeGraphTransport(
    (_) => _jsonOk({
      'value': [for (final r in _tenant) r.graphJson]
    }),
  );
  final users = await UserManager(
    GraphClient(transport: transport, auth: const StaticAuthProvider('T')),
  ).loadClientFiltered(prefix);
  return users.map((u) => u.id).toSet();
}

/// The Azure object ids the `/users/delta` walk keeps out of [_tenant].
Future<Set<String>> _readDelta(String prefix) async {
  final transport = _FakeGraphTransport(
    (_) => _jsonOk({
      '@odata.deltaLink':
          'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=T2',
      'value': [for (final r in _tenant) r.graphJson],
    }),
  );
  final delta = await UserManager(
    GraphClient(transport: transport, auth: const StaticAuthProvider('T')),
  ).delta('T1', prefix);
  return delta.changed.map((u) => u.id).toSet();
}

/// The Azure object ids `link()` keeps as orphan records — students and staff
/// both — when nothing in WISA or Smartschool matches any of them.
Set<String> _linkerKept(String prefix) {
  final snapshot = link(
    _emptyWisa(),
    _emptySmartschool(),
    _azureSnapshot(_tenant),
    _SeqResolver(),
    schoolPrefix: prefix,
  );
  return <String>{
    for (final a in snapshot.accounts)
      if (a.azure != null) a.azure!.id,
    for (final s in snapshot.staff)
      if (s.azure != null) s.azure!.id,
  };
}

void main() {
  // 'gbs ' and ' GBS' are the same school: the prefix is typed by an operator
  // in Instellingen, so every caller must fold it the same way too.
  const prefixes = <String>['GBS', 'gbs ', ' GBS', 'SSM', 'ZAV'];

  group('INV-22 is one rule, and every caller applies it (#279)', () {
    for (final prefix in prefixes) {
      test('the linker keeps exactly what the shared rule says — "$prefix"',
          () {
        final kept = _linkerKept(prefix);
        for (final row in _tenant) {
          final expected =
              core.studentBelongsToSchool(row.companyName, prefix) ||
                  core.staffBelongsToSchool(row.department, prefix);
          expect(
            kept.contains(row.id),
            expected,
            reason: '${row.id} under prefix "$prefix"',
          );
        }
      });

      test(
          'loadClientFiltered keeps exactly what the shared rule says — '
          '"$prefix"', () async {
        final kept = await _readClientFiltered(prefix);
        for (final row in _tenant) {
          expect(
            kept.contains(row.id),
            core.belongsToSchool(
              companyName: row.companyName,
              department: row.department,
              schoolPrefix: prefix,
            ),
            reason: '${row.id} under prefix "$prefix"',
          );
        }
      });

      test('the delta walk keeps exactly what the shared rule says — "$prefix"',
          () async {
        final kept = await _readDelta(prefix);
        for (final row in _tenant) {
          expect(
            kept.contains(row.id),
            core.belongsToSchool(
              companyName: row.companyName,
              department: row.department,
              schoolPrefix: prefix,
            ),
            reason: '${row.id} under prefix "$prefix"',
          );
        }
      });

      test(
          'staff retention remembers exactly what the shared rule says — '
          '"$prefix"', () {
        final remembered = retainedStaffEmployeeIds(
          _azureSnapshot(_tenant),
          schoolPrefix: prefix,
        );
        for (final row in _tenant) {
          final id = row.employeeId?.trim() ?? '';
          if (id.isEmpty) continue;
          expect(
            remembered.contains(id),
            core.staffBelongsToSchool(row.department, prefix),
            reason: '${row.id} under prefix "$prefix"',
          );
        }
        // A row with no usable employeeId leaves nothing to ask about, however
        // well its department matches.
        expect(remembered, isNot(contains('')));
        expect(remembered.every((id) => id.trim() == id), isTrue);
      });
    }

    // The direction that fails silently. Asserted separately from the
    // row-by-row equalities above so a regression names *this* property.
    for (final prefix in prefixes) {
      test('no client-side read is ever narrower than the linker — "$prefix"',
          () async {
        final linker = _linkerKept(prefix);
        final clientFiltered = await _readClientFiltered(prefix);
        final delta = await _readDelta(prefix);

        expect(
          linker.difference(clientFiltered),
          isEmpty,
          reason: 'loadClientFiltered threw away rows the linker would have '
              'kept — the linker never gets to ask about them and nothing '
              'reports the loss',
        );
        expect(
          delta.difference(clientFiltered),
          isEmpty,
          reason: 'the two client-side reads disagree with each other',
        );
        expect(
          linker.difference(delta),
          isEmpty,
          reason: 'the delta walk threw away rows the linker would have kept — '
              'the previous snapshot\'s stale row survives and nothing looks '
              'missing',
        );
      });
    }

    test('a staff member listed second is the case all four callers must share',
        () async {
      // The concrete #237 shape, spelled out once so the regression reads as
      // itself and not as a table row: our prefix sits second in the
      // comma-separated list other software maintains.
      const prefix = 'GBS';
      expect(
          await _readClientFiltered(prefix), contains('staff-listed-second'));
      expect(await _readDelta(prefix), contains('staff-listed-second'));
      expect(_linkerKept(prefix), contains('staff-listed-second'));
      expect(
        retainedStaffEmployeeIds(
          _azureSnapshot(_tenant),
          schoolPrefix: prefix,
        ),
        contains('T2'),
      );
    });

    test('an unconfigured prefix claims nobody, in every caller', () async {
      // Every string contains the empty string, so a blank prefix would
      // otherwise hand the whole tenant to a school that has not been set up.
      // The connector's copy of the rule used to do exactly that.
      for (final blank in <String>['', '   ']) {
        expect(await _readClientFiltered(blank), isEmpty, reason: '"$blank"');
        expect(await _readDelta(blank), isEmpty, reason: '"$blank"');
        expect(_linkerKept(blank), isEmpty, reason: '"$blank"');
        expect(
          retainedStaffEmployeeIds(_azureSnapshot(_tenant),
              schoolPrefix: blank),
          isEmpty,
          reason: '"$blank"',
        );
      }
    });
  });
}
