/// Read-only diagnostic: pull WISA + Smartschool + Azure live, run the real
/// [link] pass over the three snapshots, and report everything the three
/// systems and the linker hold about one person.
///
/// Answers "why is this Azure account not picked up?" — it shows whether the
/// row survived each connector's read, which record (if any) the linker
/// attached it to, and which bridge did the attaching.
///
/// Read-only: three `sync()` calls and nothing else. Never writes.
///
///     ./tool/live-tests.ps1 -Only azure   # (to mint AZURE_ACCESS_TOKEN)
///     dart run packages/account_linker/tool/trace_person.dart 32966 buvens
library;

import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:account_linker/account_linker.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: trace_person.dart <needle> [<needle> ...]');
    return 2;
  }
  final needles = args.map((s) => s.toLowerCase()).toList();
  bool hit(Object? value) {
    final s = value?.toString().toLowerCase() ?? '';
    return s.isNotEmpty && needles.any(s.contains);
  }

  final wisaConfig = wapi.WisaLiveConfig.fromEnvironment();
  final ssConfig = ss.SmartschoolLiveConfig.fromEnvironment();
  final azConfig = az.AzureLiveConfig.fromEnvironment();
  if (wisaConfig == null || ssConfig == null || azConfig == null) {
    stderr.writeln('Missing credentials. Load .wisa.env, .smartschool.env and '
        '.azure.env (and mint AZURE_ACCESS_TOKEN) first.');
    return 2;
  }

  // ---- WISA -------------------------------------------------------------
  final wisa = wisaConfig.connector();
  final schools = await wisa.loadSchools();
  final workDate = wisaConfig.resolveWorkDate(DateTime.now());
  stdout.writeln('Werkdatum: ${wapi.formatWerkdatum(workDate)}');
  stdout.writeln(
      'Schools: ${[for (final s in schools) '${s.id}=${s.code}'].join(', ')}');
  final wisaSnapshot = await wisa.sync(schools: schools, workDate: workDate);
  stdout.writeln('WISA: ${wisaSnapshot.students.length} students, '
      '${wisaSnapshot.staff.length} staff, '
      '${wisaSnapshot.classGroups.length} class groups');

  // ---- Smartschool ------------------------------------------------------
  final ssConnector = ssConfig.connector();
  final ssSnapshot = await ssConnector.sync();
  stdout.writeln('Smartschool: ${ssSnapshot.accounts.length} accounts, '
      '${ssSnapshot.groups.length} groups');

  // ---- Azure ------------------------------------------------------------
  final azConnector = az.AzureConnector(
    credentials: az.AzureCredentials(
      clientId: azConfig.clientId,
      tenantId: azConfig.tenantId,
      azureDomain: azConfig.azureDomain,
      schoolPrefix: azConfig.schoolPrefix,
    ),
    authProvider: az.StaticAuthProvider(azConfig.accessToken),
  );
  final azSnapshot = await azConnector.sync(
    expectedEmployeeIds: [
      for (final s in wisaSnapshot.students) s.wisaId.value,
      for (final s in wisaSnapshot.staff) s.wisaId?.value ?? '',
    ],
  );
  stdout.writeln('Azure: ${azSnapshot.users.length} users, '
      '${azSnapshot.groups.length} groups '
      '(prefix "${azConfig.schoolPrefix}")');
  azConnector.close();

  // ---- What each system holds ------------------------------------------
  stdout.writeln('\n${'=' * 72}\nWISA rows');
  for (final s in wisaSnapshot.students) {
    if (!hit(s.wisaId.value) && !hit('${s.firstName} ${s.name}')) continue;
    stdout.writeln('  wisaId=${s.wisaId.value} school=${s.schoolId} '
        'klas=${s.classGroup}/${s.classSubGroup} '
        'naam=${s.firstName} ${s.name}');
  }

  stdout.writeln('\nSmartschool accounts');
  for (final a in ssSnapshot.accounts) {
    if (!hit(a.accountId) &&
        !hit(a.mail) &&
        !hit('${a.givenName} ${a.surname}')) {
      continue;
    }
    stdout.writeln('  accountId=${a.accountId} uid=${a.uid} '
        'type=${a.accountType} role=${a.role} status=${a.status} '
        'mail=${a.mail} naam=${a.givenName} ${a.surname}');
  }

  stdout.writeln('\nAzure users in snapshot');
  for (final u in azSnapshot.users) {
    if (!hit(u.employeeId) && !hit(u.upn) && !hit(u.displayName)) continue;
    stdout.writeln('  id=${u.id} upn=${u.upn} employeeId=${u.employeeId} '
        'company=${u.companyName} dept=${u.department} '
        'job=${u.jobTitle} enabled=${u.accountEnabled}');
  }

  stdout.writeln('\nAzure groups naming a class the needle sits in');
  final needleIds = <String>{
    for (final u in azSnapshot.users)
      if (hit(u.employeeId) || hit(u.upn)) u.id,
  };
  for (final g in azSnapshot.groups) {
    final names = '${g.displayName} ${g.mailNickname ?? ''}'.toLowerCase();
    final member = g.memberIds.any(needleIds.contains);
    if (!member && !names.contains('1b2')) continue;
    stdout.writeln('  ${g.displayName} (nick=${g.mailNickname} '
        'unified=${g.isUnified} members=${g.memberIds.length}) '
        'needleIsMember=$member');
  }

  // ---- The link pass ----------------------------------------------------
  final resolver = _SeqResolver();
  final linked = link(
    wisaSnapshot,
    ssSnapshot,
    azSnapshot,
    resolver,
    schoolPrefix: azConfig.schoolPrefix,
  );
  stdout.writeln('\n${'=' * 72}\nLinked records');
  for (final r in linked.accounts) {
    final match = hit(r.wisa?.wisaId.value) ||
        hit(r.smartschool?.accountId) ||
        hit(r.smartschool?.mail) ||
        hit(r.azure?.employeeId) ||
        hit(r.azure?.upn);
    if (!match) continue;
    stdout.writeln('  [student] id=${r.id.value} confidence=${r.confidence} '
        'presence=${r.wisaPresence}');
    stdout
        .writeln('      wisa=${r.wisa == null ? '-' : '${r.wisa!.wisaId.value} '
            'klassen=${r.wisaClassGroups}'}');
    stdout.writeln(
        '      smartschool=${r.smartschool == null ? '-' : '${r.smartschool!.accountId} ${r.smartschool!.mail}'}');
    stdout.writeln(
        '      azure=${r.azure == null ? '-' : '${r.azure!.upn} emp=${r.azure!.employeeId}'}');
    if (r.azureDuplicates.isNotEmpty) {
      stdout.writeln('      azureDuplicates='
          '${[for (final d in r.azureDuplicates) d.upn].join(', ')}');
    }
  }
  for (final r in linked.staff) {
    final match = hit(r.wisa?.wisaId?.value) ||
        hit(r.smartschool?.accountId) ||
        hit(r.azure?.employeeId) ||
        hit(r.azure?.upn);
    if (!match) continue;
    stdout.writeln('  [staff] id=${r.id.value} confidence=${r.confidence} '
        'azure=${r.azure?.upn ?? '-'}');
  }

  // The Passwords screen looks the Azure account up by the *Smartschool* mail
  // (`getUser(row.account.mail)`), so any record whose mail is not the UPN
  // silently gets no Office 365 password.
  stdout.writeln('\n${'=' * 72}\nSmartschool mail != Azure UPN (O365 password '
      'would fail)');
  var mismatched = 0;
  for (final r in linked.accounts) {
    final ssMail = r.smartschool?.mail.trim().toLowerCase() ?? '';
    final upn = r.azure?.upn.trim().toLowerCase() ?? '';
    if (r.smartschool == null || r.azure == null) continue;
    if (ssMail.isEmpty || ssMail == upn) continue;
    mismatched++;
    final klas = r.wisaClassGroups.values.join('/');
    stdout.writeln('  klas=${klas.isEmpty ? '-' : klas}  '
        'uid=${r.smartschool!.uid}  ss=$ssMail  upn=$upn');
  }
  stdout.writeln('  total: $mismatched of ${linked.accounts.length} records');

  stdout.writeln('\nWarnings mentioning the needle');
  for (final w in linked.warnings) {
    if (!hit(w.toString())) continue;
    stdout.writeln('  $w');
  }

  return 0;
}

class _SeqResolver implements core.PersonIdResolver {
  final _ids = <String, core.PersonId>{};
  var _next = 0;
  @override
  core.PersonId resolve(String naturalKey) =>
      _ids.putIfAbsent(naturalKey, () => core.PersonId('p${_next++}'));
}
