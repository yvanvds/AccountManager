import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:flutter/foundation.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;

import 'password_backends.dart';
import 'password_export.dart';

/// The eight per-account password targets a student row can regenerate: the two
/// backends plus the six Smartschool co-account slots.
enum PasswordTarget {
  smartschool,
  office365,
  co1,
  co2,
  co3,
  co4,
  co5,
  co6;

  /// The 1-based co-account slot (1..6), or `null` for the two backends.
  int? get coSlot => switch (this) {
        co1 => 1,
        co2 => 2,
        co3 => 3,
        co4 => 4,
        co5 => 5,
        co6 => 6,
        _ => null,
      };

  /// Short badge label used in the selection grid.
  String get label => switch (this) {
        PasswordTarget.smartschool => 'SS',
        PasswordTarget.office365 => 'O365',
        _ => '${coSlot!}',
      };
}

/// The fields a staff list can be filtered on (#180, legacy `FilterTypes`).
enum StaffFilterField { naam, voornaam, gebruikersnaam }

/// One student in the currently-selected class, with its per-target selection.
class StudentRow {
  StudentRow(this.account);

  final ss.SmartschoolAccount account;
  final Set<PasswordTarget> selected = <PasswordTarget>{};

  String get username => account.uid;
  String get name => '${account.givenName} ${account.surname}'.trim();
}

/// Drives the reworked Passwords screen (#180): on-demand password generation
/// for students (per-class, per-target, bulk) and staff (per-member resets),
/// reading the current Smartschool group tree from the last sync and pushing
/// fresh passwords live through [PasswordBackends].
///
/// The key correction over the old distribution-only queue: passwords are
/// generated **on demand from this screen**, not as a side effect of account
/// creation. Generated student/co-account passwords are recorded in the shared
/// [PasswordQueueStore] for printing/CSV; staff resets export a per-staff sheet
/// immediately (they are never queued), mirroring the legacy app.
class PasswordController extends ChangeNotifier {
  PasswordController({
    required ss.SmartschoolSnapshot? snapshot,
    required PasswordQueueStore queue,
    required PasswordBackends backends,
    PasswordFileWriter writer = writePasswordExport,
    PasswordFileOpener opener = openPasswordExport,
    String Function() generatePassword = core.Password.create,
    String studentGroupName = 'Leerlingen',
    String staffGroupName = 'Personeel',
    core.ILog? log,
  })  : _snapshot = snapshot,
        _queue = queue,
        _backends = backends,
        _writer = writer,
        _opener = opener,
        _generate = generatePassword,
        _log = log {
    _indexTree();
    studentRoot = _findGroupByName(studentGroupName);
    _staffRoot = _findGroupByName(staffGroupName);
    _loadStaff();
  }

  final ss.SmartschoolSnapshot? _snapshot;
  final PasswordQueueStore _queue;
  final PasswordBackends _backends;
  final PasswordFileWriter _writer;
  final PasswordFileOpener _opener;
  final String Function() _generate;
  final core.ILog? _log;

  // --- Group-tree index (built once from the snapshot) -----------------------

  final Map<String, List<core.Group>> _childrenByParent =
      <String, List<core.Group>>{};
  final Map<String, ss.SmartschoolAccount> _accountByUid =
      <String, ss.SmartschoolAccount>{};
  final Map<String, List<String>> _uidsByGroup = <String, List<String>>{};

  /// The "Leerlingen" root of the student class tree, or `null` when the last
  /// sync carried no such group (or there was no sync this session).
  core.Group? studentRoot;
  core.Group? _staffRoot;

  void _indexTree() {
    final snap = _snapshot;
    if (snap == null) return;
    for (final account in snap.accounts) {
      _accountByUid[account.uid] = account;
    }
    for (final group in snap.groups) {
      final parent = group.parentId?.value;
      if (parent != null) {
        _childrenByParent.putIfAbsent(parent, () => <core.Group>[]).add(group);
      }
    }
    for (final m in snap.memberships) {
      _uidsByGroup.putIfAbsent(m.groupId.value, () => <String>[]).add(m.uid);
    }
  }

