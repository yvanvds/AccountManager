import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/passwords/password_controller.dart';
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:flutter_test/flutter_test.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../reconcile/reconcile_fakes.dart';

/// A Smartschool snapshot shaped like the Passwords screen needs it: a
/// "Leerlingen" root with one class (3C) holding two students, and a
/// "Personeel" group holding one staff member.
ss.SmartschoolSnapshot _snapshot() => ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: <core.Group>[
        core.Group(
          id: const core.GroupId('leerlingen'),
          name: 'Leerlingen',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
        core.Group(
          id: const core.GroupId('3C'),
          name: '3C',
          description: '',
          type: core.GroupType.classGroup,
          official: true,
          origin: core.Origin.smartschool,
          parentId: const core.GroupId('leerlingen'),
        ),
        core.Group(
          id: const core.GroupId('personeel'),
          name: 'Personeel',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
      ],
      accounts: <ss.SmartschoolAccount>[
        ssAccount(uid: 'jane', accountId: '1', mail: 'jane@student.school'),
        ssAccount(uid: 'bob', accountId: '2', mail: 'bob@student.school'),
        ssAccount(uid: 'anna.smit', accountId: '3', mail: 'anna@school'),
      ],
      memberships: <ss.SmartschoolMembership>[
        member('jane', '3C'),
        member('bob', '3C'),
        member('anna.smit', 'personeel'),
      ],
    );

// ---------------------------------------------------------------------------
// #372 fixtures: the same Smartschool tree, plus the linker's view of it.
// ---------------------------------------------------------------------------

/// The Smartschool tree the linked-snapshot scenarios run on: the `_snapshot()`
/// above, extended with
/// - **emely**, a student whose Smartschool `mail` carries the numeric collision
///   suffix her Azure UPN does not (`emely.buvens1@` vs `emely.buvens@`) — one
///   of the 42 live records the O365 push silently skipped;
/// - **piet.nieuw**, a staff account this app has just created through
///   `AddStaffToSmartschool`: present in `accounts`, in **no group at all**, so
///   the Personeel group walk cannot see him.
ss.SmartschoolSnapshot _linkedSnapshotTree() => ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: _snapshot().groups,
      accounts: <ss.SmartschoolAccount>[
        ..._snapshot().accounts,
        ssAccount(
          uid: 'emely',
          accountId: '4',
          mail: 'emely.buvens1@student.school',
          givenName: 'Emely',
          surname: 'Buvens',
        ),
        ssAccount(
          uid: 'piet.nieuw',
          accountId: 'PNIE',
          mail: 'piet.nieuw@school',
          givenName: 'Piet',
          surname: 'Nieuw',
          role: core.PersonRole.teacher,
        ),
      ],
      memberships: <ss.SmartschoolMembership>[
        ..._snapshot().memberships,
        member('emely', '3C'),
        // Deliberately no membership for `piet.nieuw`: the create wrote the
        // account and nothing else.
      ],
    );

core.LinkedAccount _linkedStudent({
  required String id,
  required ss.SmartschoolAccount smartschool,
  az.AzureUser? azure,
}) =>
    core.LinkedAccount(
      id: core.LinkedAccountId(id),
      role: core.PersonRole.student,
      wisa: wisaStudent(wisaId: smartschool.accountId),
      smartschool: smartschool,
      azure: azure,
      confidence:
          azure == null ? core.LinkConfidence.medium : core.LinkConfidence.high,
    );

core.LinkedStaff _linkedStaff({
  required String id,
  ss.SmartschoolAccount? smartschool,
  az.AzureUser? azure,
  wapi.WisaStaff? wisa,
}) =>
    core.LinkedStaff(
      id: core.LinkedAccountId(id),
      role: core.PersonRole.teacher,
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      confidence: core.LinkConfidence.high,
    );

core.LinkedSnapshot _linkedSnapshot({
  List<core.LinkedAccount> accounts = const <core.LinkedAccount>[],
  List<core.LinkedStaff> staff = const <core.LinkedStaff>[],
}) =>
    core.LinkedSnapshot.fromRecords(
      accounts: accounts,
      staff: staff,
      groups: const <core.LinkedGroup>[],
    );

/// A deterministic password generator: `pw1`, `pw2`, ... in call order.
String Function() _seqGenerator() {
  var n = 0;
  return () => 'pw${++n}';
}

