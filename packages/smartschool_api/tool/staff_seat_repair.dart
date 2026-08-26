/// Counts — and, on request, repairs — the staff accounts the port left seated
/// in the Smartschool default group before #374 (#378).
///
/// Background. `saveUser` seats every account it creates in the platform
/// default group (`Leerlingen`), whatever role it carries. Legacy compensated
/// inside the staff create with two follow-up writes; the port dropped them, so
/// every staff account it made before #374 sits in the student subtree and in
/// no staff group at all. #374 fixed the create going forward. This is the
/// backlog.
///
/// **Read-only by default** — `sync` only, no write — so the count, which #378
/// asks for first, costs nothing. `--apply` is the opt-in that writes: it
/// issues exactly the pair `AddStaffToSmartschool` now issues, per account.
/// Because it writes, it is manual: the project's live-testing policy keeps
/// write-capable runs out of CI.
///
/// Run from anywhere in the repo after sourcing `.smartschool.env`:
///
///     dart run packages/smartschool_api/tool/staff_seat_repair.dart
///     dart run packages/smartschool_api/tool/staff_seat_repair.dart --refresh
///     dart run packages/smartschool_api/tool/staff_seat_repair.dart --apply
///
/// Flags: `--refresh` re-pulls the sync instead of reusing the cached snapshot;
/// `--apply` performs the two writes; `--only a,b` limits the run to named uids
/// (use it after eyeballing the audit — an account that also sits in
/// `Stagiairs` or `Beheerders` was put there by an operator, not by our
/// create); `--staff-group`, `--default-group` and `--staff-root` override the
/// group names for a tenant whose tree spells them differently.
///
/// Exit code: `0` when there was nothing to repair or everything applied, `1`
/// when a write missed, `2` when the credentials are absent.
///
/// The pull is deliberately **unscoped** — the whole forest, not
/// `AppSettings.smartschoolRoots` — because the audit's "is this account seated
/// somewhere staff-side?" test has to see the staff root, and a scoped pull is
/// exactly the thing that could hide it.
///
/// Output goes to `packages/smartschool_api/captures/staff-seat/`
/// (gitignored — it holds real staff data straight from Smartschool).
library;

import 'dart:convert';
import 'dart:io';

import 'package:smartschool_api/smartschool_api.dart';

Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  final refresh = args.contains('--refresh');
  final apply = args.contains('--apply');
  final only = _csvFlag(args, '--only');
  final staffGroupName =
      _stringFlag(args, '--staff-group') ?? smartschoolStaffGroupName;
  final defaultGroupName =
      _stringFlag(args, '--default-group') ?? smartschoolDefaultGroupName;
  final staffRootName =
      _stringFlag(args, '--staff-root') ?? smartschoolStaffRootName;

  final config = SmartschoolLiveConfig.fromEnvironment();
  if (config == null) {
    stderr.writeln(
      'SMARTSCHOOL_ACCESSCODE is not set. Source .smartschool.env first '
      '(see .smartschool.env.example).',
    );
    return 2;
  }

  final outDir = Directory(
    '${_findRepoRoot().path}/packages/smartschool_api/captures/staff-seat',
  )..createSync(recursive: true);
  stdout.writeln('Output: ${outDir.path}');

  // One transport, one connector, for the whole run (the connector is
  // documented as one-per-tenant-per-run) — and closed at the end, so a tool
  // that only read the cache does not sit on an open socket.
  final transport = HttpSmartschoolSoapTransport();
  final connector = SmartschoolConnector.fromParts(
    site: config.site,
    accessCode: config.accessCode,
    transport: transport,
  );
  try {
    return await _audit(
      connector,
      outDir,
      refresh: refresh,
      apply: apply,
      only: only,
      staffGroupName: staffGroupName,
      defaultGroupName: defaultGroupName,
      staffRootName: staffRootName,
    );
  } finally {
    transport.close();
  }
}