  core.Group? _findGroupByName(String name) {
    for (final group in _snapshot?.groups ?? const <core.Group>[]) {
      if (group.name == name) return group;
    }
    return null;
  }

  /// The direct child groups of [group] in the class tree, sorted by name.
  List<core.Group> childrenOf(core.Group group) {
    final children = List<core.Group>.of(
      _childrenByParent[group.id.value] ?? const <core.Group>[],
    )..sort((a, b) => a.name.compareTo(b.name));
    return children;
  }

  /// The direct member accounts of [group] (not recursive), sorted by surname —
  /// the accounts shown when a class is selected.
  List<ss.SmartschoolAccount> _directAccounts(core.Group group) {
    final uids = _uidsByGroup[group.id.value] ?? const <String>[];
    final accounts = <ss.SmartschoolAccount>[
      for (final uid in uids)
        if (_accountByUid[uid] != null) _accountByUid[uid]!,
    ]..sort((a, b) => a.surname.compareTo(b.surname));
    return accounts;
  }

  // --- Leerlingen tab --------------------------------------------------------

  core.Group? _selectedClass;
  core.Group? get selectedClass => _selectedClass;

  final List<StudentRow> _rows = <StudentRow>[];
  List<StudentRow> get rows => List<StudentRow>.unmodifiable(_rows);

  /// The bulk "select all" state per target, inherited by a freshly-loaded
  /// class so the header toggles persist across class selections (legacy
  /// `StudentPasswords` seeds each new list from the header checkboxes).
  final Set<PasswordTarget> _bulk = <PasswordTarget>{};
  bool bulkSelected(PasswordTarget t) => _bulk.contains(t);

  bool _busy = false;
  bool get busy => _busy;

  String? _message;
  String? get message => _message;

  /// Selects [group] as the active class and loads its rows, seeding each row's
  /// selection from the current bulk state.
  void selectClass(core.Group group) {
    _selectedClass = group;
    _rows
      ..clear()
      ..addAll(_directAccounts(group).map((a) {
        final row = StudentRow(a)..selected.addAll(_bulk);
        return row;
      }));
    notifyListeners();
  }

  void toggleRow(StudentRow row, PasswordTarget target, bool on) {
    if (on) {
      row.selected.add(target);
    } else {
      row.selected.remove(target);
    }
    notifyListeners();
  }

  /// Toggles [target] for every loaded row and records the bulk state so the
  /// next class inherits it.
  void toggleBulk(PasswordTarget target, bool on) {
    if (on) {
      _bulk.add(target);
    } else {
      _bulk.remove(target);
    }
    for (final row in _rows) {
      if (on) {
        row.selected.add(target);
      } else {
        row.selected.remove(target);
      }
    }
    notifyListeners();
  }

  /// The number of (row, target) pushes a generate would perform — used to
  /// guard the confirm dialog against an accidental mass reset.
  int get selectedCount =>
      _rows.fold(0, (sum, row) => sum + row.selected.length);