/// The PDF magic bytes, so a test can assert the payload really is a document
/// rather than the old HTML string.
bool _isPdf(List<int> bytes) =>
    bytes.length > 5 && latin1.decode(bytes.sublist(0, 5)) == '%PDF-';

void main() {
  group('PasswordController - Leerlingen', () {
    late InMemoryPasswordQueueStore queue;
    late RecordingPasswordBackends backends;
    late List<(String, List<int>)> writes;
    late List<String> opens;
    Object? openError;

    // One stable snapshot per controller: the provider is read live (#287), so
    // handing it a factory that mints a fresh object each call would make every
    // read look like a changed tree.
    PasswordController build({
      String Function()? gen,
      AppSettings Function()? settings,
    }) {
      final snap = _snapshot();
      return PasswordController(
          snapshot: () => snap,
          queue: queue,
          backends: backends,
          settings: settings ?? () => const AppSettings(),
          generatePassword: gen ?? _seqGenerator(),
          writer: (name, bytes) async {
            writes.add((name, List<int>.of(bytes)));
            return 'C:/exports/$name';
          },
          opener: (path) async {
            final error = openError;
            if (error != null) throw error;
            opens.add(path);
          });
    }

    setUp(() {
      queue = InMemoryPasswordQueueStore();
      backends = RecordingPasswordBackends();
      writes = <(String, List<int>)>[];
      opens = <String>[];
      openError = null;
    });

    test('exposes the Leerlingen root and its classes', () {
      final c = build();
      expect(c.studentRoot?.name, 'Leerlingen');
      final classes = c.childrenOf(c.studentRoot!);
      expect(classes.map((g) => g.name), ['3C']);
    });

    test('selecting a class loads its accounts sorted by surname', () {
      final c = build()
        ..selectClass(const core.Group(
            id: core.GroupId('3C'),
            name: '3C',
            description: '',
            type: core.GroupType.classGroup,
            official: true,
            origin: core.Origin.smartschool,
            parentId: core.GroupId('leerlingen')));
      expect(c.rows.map((r) => r.username), ['jane', 'bob']);
    });

    test(
        'generate pushes a fresh password per checked target and queues the '
        'result (#180)', () async {
      final c = build();
      final klas = c.childrenOf(c.studentRoot!).single;
      c.selectClass(klas);
      final jane = c.rows.firstWhere((r) => r.username == 'jane');
      c
        ..toggleRow(jane, PasswordTarget.smartschool, true)
        ..toggleRow(jane, PasswordTarget.office365, true)
        ..toggleRow(jane, PasswordTarget.co2, true);
      expect(c.selectedCount, 3);

      await c.generate();

      // Three live pushes: two Smartschool slots (main + co2) and one Azure.
      expect(backends.smartschoolPushes.length, 2);
      expect(backends.azurePushes.length, 1);
      expect(
        backends.smartschoolPushes.map((p) => p.$2),
        containsAll(<core.AccountType>[
          core.AccountType.student,
          core.AccountType.coAccount2,
        ]),
      );
      // Azure was pushed by mail.
      expect(backends.azurePushes.single.$1, 'jane@student.school');

      // The selection is cleared and the results are queued: one account sheet
      // (SS + Azure) and one co-account entry (slot 2).
      expect(c.selectedCount, 0);
      final entries = await queue.load();
      final account =
          entries.firstWhere((e) => e.kind == PasswordAccountKind.account);
      final co =
          entries.firstWhere((e) => e.kind == PasswordAccountKind.coAccount);
      expect(account.smartschoolPassword, isNotNull);
      expect(account.azurePassword, isNotNull);
      expect(account.classGroup, '3C');
      expect(co.coAccountPasswords.keys, <int>[2]);
    });

    test('bulk toggle selects the target for every row and persists per class',
        () {
      final c = build();
      final klas = c.childrenOf(c.studentRoot!).single;
      c
        ..selectClass(klas)
        ..toggleBulk(PasswordTarget.smartschool, true);
      expect(
          c.rows.every((r) => r.selected.contains(PasswordTarget.smartschool)),
          isTrue);
      expect(c.bulkSelected(PasswordTarget.smartschool), isTrue);
      // Re-selecting the class inherits the bulk state.
      c.selectClass(klas);
      expect(
          c.rows.every((r) => r.selected.contains(PasswordTarget.smartschool)),
          isTrue);
    });

    test('a failed Azure push leaves the field blank and counts as failed',
        () async {
      backends = RecordingPasswordBackends(failAzure: {'jane@student.school'});
      final c = build();
      final klas = c.childrenOf(c.studentRoot!).single;
      c.selectClass(klas);
      final jane = c.rows.firstWhere((r) => r.username == 'jane');
      c
        ..toggleRow(jane, PasswordTarget.smartschool, true)
        ..toggleRow(jane, PasswordTarget.office365, true);

      await c.generate();

      final entries = await queue.load();
      final account =
          entries.firstWhere((e) => e.kind == PasswordAccountKind.account);
      expect(account.smartschoolPassword, isNotNull);
      expect(account.azurePassword, isNull, reason: 'Azure push failed');
      expect(c.message, contains('mislukt'));
    });

    test(
        'a refused Azure write is reported as a rights problem naming the '
        'student, and the rest of the batch still runs (#216)', () async {
      // Graph denies the passwordProfile write. The operator used to read
      // "Genereren mislukt: GraphException(403 (Authorization_RequestDenied))".
      backends = RecordingPasswordBackends(denyAzure: {'jane@student.school'});
      final c = build();
      final klas = c.childrenOf(c.studentRoot!).single;
      c.selectClass(klas);
      final jane = c.rows.firstWhere((r) => r.username == 'jane');
      final bob = c.rows.firstWhere((r) => r.username == 'bob');
      c
        ..toggleRow(jane, PasswordTarget.office365, true)
        ..toggleRow(jane, PasswordTarget.smartschool, true)
        ..toggleRow(bob, PasswordTarget.smartschool, true);

      await c.generate();

      expect(c.message, isNot(contains('GraphException')));
      expect(c.message, contains('Geen rechten'));
      expect(c.message, contains('Jane Doe'));
      expect(c.message, contains('User-PasswordProfile.ReadWrite.All'));
      // The refusal ended one push, not the run: both Smartschool passwords
      // were still pushed and queued.
      expect(backends.smartschoolPushes.map((p) => p.$1), ['jane', 'bob']);
      final entries = await queue.load();
      expect(entries, hasLength(2));
      expect(
        entries.firstWhere((e) => e.accountName == 'jane').azurePassword,
        isNull,
      );
    });

    test('generate is a no-op when nothing is selected', () async {
      final c = build();
      c.selectClass(c.childrenOf(c.studentRoot!).single);
      await c.generate();
      expect(backends.smartschoolPushes, isEmpty);
      expect(backends.azurePushes, isEmpty);
    });

    Future<PasswordController> queuedStudent({
      AppSettings Function()? settings,
    }) async {
      final c = build(settings: settings);
      final klas = c.childrenOf(c.studentRoot!).single;
      c.selectClass(klas);
      final jane = c.rows.firstWhere((r) => r.username == 'jane');
      c.toggleRow(jane, PasswordTarget.smartschool, true);
      await c.generate();
      return c;
    }

    test(
        'exporting student sheets writes a PDF, opens it, and drains them '
        '(#195)', () async {
      final c = await queuedStudent();
      expect(c.studentSheets, isNotEmpty);

      final path = await c.exportStudentSheets();

      expect(writes.single.$1, 'leerling-wachtwoorden.pdf');
      expect(_isPdf(writes.single.$2), isTrue,
          reason: 'a real PDF document, not printable HTML');
      // The written file is handed to the platform viewer, ready to print.
      expect(opens, <String>[path]);
      expect(c.message, contains('geopend'));
      expect(c.message, contains(path));
      // Drained from the queue afterwards.
      expect(c.studentSheets, isEmpty);
    });

    test(
        'the sheet reads the WiFi networks at export time, not at build (#368)',
        () async {
      // The screen outlives a save on the Instellingen tab, so a network
      // captured when Wachtwoorden was first opened is the wrong answer. The
      // provider must be consulted when the PDF is built.
      final live = LiveSettings();
      final read = <WifiNetwork>[];
      final c = await queuedStudent(settings: () {
        read.add(live.current.studentWifi);
        return live.current;
      });
      expect(read, isEmpty, reason: 'nothing is read before an export');

      live.publish(const AppSettings(
        studentWifi: WifiNetwork(ssid: 'Testnet-L', code: 'l-sleutel'),
      ));
      await c.exportStudentSheets();

      expect(
          read.single, const WifiNetwork(ssid: 'Testnet-L', code: 'l-sleutel'));
    });

    test('a viewer that will not launch keeps the file and the drain (#195)',
        () async {
      openError = StateError('geen PDF-viewer geregistreerd');
      final c = await queuedStudent();

      final path = await c.exportStudentSheets();

      // The write happened and the queue is drained: an open failure must not
      // throw the export away or re-queue the drained entries.
      expect(writes.single.$1, 'leerling-wachtwoorden.pdf');
      expect(c.studentSheets, isEmpty);
      expect(opens, isEmpty);
      expect(c.message, contains(path));
      expect(c.message, contains('openen mislukt'));
    });

    test('exporting co-accounts writes a CSV and drains them', () async {
      final c = build();
      final klas = c.childrenOf(c.studentRoot!).single;
      c.selectClass(klas);
      final jane = c.rows.firstWhere((r) => r.username == 'jane');
      c.toggleRow(jane, PasswordTarget.co1, true);
      await c.generate();
      expect(c.coAccountSheets, isNotEmpty);

      await c.exportCoAccounts();
      expect(writes.single.$1, 'co-accounts.csv');
      expect(utf8.decode(writes.single.$2), contains('CoAccount1'));
      // The CSV is not printed, so it is not opened either.
      expect(opens, isEmpty);
      expect(c.coAccountSheets, isEmpty);
    });
  });

  group('PasswordController - Personeel', () {
    late InMemoryPasswordQueueStore queue;
    late RecordingPasswordBackends backends;
    late List<(String, List<int>)> writes;
    late List<String> opens;

    PasswordController build() {
      final snap = _snapshot();
      return PasswordController(
        snapshot: () => snap,
        queue: queue,
        backends: backends,
        generatePassword: _seqGenerator(),
        writer: (name, bytes) async {
          writes.add((name, List<int>.of(bytes)));
          return 'C:/exports/$name';
        },
        opener: (path) async => opens.add(path),
      );
    }

    setUp(() {
      queue = InMemoryPasswordQueueStore();
      backends = RecordingPasswordBackends();
      writes = <(String, List<int>)>[];
      opens = <String>[];
    });

    test('loads the Personeel group members', () {
      final c = build();
      expect(c.staff.map((a) => a.uid), ['anna.smit']);
    });

    test('orders the staff list alphabetically by name (#186)', () {
      // Three staff seeded out of alphabetical order across mixed casing; the
      // controller must expose them sorted by display name (alice, Bob, Charlie).
      final snap = staffOrderSnap();
      final c = PasswordController(
        snapshot: () => snap,
        queue: queue,
        backends: backends,
        generatePassword: _seqGenerator(),
        writer: (name, bytes) async => 'C:/exports/$name',
      );
      // Alphabetical by "Voornaam Naam", case-insensitive: alice, Bob, Charlie.
      expect(c.staff.map((a) => a.uid), ['alice', 'bob', 'charlie']);
    });

    /// The Personeel search over three staff whose names differ in case and in
    /// which half is distinctive: Charlie Zulu, alice Bravo, Bob Alpha.
    PasswordController buildStaffSearch() {
      final snap = staffOrderSnap();
      return PasswordController(
        snapshot: () => snap,
        queue: queue,
        backends: backends,
        generatePassword: _seqGenerator(),
        writer: (name, bytes) async => 'C:/exports/$name',
      );
    }

    test('searches any part of the full name, case-insensitively (#215)', () {
      final c = buildStaffSearch()..setStaffFilterText('ZUL');
      expect(c.staff.map((a) => a.uid), ['charlie']);
      // The given name matches just as well as the surname — no field to pick.
      c.setStaffFilterText('Bob');
      expect(c.staff.map((a) => a.uid), ['bob']);
      // …and a fragment from the middle of a name matches too (*namepart*).
      c.setStaffFilterText('rav');
      expect(c.staff.map((a) => a.uid), ['alice']);
      c.setStaffFilterText('zzz');
      expect(c.staff, isEmpty);
    });

    test('a multi-word needle matches in either name order (#215)', () {
      final c = buildStaffSearch()..setStaffFilterText('alice bravo');
      expect(c.staff.map((a) => a.uid), ['alice']);
      // Reversed — the operator never has to guess which way round the name is
      // stored.
      c.setStaffFilterText('bravo alice');
      expect(c.staff.map((a) => a.uid), ['alice']);
      // Every part must match: one part from each of two people finds neither.
      c.setStaffFilterText('alice zulu');
      expect(c.staff, isEmpty);
    });

    test('a whitespace-only needle shows every staff member (#215)', () {
      final c = buildStaffSearch()..setStaffFilterText('zzz');
      expect(c.staff, isEmpty);
      c.setStaffFilterText('   ');
      expect(c.staff, hasLength(3));
      c.setStaffFilterText('');
      expect(c.staff, hasLength(3));
    });

    test('searches the name, not the username (#215)', () {
      // This staff account is named "Jane Doe" under the username anna.smit:
      // with the Gebruiker option gone the name is what the box matches.
      final c = build()..setStaffFilterText('anna.smit');
      expect(c.staff, isEmpty);
      c.setStaffFilterText('doe jane');
      expect(c.staff.map((a) => a.uid), ['anna.smit']);
    });

    test('reset both mints one shared password, pushes both, exports a sheet',
        () async {
      final c = build();
      c.selectStaff(c.staff.single);
      final path = await c.resetStaff(smartschool: true, office365: true);

      expect(path, isNotNull);
      expect(backends.smartschoolPushes, hasLength(1));
      expect(backends.azurePushes, hasLength(1));
      // Both legs share the same password (legacy NewPasswords).
      expect(
          backends.smartschoolPushes.single.$3, backends.azurePushes.single.$2);
      // A per-staff PDF sheet was written and opened for printing (#195), not
      // queued.
      expect(writes.single.$1, 'anna.smit.pdf');
      expect(_isPdf(writes.single.$2), isTrue);
      expect(opens, <String>[path!]);
      expect(await queue.load(), isEmpty);
    });

    test('reset Smartschool only pushes Smartschool', () async {
      final c = build();
      c.selectStaff(c.staff.single);
      await c.resetStaff(smartschool: true, office365: false);
      expect(backends.smartschoolPushes, hasLength(1));
      expect(backends.azurePushes, isEmpty);
    });

    test(
        'a refused Office 365 reset names the staff member and the cause, not '
        'a raw GraphException (#216)', () async {
      backends = RecordingPasswordBackends(denyAzure: {'anna@school'});
      final c = build();
      c.selectStaff(c.staff.single);

      final path = await c.resetStaff(smartschool: false, office365: true);

      expect(path, isNull, reason: 'nothing was set, so no sheet is written');
      expect(c.message, isNot(contains('GraphException')));
      expect(c.message, contains('Geen rechten'));
      expect(c.message, contains('Jane Doe'));
      expect(c.message, contains('User-PasswordProfile.ReadWrite.All'));
      expect(writes, isEmpty);
    });

    test('a half-refused reset still hands over the sheet and says why (#216)',
        () async {
      backends = RecordingPasswordBackends(denyAzure: {'anna@school'});
      final c = build();
      c.selectStaff(c.staff.single);

      final path = await c.resetStaff(smartschool: true, office365: true);

      expect(path, isNotNull);
      expect(backends.smartschoolPushes, hasLength(1));
      expect(c.message, contains('Geen rechten'));
      expect(c.message, contains('sheet'));
      expect(c.message, isNot(contains('GraphException')));
    });

    test('reset with no target selected is a no-op', () async {
      final c = build();
      c.selectStaff(c.staff.single);
      final path = await c.resetStaff(smartschool: false, office365: false);
      expect(path, isNull);
      expect(backends.smartschoolPushes, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // #372: the screen reads the linked snapshot, not the Smartschool group tree.
  // -------------------------------------------------------------------------

  group('PasswordController - linked snapshot (#372)', () {
    late InMemoryPasswordQueueStore queue;
    late RecordingPasswordBackends backends;

    setUp(() {
      queue = InMemoryPasswordQueueStore();
      backends = RecordingPasswordBackends();
    });

    PasswordController build({core.LinkedSnapshot? linked}) {
      final snap = _linkedSnapshotTree();
      return PasswordController(
        snapshot: () => snap,
        linked: () => linked,
        queue: queue,
        backends: backends,
        generatePassword: _seqGenerator(),
        writer: (name, bytes) async => 'C:/exports/$name',
        opener: (path) async {},
      );
    }

    /// Emely as the live tenant holds her: Smartschool carries the collision
    /// suffix her Azure UPN does not, so `GET /users/<smartschool mail>` answers
    /// `Request_ResourceNotFound`. The linker attached the account all the same,
    /// through `employeeId ≡ wisaId`.
    ss.SmartschoolAccount emelySs() =>
        _linkedSnapshotTree().accounts.firstWhere((a) => a.uid == 'emely');

    az.AzureUser emelyAzure() => azUser(
          id: 'az-emely',
          upn: 'emely.buvens@student.school',
          employeeId: '4',
        );

    void tickO365(PasswordController c, String uid) {
      c.selectClass(c.childrenOf(c.studentRoot!).single);
      final row = c.rows.firstWhere((r) => r.username == uid);
      c.toggleRow(row, PasswordTarget.office365, true);
    }

    test(
        'a student whose Smartschool mail is not her UPN still gets an Office '
        '365 password, pushed to the linked account', () async {
      // The regression: the mail lookup fails the way Graph fails it.
      backends = RecordingPasswordBackends(
          failAzure: {'emely.buvens1@student.school'});
      final c = build(
        linked: _linkedSnapshot(accounts: <core.LinkedAccount>[
          _linkedStudent(
              id: 'p-emely', smartschool: emelySs(), azure: emelyAzure()),
        ]),
      );
      tickO365(c, 'emely');

      await c.generate();

      // Pushed by Graph object id, never by the Smartschool address.
      expect(backends.azureIdPushes, <String>['az-emely']);
      expect(backends.azurePushes.single.$1, 'az-emely');
      final entries = await queue.load();
      expect(
        entries.firstWhere((e) => e.accountName == 'emely').azurePassword,
        isNotNull,
      );
      expect(c.message, contains('gegenereerd'));
      expect(c.rows.firstWhere((r) => r.username == 'emely').problem, isNull);
    });

    test('a student the linker holds with no Azure account says so on the row',
        () async {
      final c = build(
        linked: _linkedSnapshot(accounts: <core.LinkedAccount>[
          _linkedStudent(id: 'p-emely', smartschool: emelySs()),
        ]),
      );
      tickO365(c, 'emely');
      // The fact is known before anything is pushed.
      expect(c.rows.firstWhere((r) => r.username == 'emely').hasNoAzureAccount,
          isTrue);

      await c.generate();

      // Nothing was pushed anywhere, and the row — not just the log — says why.
      expect(backends.azurePushes, isEmpty);
      expect(backends.azureIdPushes, isEmpty);
      expect(
        c.rows.firstWhere((r) => r.username == 'emely').problem,
        PasswordController.noAzureAccountNote,
      );
      expect(c.message, contains('mislukt'));
    });

    test('a row that succeeds on a later run stops claiming a problem',
        () async {
      final c = build(
        linked: _linkedSnapshot(accounts: <core.LinkedAccount>[
          _linkedStudent(id: 'p-emely', smartschool: emelySs()),
        ]),
      );
      tickO365(c, 'emely');
      await c.generate();
      expect(
          c.rows.firstWhere((r) => r.username == 'emely').problem, isNotNull);

      // A second run on a target that works clears the stale verdict.
      final row = c.rows.firstWhere((r) => r.username == 'emely');
      c.toggleRow(row, PasswordTarget.smartschool, true);
      await c.generate();
      expect(row.problem, isNull);
    });

    test(
        'without a linked snapshot the Office 365 push still resolves by mail '
        '— a session that has not linked keeps working', () async {
      final c = build();
      tickO365(c, 'emely');

      await c.generate();

      expect(backends.azureIdPushes, isEmpty);
      expect(backends.azurePushes.single.$1, 'emely.buvens1@student.school');
    });

    test(
        'a staff account in no Smartschool group is on the Personeel tab '
        'because the linker holds it', () async {
      final piet = _linkedSnapshotTree()
          .accounts
          .firstWhere((a) => a.uid == 'piet.nieuw');
      final c = build(
        linked: _linkedSnapshot(staff: <core.LinkedStaff>[
          _linkedStaff(
            id: 'p-piet',
            smartschool: piet,
            azure: azStaffUser(id: 'az-piet', upn: 'piet.nieuw@school'),
            wisa: wisaStaff(code: 'PNIE', wisaId: '77'),
          ),
        ]),
      );

      // Visible with no re-sync, and the group-walk member is still there: the
      // roster is a union, so nobody who was reachable before stops being.
      expect(c.staff.map((r) => r.uid), containsAll(<String>['piet.nieuw']));
      expect(c.staff.map((r) => r.uid), contains('anna.smit'));

      c.selectStaff(c.staff.firstWhere((r) => r.uid == 'piet.nieuw'));
      final path = await c.resetStaff(smartschool: true, office365: true);

      expect(path, 'C:/exports/piet.nieuw.pdf');
      expect(backends.smartschoolPushes.single.$1, 'piet.nieuw');
      // …and the Office 365 half went to the linked account's object id.
      expect(backends.azureIdPushes, <String>['az-piet']);
    });

    test('a staff member the linker holds with no Azure account says so',
        () async {
      final piet = _linkedSnapshotTree()
          .accounts
          .firstWhere((a) => a.uid == 'piet.nieuw');
      final c = build(
        linked: _linkedSnapshot(staff: <core.LinkedStaff>[
          _linkedStaff(id: 'p-piet', smartschool: piet),
        ]),
      );
      final row = c.staff.firstWhere((r) => r.uid == 'piet.nieuw');
      expect(row.hasNoAzureAccount, isTrue);
      c.selectStaff(row);

      final path = await c.resetStaff(smartschool: false, office365: true);

      expect(path, isNull);
      expect(backends.azurePushes, isEmpty);
      expect(row.problem, PasswordController.noAzureAccountNote);
      expect(c.message, PasswordController.noAzureAccountNote);
    });

    test(
        'a linked staff member with no Smartschool account is listed and can '
        'still reset Office 365', () async {
      final c = build(
        linked: _linkedSnapshot(staff: <core.LinkedStaff>[
          _linkedStaff(
            id: 'p-lore',
            azure: azStaffUser(id: 'az-lore', upn: 'lore.vos@school'),
            wisa: wisaStaff(
                code: 'LVOS', wisaId: '88', firstName: 'Lore', lastName: 'Vos'),
          ),
        ]),
      );
      final row = c.staff.firstWhere((r) => r.name == 'Lore Vos');
      expect(row.hasSmartschoolAccount, isFalse);
      c.selectStaff(row);

      // The Smartschool half has no username to push to and says so…
      await c.resetStaff(smartschool: true, office365: false);
      expect(backends.smartschoolPushes, isEmpty);
      expect(row.problem, PasswordController.noSmartschoolAccountNote);

      // …while the Office 365 half lands, and the sheet is named after them.
      final path = await c.resetStaff(smartschool: false, office365: true);
      expect(backends.azureIdPushes, <String>['az-lore']);
      expect(path, 'C:/exports/Lore-Vos.pdf');
    });

    test('a WISA-only staff member has nothing to reset and is not listed', () {
      final c = build(
        linked: _linkedSnapshot(staff: <core.LinkedStaff>[
          _linkedStaff(
              id: 'p-ghost',
              wisa: wisaStaff(
                  code: 'GHST',
                  wisaId: '99',
                  firstName: 'Geert',
                  lastName: 'Geest')),
        ]),
      );
      expect(c.staff.map((r) => r.name), isNot(contains('Geert Geest')));
    });

    test('a linked snapshot that arrives after the screen opened is adopted',
        () async {
      final snap = _linkedSnapshotTree();
      core.LinkedSnapshot? live;
      final c = PasswordController(
        snapshot: () => snap,
        linked: () => live,
        queue: queue,
        backends: backends,
        generatePassword: _seqGenerator(),
        writer: (name, bytes) async => 'C:/exports/$name',
      );
      // Before the session links: only the group walk, and no linked account.
      expect(c.staff.map((r) => r.uid), <String>['anna.smit']);
      c.selectClass(c.childrenOf(c.studentRoot!).single);
      expect(c.rows.every((r) => r.linked == null), isTrue);

      live = _linkedSnapshot(
        accounts: <core.LinkedAccount>[
          _linkedStudent(
              id: 'p-emely', smartschool: emelySs(), azure: emelyAzure()),
        ],
        staff: <core.LinkedStaff>[
          _linkedStaff(
            id: 'p-piet',
            smartschool: _linkedSnapshotTree()
                .accounts
                .firstWhere((a) => a.uid == 'piet.nieuw'),
            azure: azStaffUser(id: 'az-piet', upn: 'piet.nieuw@school'),
          ),
        ],
      );
      c.refresh();

      expect(c.staff.map((r) => r.uid), containsAll(<String>['piet.nieuw']));
      expect(
        c.rows.firstWhere((r) => r.username == 'emely').azureObjectId,
        'az-emely',
      );
      // …and the open class kept its place across the rebuild.
      expect(c.selectedClass?.name, '3C');
    });
  });
}