Future<int> _audit(
  SmartschoolConnector connector,
  Directory outDir, {
  required bool refresh,
  required bool apply,
  required List<String> only,
  required String staffGroupName,
  required String defaultGroupName,
  required String staffRootName,
}) async {
  final snapshot = await _loadSnapshot(connector, outDir, refresh: refresh);
  stdout.writeln(
    'Snapshot: ${snapshot.groups.length} groups, '
    '${snapshot.accounts.length} accounts, '
    '${snapshot.memberships.length} memberships '
    '(pulled ${snapshot.fetchedAt.toIso8601String()}).',
  );

  var found = misSeatedStaffAccounts(
    snapshot,
    defaultGroupName: defaultGroupName,
    staffRootName: staffRootName,
  );
  if (only.isNotEmpty) {
    final wanted = {for (final uid in only) uid.toLowerCase()};
    found = [
      for (final row in found)
        if (wanted.contains(row.account.uid.toLowerCase())) row,
    ];
  }

  final report = StringBuffer()
    ..writeln('Staff accounts seated in "$defaultGroupName" and in no group '
        'under "$staffRootName": ${found.length}')
    ..writeln();
  for (final row in found) {
    final account = row.account;
    final others = row.otherGroups.isEmpty
        ? '(none)'
        : row.otherGroups.map((g) => g.name).join(', ');
    report.writeln(
      '  ${account.uid.padRight(24)} '
      '${'${account.surname} ${account.givenName}'.padRight(32)} '
      'role=${account.role?.name ?? '?'} '
      'accountId=${account.accountId.isEmpty ? '-' : account.accountId} '
      'other groups: $others',
    );
  }
  stdout
    ..writeln()
    ..write(report.toString());

  if (found.isEmpty) {
    stdout.writeln('Nothing to repair.');
    _write(outDir, report);
    return 0;
  }

  if (!apply) {
    stdout.writeln(
      '\nRead-only run. Re-run with --apply to add these accounts to '
      '"$staffGroupName" and remove them from "$defaultGroupName".',
    );
    _write(outDir, report);
    return 0;
  }

  final staffGroup = resolveStaffGroup(snapshot, name: staffGroupName);
  if (staffGroup == null) {
    stderr.writeln(
      'No group named "$staffGroupName" in the tree — these accounts could be '
      'taken out of "$defaultGroupName" but not put anywhere. Aborting; pass '
      '--staff-group to name the right one.',
    );
    _write(outDir, report);
    return 1;
  }

  stdout.writeln(
    '\nApplying to ${found.length} account(s): + $staffGroupName '
    '(${staffGroup.id.value}), - $defaultGroupName …',
  );
  final results = await repairStaffSeating(
    connector,
    found,
    staffGroup: staffGroup,
    staffGroupName: staffGroupName,
    defaultGroupName: defaultGroupName,
  );

  var repaired = 0;
  report
    ..writeln()
    ..writeln('--- apply ---');
  for (final result in results) {
    if (result.repaired) repaired++;
    final buffer = StringBuffer(
      '  ${result.uid.padRight(24)} '
      'joined=${result.joined} left=${result.left}',
    );
    for (final problem in result.problems) {
      buffer.write('\n      $problem');
    }
    report.writeln(buffer);
    stdout.writeln(buffer);
  }
  final summary = 'Repaired ${results.length} account(s): '
      '$repaired fully, ${results.length - repaired} with problems.';
  report.writeln(summary);
  stdout.writeln(summary);

  // The cached snapshot no longer matches the tenant we just wrote to, and a
  // stale reuse would re-propose the accounts already repaired. Drop it so the
  // next run re-pulls.
  final cached = File('${outDir.path}/snapshot.json');
  if (cached.existsSync()) cached.deleteSync();

  _write(outDir, report);
  return repaired == results.length ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Snapshot cache
// ---------------------------------------------------------------------------

Future<SmartschoolSnapshot> _loadSnapshot(
  SmartschoolConnector connector,
  Directory outDir, {
  required bool refresh,
}) async {
  final file = File('${outDir.path}/snapshot.json');
  if (!refresh && file.existsSync()) {
    stdout.writeln('Reusing cached snapshot (--refresh to re-pull).');
    return SmartschoolSnapshot.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  }
  stdout.writeln('Running a full Smartschool sync (minutes on a real tenant)…');
  final snapshot = await connector.sync();
  file.writeAsStringSync(jsonEncode(snapshot.toJson()));
  return snapshot;
}

void _write(Directory outDir, StringBuffer report) {
  final file = File('${outDir.path}/report.txt')
    ..writeAsStringSync(report.toString());
  stdout.writeln('Report: ${file.path}');
}

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

String? _stringFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

List<String> _csvFlag(List<String> args, String name) {
  final raw = _stringFlag(args, name);
  if (raw == null) return const [];
  return [
    for (final part in raw.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

Directory _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/packages').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate the repository root.');
    }
    dir = parent;
  }
}