  /// Generates and pushes a fresh password for every selected (row, target),
  /// recording the results in the shared queue. A failed push is logged and its
  /// field left blank; the selection is cleared on success.
  Future<void> generate() async {
    if (_busy || selectedCount == 0) return;
    _setBusy(true);
    try {
      final entries = await _queue.load();
      final byKey = <String, PasswordEntry>{
        for (final e in entries) '${e.personId.value}|${e.kind.name}': e,
      };
      var pushed = 0;
      var failed = 0;
      final classLabel = _selectedClass?.name;

      for (final row in _rows) {
        if (row.selected.isEmpty) continue;
        String? ssPw;
        String? azPw;
        final coPws = <int, String>{};

        for (final target in row.selected) {
          final password = _generate();
          if (target == PasswordTarget.smartschool) {
            if (await _backends.setSmartschoolPassword(
                row.username, core.AccountType.student, password)) {
              ssPw = password;
              pushed++;
            } else {
              failed++;
              _log?.addError(core.Origin.smartschool,
                  'Smartschool-wachtwoord niet gezet voor ${row.username}.');
            }
          } else if (target == PasswordTarget.office365) {
            final mail = row.account.mail;
            if (mail.isNotEmpty &&
                await _backends.setAzurePassword(mail, password)) {
              azPw = password;
              pushed++;
            } else {
              failed++;
              _log?.addError(core.Origin.azure,
                  'Office 365-wachtwoord niet gezet voor ${row.name}.');
            }
          } else {
            final slot = target.coSlot!;
            if (await _backends.setSmartschoolPassword(
                row.username, _coAccountType(slot), password)) {
              coPws[slot] = password;
              pushed++;
            } else {
              failed++;
              _log?.addError(core.Origin.smartschool,
                  'Co-account $slot niet gezet voor ${row.username}.');
            }
          }
        }

        if (ssPw != null || azPw != null) {
          _mergeAccount(byKey, row, classLabel, ssPw, azPw);
        }
        if (coPws.isNotEmpty) {
          _mergeCoAccount(byKey, row, classLabel, coPws);
        }
        row.selected.clear();
      }

      await _queue.save(byKey.values.toList());
      await _reloadQueue();
      _message = failed == 0
          ? '$pushed wachtwoord(en) gegenereerd en verstuurd.'
          : '$pushed verstuurd, $failed mislukt — zie het logboek.';
    } on Object catch (e) {
      _message = 'Genereren mislukt: $e';
    } finally {
      _setBusy(false);
    }
  }

  void _mergeAccount(
    Map<String, PasswordEntry> byKey,
    StudentRow row,
    String? classLabel,
    String? ssPw,
    String? azPw,
  ) {
    final key = 'ss:${row.username}|${PasswordAccountKind.account.name}';
    final existing = byKey[key];
    byKey[key] = PasswordEntry(
      personId: core.PersonId('ss:${row.username}'),
      kind: PasswordAccountKind.account,
      accountName: row.username,
      displayName: row.name,
      mail: row.account.mail.isEmpty ? null : row.account.mail,
      classGroup: classLabel,
      smartschoolPassword: ssPw ?? existing?.smartschoolPassword,
      azurePassword: azPw ?? existing?.azurePassword,
    );
  }

  void _mergeCoAccount(
    Map<String, PasswordEntry> byKey,
    StudentRow row,
    String? classLabel,
    Map<int, String> coPws,
  ) {
    final key = 'ss:${row.username}|${PasswordAccountKind.coAccount.name}';
    final existing = byKey[key];
    byKey[key] = PasswordEntry(
      personId: core.PersonId('ss:${row.username}'),
      kind: PasswordAccountKind.coAccount,
      accountName: row.username,
      displayName: row.name,
      classGroup: classLabel,
      coAccountPasswords: <int, String>{
        ...?existing?.coAccountPasswords,
        ...coPws,
      },
    );
  }

  static core.AccountType _coAccountType(int slot) => switch (slot) {
        1 => core.AccountType.coAccount1,
        2 => core.AccountType.coAccount2,
        3 => core.AccountType.coAccount3,
        4 => core.AccountType.coAccount4,
        5 => core.AccountType.coAccount5,
        _ => core.AccountType.coAccount6,
      };

  // --- Output queue (student sheets + co-account CSV) ------------------------

  List<PasswordEntry> _studentSheets = <PasswordEntry>[];
  List<PasswordEntry> _coAccountSheets = <PasswordEntry>[];

  /// Queued student account sheets (Smartschool / Office 365 passwords).
  List<PasswordEntry> get studentSheets =>
      List<PasswordEntry>.unmodifiable(_studentSheets);

  /// Queued co-account entries (Co1..Co6 passwords), destined for the CSV.
  List<PasswordEntry> get coAccountSheets =>
      List<PasswordEntry>.unmodifiable(_coAccountSheets);

  /// Reads the shared queue and partitions it into the student-sheet and
  /// co-account outputs shown on the Leerlingen tab.
  Future<void> loadQueue() async {
    await _reloadQueue();
    notifyListeners();
  }

  Future<void> _reloadQueue() async {
    final entries = await _queue.load();
    _studentSheets = <PasswordEntry>[
      for (final e in entries)
        if (e.kind == PasswordAccountKind.account) e,
    ];
    _coAccountSheets = <PasswordEntry>[
      for (final e in entries)
        if (e.kind == PasswordAccountKind.coAccount) e,
    ];
  }

  /// Exports the queued student sheets as a printable PDF — one page per
  /// student (#195) — drains them from the shared queue (as legacy clears its
  /// list after an export), and opens the file so the operator can print
  /// straight away. Returns the written path.
  Future<String> exportStudentSheets() async {
    final sheets = List<PasswordEntry>.of(_studentSheets);
    final path = await _writer(
      'leerling-wachtwoorden.pdf',
      await studentPasswordsPdf(sheets),
    );
    await _drain(sheets);
    _message =
        _exportMessage('Leerling-wachtwoorden', path, await _tryOpen(path));
    notifyListeners();
    return path;
  }

  /// Exports the queued co-account passwords to a CSV file, then drains them.
  /// Not opened afterwards: unlike the sheets this file is fed to other tooling
  /// rather than printed — it only moved out of the temp folder (#195).
  Future<String> exportCoAccounts() async {
    final sheets = List<PasswordEntry>.of(_coAccountSheets);
    final path = await _writer(
      'co-accounts.csv',
      utf8.encode(coAccountsCsv(sheets)),
    );
    await _drain(sheets);
    _message = 'Co-account wachtwoorden bewaard: $path';
    notifyListeners();
    return path;
  }

  Future<void> _drain(List<PasswordEntry> exported) async {
    final drainedKeys = <String>{
      for (final e in exported) '${e.personId.value}|${e.kind.name}',
    };
    final remainder = <PasswordEntry>[
      for (final e in await _queue.load())
        if (!drainedKeys.contains('${e.personId.value}|${e.kind.name}')) e,
    ];
    await _queue.save(remainder);
    await _reloadQueue();
  }

  /// Opens [path] with the platform PDF viewer. Returns `null` on success, or
  /// the failure text. By the time this runs the file is already written and
  /// the queue already drained, so a viewer that will not launch costs the
  /// operator one double-click — never the export itself (#195).
  Future<String?> _tryOpen(String path) async {
    try {
      await _opener(path);
      return null;
    } on Object catch (e) {
      _log?.addError(core.Origin.other, 'Kon "$path" niet openen: $e');
      return '$e';
    }
  }

  static String _exportMessage(String what, String path, String? openError) =>
      openError == null
          ? '$what bewaard en geopend: $path'
          : '$what bewaard: $path — openen mislukt ($openError).';

  // --- Personeel tab ---------------------------------------------------------

  final List<ss.SmartschoolAccount> _allStaff = <ss.SmartschoolAccount>[];
  List<ss.SmartschoolAccount> _filteredStaff = <ss.SmartschoolAccount>[];

  /// The filtered staff list shown in the Personeel tab.
  List<ss.SmartschoolAccount> get staff =>
      List<ss.SmartschoolAccount>.unmodifiable(_filteredStaff);

  String _filterText = '';
  String get filterText => _filterText;
  // Voornaam (first name) is the more natural default to filter staff by (#186).
  StaffFilterField _filterField = StaffFilterField.voornaam;
  StaffFilterField get filterField => _filterField;

  ss.SmartschoolAccount? _selectedStaff;
  ss.SmartschoolAccount? get selectedStaff => _selectedStaff;

  void _loadStaff() {
    final root = _staffRoot;
    if (root == null) return;
    final seen = <String>{};
    void walk(core.Group group) {
      for (final uid in _uidsByGroup[group.id.value] ?? const <String>[]) {
        final account = _accountByUid[uid];
        if (account != null && seen.add(uid)) _allStaff.add(account);
      }
      for (final child in childrenOf(group)) {
        walk(child);
      }
    }

    walk(root);
    // Alphabetical by the displayed "Voornaam Naam" name, case-insensitive, so
    // the list is easy to scan when locating a person to (re)generate a
    // password for (#186).
    _allStaff.sort((a, b) => '${a.givenName} ${a.surname}'
        .trim()
        .toLowerCase()
        .compareTo('${b.givenName} ${b.surname}'.trim().toLowerCase()));
    _applyStaffFilter();
  }

  void setStaffFilterText(String text) {
    _filterText = text.trim();
    _applyStaffFilter();
    notifyListeners();
  }

  void setStaffFilterField(StaffFilterField field) {
    _filterField = field;
    _applyStaffFilter();
    notifyListeners();
  }

  void selectStaff(ss.SmartschoolAccount account) {
    _selectedStaff = account;
    notifyListeners();
  }

  void _applyStaffFilter() {
    final needle = _filterText.toLowerCase();
    if (needle.isEmpty) {
      _filteredStaff = List<ss.SmartschoolAccount>.of(_allStaff);
      return;
    }
    _filteredStaff = <ss.SmartschoolAccount>[
      for (final a in _allStaff)
        if (_staffMatches(a, needle)) a,
    ];
  }

  bool _staffMatches(ss.SmartschoolAccount a, String needle) =>
      switch (_filterField) {
        StaffFilterField.voornaam => a.givenName.toLowerCase().contains(needle),
        StaffFilterField.naam => a.surname.toLowerCase().contains(needle),
        StaffFilterField.gebruikersnaam => a.uid.toLowerCase().contains(needle),
      };

  /// Resets the selected staff member's password(s): a fresh Smartschool and/or
  /// Office 365 password (when both are requested they share one password, as
  /// legacy `NewPasswords` does), pushes them live, exports a one-page per-staff
  /// PDF sheet and opens it for printing (#195). Returns the written path, or
  /// `null` when nothing was pushed.
  Future<String?> resetStaff({
    required bool smartschool,
    required bool office365,
  }) async {
    final account = _selectedStaff;
    if (account == null || _busy || (!smartschool && !office365)) return null;
    _setBusy(true);
    try {
      final shared = _generate();
      String? ssPw;
      String? azPw;
      var failed = false;

      if (smartschool) {
        final pw = office365 ? shared : _generate();
        if (await _backends.setSmartschoolPassword(
            account.uid, core.AccountType.student, pw)) {
          ssPw = pw;
        } else {
          failed = true;
        }
      }
      if (office365) {
        final pw = smartschool ? shared : _generate();
        if (account.mail.isNotEmpty &&
            await _backends.setAzurePassword(account.mail, pw)) {
          azPw = pw;
        } else {
          failed = true;
        }
      }

      if (ssPw == null && azPw == null) {
        _message = 'Geen wachtwoord gezet — zie het logboek.';
        return null;
      }
      final path = await _writer(
        '${account.uid}.pdf',
        await staffPasswordPdf(
          name: '${account.givenName} ${account.surname}'.trim(),
          username: account.uid,
          mail: account.mail,
          smartschoolPassword: ssPw,
          office365Password: azPw,
        ),
      );
      _message = _exportMessage(
        failed ? 'Deels gezet — sheet' : 'Wachtwoord gezet en sheet',
        path,
        await _tryOpen(path),
      );
      return path;
    } on Object catch (e) {
      _message = 'Reset mislukt: $e';
      return null;
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }
}
