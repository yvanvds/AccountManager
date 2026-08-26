import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:flutter/foundation.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../search/name_query.dart';
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

/// The default linked-snapshot provider: none. A [PasswordController] built
/// without one behaves exactly as it did before #372 — the Smartschool tree is
/// the only roster, and an Office 365 push resolves by address.
core.LinkedSnapshot? _noLinkedSnapshot() => null;

/// One student in the currently-selected class, with its per-target selection.
class StudentRow {
  StudentRow(this.account, {this.linked});

  final ss.SmartschoolAccount account;

  /// The linker's record for this person, when a linked snapshot is in hand
  /// (#372) — the **only** place the Office 365 account is read from.
  ///
  /// `null` means "this session has not linked", not "no Azure account": see
  /// [hasNoAzureAccount], which is the positive statement and the one the row
  /// reports on screen.
  final core.LinkedAccount? linked;

  final Set<PasswordTarget> selected = <PasswordTarget>{};

  /// What the last generate could **not** do for this row, in one short line
  /// shown beside the row (#372).
  ///
  /// A miss used to leave nothing but a line in the Log panel, so a class-wide
  /// generate that silently skipped Office 365 for a handful of students read
  /// exactly like one that succeeded for all of them.
  String? problem;

  String get username => account.uid;
  String get name => '${account.givenName} ${account.surname}'.trim();

  /// The Graph object id of the Azure account the linker attached, or `null`
  /// when there is none to push to.
  String? get azureObjectId {
    final id = linked?.azure?.id;
    return id == null || id.isEmpty ? null : id;
  }

  /// Whether the linker **positively holds no** Office 365 account for this
  /// student — a fact worth stating before a generate, not only after one.
  bool get hasNoAzureAccount => linked != null && azureObjectId == null;
}

/// One person on the Personeel tab.
///
/// Since #372 the roster is the linker's, not the Smartschool group tree's, so
/// a row is no longer necessarily backed by a group membership — or even by a
/// Smartschool account. What a row always carries is a name and at least one
/// account a password can be reset on.
class StaffRow {
  StaffRow({
    required this.name,
    required this.uid,
    required this.mail,
    this.linked,
  });

  /// The linker's record, when this row came from the linked snapshot (or the
  /// group walk found a uid the linker also holds). `null` for a row the group
  /// walk contributed that the linker has no staff record for.
  final core.LinkedStaff? linked;

  /// Display name, "Voornaam Naam".
  final String name;

  /// Smartschool username — empty for someone the linker holds who has no
  /// Smartschool account at all. Only the Office 365 reset is open to them.
  final String uid;

  final String mail;

  /// What the last reset could **not** do for this person, in one short line
  /// shown in the detail panel (#372) — the staff twin of [StudentRow.problem].
  String? problem;

  /// A stable identity for this row across a rebuild, so a snapshot landing
  /// mid-selection keeps the operator's place. The uid where there is one, so
  /// the tile keys stay what they have always been.
  String get key => uid.isNotEmpty ? uid : (linked?.id.value ?? name);

  /// The Graph object id of the Azure account the linker attached, or `null`.
  String? get azureObjectId {
    final id = linked?.azure?.id;
    return id == null || id.isEmpty ? null : id;
  }

  /// Whether the linker positively holds no Office 365 account for this person.
  bool get hasNoAzureAccount => linked != null && azureObjectId == null;

  bool get hasSmartschoolAccount => uid.isNotEmpty;
}

/// Drives the reworked Passwords screen (#180): on-demand password generation
/// for students (per-class, per-target, bulk) and staff (per-member resets),
/// reading the Smartschool class tree **and the linked snapshot** from the last
/// sync and pushing fresh passwords live through [PasswordBackends].
///
/// The linked snapshot is what identifies people here since #372. The class tree
/// is still the spine of the Leerlingen tab — it is how an operator navigates to
/// a class — but who a row *is* comes from the linker: which Office 365 account
/// belongs to this person, and (on the Personeel tab) which people exist at all.
/// Reading either fact out of the group tree was the bug: a Smartschool `mail`
/// is not a UPN, and an account Smartschool has seated in no group has no
/// membership row to be found by.
///
/// The key correction over the old distribution-only queue: passwords are
/// generated **on demand from this screen**, not as a side effect of account
/// creation. Generated student/co-account passwords are recorded in the shared
/// [PasswordQueueStore] for printing/CSV; staff resets export a per-staff sheet
/// immediately (they are never queued), mirroring the legacy app.
class PasswordController extends ChangeNotifier {
  PasswordController({
    required ss.SmartschoolSnapshot? Function() snapshot,
    required PasswordQueueStore queue,
    required PasswordBackends backends,
    core.LinkedSnapshot? Function() linked = _noLinkedSnapshot,
    PasswordFileWriter writer = writePasswordExport,
    PasswordFileOpener opener = openPasswordExport,
    String Function() generatePassword = core.Password.create,
    String studentGroupName = 'Leerlingen',
    String staffGroupName = 'Personeel',
    core.ILog? log,
  })  : _snapshotOf = snapshot,
        _linkedOf = linked,
        _studentGroupName = studentGroupName,
        _staffGroupName = staffGroupName,
        _queue = queue,
        _backends = backends,
        _writer = writer,
        _opener = opener,
        _generate = generatePassword,
        _log = log {
    _reindex();
  }

  /// Where the Smartschool group tree comes from, read **live** rather than
  /// captured (#287).
  ///
  /// The screen hands over `() => app.smartschool.snapshot`. Capturing the value
  /// at bootstrap froze this screen on whatever the session held the instant it
  /// was first opened — which, in a session that seeded from the cold store and
  /// then synced, is the *older* of the two trees.
  final ss.SmartschoolSnapshot? Function() _snapshotOf;

  /// Where the **linked snapshot** comes from, read live like the tree above
  /// (#372).
  ///
  /// The screen hands over `() => services.controller.linked?.snapshot`. This is
  /// what makes the Office 365 account resolvable (`employeeId ≡ wisaId`, the
  /// bridge `link()` already applied) and the Personeel roster complete: an
  /// account that sits in no Smartschool group has no membership row for the
  /// group walk to find, but the linker holds it all the same.
  ///
  /// `null` — a session that has neither synced nor adopted the shared state —
  /// is a real state, not a failure: everything falls back to the pre-#372
  /// behaviour so the screen stays usable.
  final core.LinkedSnapshot? Function() _linkedOf;

  /// The snapshot the index below was built from, so [refresh] can tell a real
  /// change from a repaint and cost nothing on the latter.
  ss.SmartschoolSnapshot? _indexed;

  /// The linked snapshot the index below was built from — the second half of
  /// [refresh]'s identity guard, since either can move on its own.
  core.LinkedSnapshot? _indexedLink;

  final String _studentGroupName;
  final String _staffGroupName;
  final PasswordQueueStore _queue;
  final PasswordBackends _backends;
  final PasswordFileWriter _writer;
  final PasswordFileOpener _opener;
  final String Function() _generate;
  final core.ILog? _log;

  // --- Group-tree index (rebuilt whenever the snapshot moves) ----------------

  final Map<String, List<core.Group>> _childrenByParent =
      <String, List<core.Group>>{};
  final Map<String, ss.SmartschoolAccount> _accountByUid =
      <String, ss.SmartschoolAccount>{};
  final Map<String, List<String>> _uidsByGroup = <String, List<String>>{};
  final Map<String, core.Group> _groupsById = <String, core.Group>{};

  // --- Linked index (#372) ---------------------------------------------------

  /// The linker's student record per Smartschool username — how a row on the
  /// Leerlingen tab reaches the Azure account attached to that person.
  final Map<String, core.LinkedAccount> _linkedStudentsByUid =
      <String, core.LinkedAccount>{};

  /// The linker's staff record per Smartschool username, for the rows the group
  /// walk contributes.
  final Map<String, core.LinkedStaff> _linkedStaffByUid =
      <String, core.LinkedStaff>{};

  /// The "Leerlingen" root of the student class tree, or `null` when the last
  /// sync carried no such group (or there was no sync this session).
  core.Group? studentRoot;
  core.Group? _staffRoot;

  /// Rebuilds every index from the snapshot the provider answers with now.
  void _reindex() {
    final snap = _snapshotOf();
    final linked = _linkedOf();
    _indexed = snap;
    _indexedLink = linked;
    _childrenByParent.clear();
    _accountByUid.clear();
    _uidsByGroup.clear();
    _groupsById.clear();
    _linkedStudentsByUid.clear();
    _linkedStaffByUid.clear();
    _allStaff.clear();
    if (linked != null) {
      for (final record in linked.accounts) {
        final uid = record.smartschool?.uid ?? '';
        if (uid.isNotEmpty) _linkedStudentsByUid[uid] = record;
      }
      for (final record in linked.staff) {
        final uid = record.smartschool?.uid ?? '';
        if (uid.isNotEmpty) _linkedStaffByUid[uid] = record;
      }
    }
    if (snap != null) {
      for (final account in snap.accounts) {
        _accountByUid[account.uid] = account;
      }
      for (final group in snap.groups) {
        _groupsById[group.id.value] = group;
        final parent = group.parentId?.value;
        if (parent != null) {
          _childrenByParent
              .putIfAbsent(parent, () => <core.Group>[])
              .add(group);
        }
      }
      for (final m in snap.memberships) {
        _uidsByGroup.putIfAbsent(m.groupId.value, () => <String>[]).add(m.uid);
      }
    }
    studentRoot = _findGroupByName(_studentGroupName, snap);
    _staffRoot = _findGroupByName(_staffGroupName, snap);
    _loadStaff();
    // `_loadStaff` returns early when there is no staff root, which would leave
    // the previous tree's filtered list standing; re-filter unconditionally.
    _applyStaffFilter();
  }

  /// Adopts a Smartschool snapshot — or a linked snapshot (#372) — that arrived
  /// after this screen opened: a sync, a drift check, an apply that patched the
  /// tree, or the session's opening adoption of the shared state (#287).
  ///
  /// A no-op while **both** live snapshots are the ones already indexed, so a
  /// listener may call it on every repaint. Either can move without the other:
  /// an apply patches the tree, and a link replaces the linked view alone. When
  /// it does rebuild, the operator's place is kept wherever it still exists: the
  /// open class is re-resolved by id and its rows keep the targets already
  /// ticked, so a colleague's sync landing mid-selection does not silently
  /// discard the work.
  void refresh() {
    if (identical(_snapshotOf(), _indexed) &&
        identical(_linkedOf(), _indexedLink)) {
      return;
    }
    final String? openClassId = _selectedClass?.id.value;
    final String? openStaffKey = _selectedStaff?.key;
    final ticked = <String, Set<PasswordTarget>>{
      for (final row in _rows) row.username: <PasswordTarget>{...row.selected},
    };

    _reindex();

    _selectedStaff = openStaffKey == null
        ? null
        : _allStaff.where((r) => r.key == openStaffKey).firstOrNull;
    final core.Group? again =
        openClassId == null ? null : _groupsById[openClassId];
    _selectedClass = again;
    _rows.clear();
    if (again != null) {
      _rows.addAll(_directAccounts(again).map(
        (a) => _studentRow(a)..selected.addAll(ticked[a.uid] ?? _bulk),
      ));
    }
    notifyListeners();
  }

  /// The row for [account], carrying the linker's record for that person so the
  /// Office 365 push resolves through the link rather than through the mail
  /// (#372).
  StudentRow _studentRow(ss.SmartschoolAccount account) =>
      StudentRow(account, linked: _linkedStudentsByUid[account.uid]);

  core.Group? _findGroupByName(String name, ss.SmartschoolSnapshot? snap) {
    for (final group in snap?.groups ?? const <core.Group>[]) {
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
        final row = _studentRow(a)..selected.addAll(_bulk);
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
    _rightsProblem = null;
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
        // The previous run's verdict is not this run's; clear it before the
        // pushes so a row that succeeds stops claiming a problem (#372).
        row.problem = null;
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
            final set = await _pushStudentAzurePassword(row, password);
            if (set != null) {
              azPw = set;
              pushed++;
            } else {
              failed++;
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
      final rights = _rightsProblem;
      _message = rights != null
          ? '$pushed verstuurd, $failed mislukt — $rights'
          : failed == 0
              ? '$pushed wachtwoord(en) gegenereerd en verstuurd.'
              : '$pushed verstuurd, $failed mislukt — zie het logboek.';
    } on Object catch (e) {
      _message = 'Genereren mislukt: $e';
    } finally {
      _setBusy(false);
    }
  }

  // --- The Office 365 write (shared by both tabs) ----------------------------

  /// The operator-readable diagnosis of a refused Office 365 write, set while a
  /// generate/reset runs and folded into [message] when it finishes (#216).
  /// Cleared at the start of each run so a fixed tenant stops reporting it.
  String? _rightsProblem;

  /// What a row says when the linker holds no Office 365 account for the person
  /// on it — sub-problem 2 of #372: a miss during a bulk generation for a whole
  /// intake must be distinguishable from a success.
  static const String noAzureAccountNote = 'Geen Office 365-account gekoppeld.';

  /// What a row says when the account exists but the write did not land. The
  /// long diagnosis (rights, Graph error) stays in [message] and the log.
  static const String azureNotSetNote = 'Office 365-wachtwoord niet gezet.';

  /// What a Personeel row says when the linker holds this person but no
  /// Smartschool account for them (#372).
  static const String noSmartschoolAccountNote = 'Geen Smartschool-account.';

  /// Pushes [password] to the Office 365 account of a staff [row], the staff
  /// twin of [_pushStudentAzurePassword] (#372).
  Future<String?> _pushStaffAzurePassword(StaffRow row, String password) async {
    final objectId = row.azureObjectId;
    if (objectId != null) {
      final set = await _pushAzure(
        () => _backends.setAzurePasswordById(objectId, password),
        row.name,
        password,
      );
      if (set == null) row.problem ??= azureNotSetNote;
      return set;
    }
    if (row.hasNoAzureAccount) {
      row.problem ??= noAzureAccountNote;
      _log?.addError(
        core.Origin.azure,
        'Geen Office 365-account gekoppeld voor ${row.name} — wachtwoord '
        'niet gezet.',
      );
      return null;
    }
    final set = await _pushAzurePassword(row.mail, row.name, password);
    if (set == null) row.problem ??= azureNotSetNote;
    return set;
  }

  /// The file name of a per-staff sheet: the username where there is one, and
  /// otherwise the person's name reduced to filename-safe characters — a row
  /// off the linked roster need not have a Smartschool account to name it by.
  static String _sheetName(StaffRow row) {
    if (row.uid.isNotEmpty) return row.uid;
    final safe = row.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    return safe.isEmpty ? 'personeelslid' : safe;
  }

  /// Pushes [password] to the Office 365 account of [row] and records what went
  /// wrong **on the row** as well as in the log (#372).
  ///
  /// The account is resolved through the linked record — the `employeeId ≡
  /// wisaId` bridge `link()` already applied — rather than by handing Graph the
  /// Smartschool `mail` as if it were a UPN. Where the two have drifted apart
  /// (a collision suffix, a private address, a differently folded accent) that
  /// lookup answered `Request_ResourceNotFound` and the push silently did
  /// nothing for a student who does have an account.
  ///
  /// Three outcomes, and the row can tell them apart:
  /// - the linker attached an account ⇒ push to its object id;
  /// - the linker holds this person and attached none ⇒ say so, push nothing;
  /// - no linked snapshot at all ⇒ fall back to the address lookup, which is
  ///   the best key a session that has not linked has.
  Future<String?> _pushStudentAzurePassword(
    StudentRow row,
    String password,
  ) async {
    final objectId = row.azureObjectId;
    if (objectId != null) {
      final set = await _pushAzure(
        () => _backends.setAzurePasswordById(objectId, password),
        row.name,
        password,
      );
      if (set == null) row.problem = azureNotSetNote;
      return set;
    }
    if (row.hasNoAzureAccount) {
      row.problem = noAzureAccountNote;
      _log?.addError(
        core.Origin.azure,
        'Geen Office 365-account gekoppeld voor ${row.name} '
        '(${row.username}) — wachtwoord niet gezet.',
      );
      return null;
    }
    final set = await _pushAzurePassword(row.account.mail, row.name, password);
    if (set == null) row.problem = azureNotSetNote;
    return set;
  }

  /// Pushes [password] to Azure for [mail], returning it when the write landed
  /// and `null` when it did not.
  ///
  /// The pre-#372 path, kept as the fallback for a session holding no linked
  /// snapshot: an address is then the only key available.
  Future<String?> _pushAzurePassword(
    String mail,
    String who,
    String password,
  ) async {
    if (mail.isEmpty) {
      _log?.addError(
        core.Origin.azure,
        'Office 365-wachtwoord niet gezet voor $who.',
      );
      return null;
    }
    return _pushAzure(
      () => _backends.setAzurePassword(mail, password),
      who,
      password,
    );
  }

  /// Runs one Azure password write and turns its outcome into the operator's
  /// language, returning [password] when it landed and `null` when it did not.
  ///
  /// A refused write — Graph `403`, because the sign-in lacks the
  /// `User-PasswordProfile.ReadWrite.All` permission or the operator holds no
  /// password-reset role — used to surface as a raw `GraphException` string, or
  /// as an unexplained "niet gezet". It is recorded as a rights problem naming
  /// [who] instead (#216). Both tabs push through here, so the class-wide
  /// generate and the per-staff reset report the same diagnosis, and a refusal
  /// ends only this one push: the rest of a class batch still runs.
  Future<String?> _pushAzure(
    Future<bool> Function() push,
    String who,
    String password,
  ) async {
    try {
      if (await push()) return password;
      _log?.addError(
        core.Origin.azure,
        'Office 365-wachtwoord niet gezet voor $who.',
      );
    } on az.AzurePasswordPermissionException catch (e) {
      final problem = _rightsMessage(who);
      _rightsProblem = problem;
      _log?.addError(core.Origin.azure, '$problem ($e)');
    }
    return null;
  }

  /// What the operator reads when Azure refuses the write: who it was for, and
  /// the two directory-side causes worth checking, in the order they bite.
  static String _rightsMessage(String who) =>
      'Geen rechten om het Office 365-wachtwoord van $who te resetten — de '
      'aanmelding mist de Graph-toestemming '
      '"User-PasswordProfile.ReadWrite.All" (beheerderstoestemming geven en '
      'opnieuw aanmelden), of je account heeft geen rol die wachtwoorden mag '
      'resetten (Gebruikersbeheerder).';

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

  final List<StaffRow> _allStaff = <StaffRow>[];
  List<StaffRow> _filteredStaff = <StaffRow>[];

  /// The filtered staff list shown in the Personeel tab.
  List<StaffRow> get staff => List<StaffRow>.unmodifiable(_filteredStaff);

  String _filterText = '';
  String get filterText => _filterText;

  StaffRow? _selectedStaff;
  StaffRow? get selectedStaff => _selectedStaff;

  /// Builds the Personeel roster from the **linked snapshot**, unioned with the
  /// Smartschool "Personeel" group walk (#372).
  ///
  /// The walk alone could only ever list people Smartschool had already seated
  /// in a group, so a staff account this app had just created through
  /// `AddStaffToSmartschool` — which writes the account and nothing else — was
  /// invisible here while the Acties card beside it showed Smartschool green. A
  /// re-sync could not rescue it either: the Smartschool pull assembles its
  /// snapshot by walking the group forest, so a group-less account never enters
  /// it. The linker holds the person regardless, which is what this reads.
  ///
  /// The walk is kept as the second half of a **union**, never replaced: it
  /// carries whoever the linked view does not (a session that has not linked at
  /// all; an account the linker classified by its Smartschool role as something
  /// other than staff). Nobody who was reachable before #372 stops being
  /// reachable.
  void _loadStaff() {
    final seen = <String>{};
    final linked = _indexedLink;
    if (linked != null) {
      for (final record in linked.staff) {
        if (!_isResettableStaff(record)) continue;
        final uid = record.smartschool?.uid ?? '';
        if (uid.isNotEmpty && !seen.add(uid)) continue;
        _allStaff.add(_staffRowFor(record, uid));
      }
    }
    final root = _staffRoot;
    if (root != null) {
      void walk(core.Group group) {
        for (final uid in _uidsByGroup[group.id.value] ?? const <String>[]) {
          final account = _accountByUid[uid];
          if (account == null || !seen.add(uid)) continue;
          _allStaff.add(StaffRow(
            name: '${account.givenName} ${account.surname}'.trim(),
            uid: account.uid,
            mail: account.mail,
            linked: _linkedStaffByUid[uid],
          ));
        }
        for (final child in childrenOf(group)) {
          walk(child);
        }
      }

      walk(root);
    }
    // Alphabetical by the displayed "Voornaam Naam" name, case-insensitive, so
    // the list is easy to scan when locating a person to (re)generate a
    // password for (#186).
    _allStaff.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    _applyStaffFilter();
  }

  /// Whether a linked staff record has anything this screen could reset.
  ///
  /// One of ours ([core.LinkedStaff.belongsToOurSchool]) holding a Smartschool
  /// account, or — for someone who has none — a current WISA row *and* an Azure
  /// account, so an Office 365 reset is meaningful. Excludes the two shapes with
  /// nothing to offer: a WISA-only row (no account anywhere) and an Azure-only
  /// leftover of someone who has left the group, which belongs on the deletion
  /// side of the app rather than in a password roster.
  static bool _isResettableStaff(core.LinkedStaff record) =>
      record.belongsToOurSchool &&
      (record.smartschool != null ||
          (record.wisa != null && record.azure != null));

  /// A row for a linked staff record: the concrete Smartschool account supplies
  /// the display name where there is one (the linker's own `smartschool` is the
  /// narrow `account_core` interface, which carries no name), then the WISA row,
  /// then the Azure address, then the username.
  StaffRow _staffRowFor(core.LinkedStaff record, String uid) {
    final account = uid.isEmpty ? null : _accountByUid[uid];
    final wisa = record.wisa;
    final upn = record.azure?.upn ?? '';
    final String name;
    if (account != null &&
        '${account.givenName} ${account.surname}'.trim().isNotEmpty) {
      name = '${account.givenName} ${account.surname}'.trim();
    } else if (wisa is wapi.WisaStaff &&
        '${wisa.firstName} ${wisa.lastName}'.trim().isNotEmpty) {
      name = '${wisa.firstName} ${wisa.lastName}'.trim();
    } else if (upn.isNotEmpty) {
      name = upn.split('@').first;
    } else {
      name = uid;
    }
    return StaffRow(
      name: name,
      uid: uid,
      mail: account?.mail ?? upn,
      linked: record,
    );
  }

  void setStaffFilterText(String text) {
    _filterText = text.trim();
    _applyStaffFilter();
    notifyListeners();
  }

  void selectStaff(StaffRow row) {
    _selectedStaff = row;
    notifyListeners();
  }

  /// Narrows the staff list to the accounts matching the current filter text.
  /// The needle is split on whitespace and every part must match (#215), so an
  /// empty or whitespace-only needle shows everyone.
  ///
  /// The matching itself lives in [NameQuery], shared with the Acties Personeel
  /// search so the two boxes cannot drift apart (#217).
  void _applyStaffFilter() {
    final query = NameQuery(_filterText);
    if (query.isEmpty) {
      _filteredStaff = List<StaffRow>.of(_allStaff);
      return;
    }
    _filteredStaff = <StaffRow>[
      for (final row in _allStaff)
        if (query.matches(row.name)) row,
    ];
  }

  /// Resets the selected staff member's password(s): a fresh Smartschool and/or
  /// Office 365 password (when both are requested they share one password, as
  /// legacy `NewPasswords` does), pushes them live, exports a one-page per-staff
  /// PDF sheet and opens it for printing (#195). Returns the written path, or
  /// `null` when nothing was pushed.
  ///
  /// Both halves resolve their target the way the Leerlingen tab now does
  /// (#372): the Smartschool push needs a username this person may not have,
  /// and the Office 365 push goes to the account the linker attached rather than
  /// to whatever address Smartschool holds. Either missing target is named in
  /// [message] and on the row instead of counted as an unexplained failure.
  Future<String?> resetStaff({
    required bool smartschool,
    required bool office365,
  }) async {
    final row = _selectedStaff;
    if (row == null || _busy || (!smartschool && !office365)) return null;
    _setBusy(true);
    _rightsProblem = null;
    row.problem = null;
    try {
      final shared = _generate();
      final who = row.name;
      String? ssPw;
      String? azPw;
      var failed = false;

      if (smartschool) {
        final pw = office365 ? shared : _generate();
        if (!row.hasSmartschoolAccount) {
          failed = true;
          row.problem = noSmartschoolAccountNote;
          _log?.addError(core.Origin.smartschool,
              'Geen Smartschool-account voor $who — wachtwoord niet gezet.');
        } else if (await _backends.setSmartschoolPassword(
            row.uid, core.AccountType.student, pw)) {
          ssPw = pw;
        } else {
          failed = true;
        }
      }
      if (office365) {
        final pw = smartschool ? shared : _generate();
        azPw = await _pushStaffAzurePassword(row, pw);
        if (azPw == null) failed = true;
      }

      final rights = _rightsProblem;
      if (ssPw == null && azPw == null) {
        _message =
            rights ?? row.problem ?? 'Geen wachtwoord gezet — zie het logboek.';
        return null;
      }
      final path = await _writer(
        '${_sheetName(row)}.pdf',
        await staffPasswordPdf(
          name: who,
          username: row.uid,
          mail: row.mail,
          smartschoolPassword: ssPw,
          office365Password: azPw,
        ),
      );
      final exported = _exportMessage(
        failed ? 'Deels gezet — sheet' : 'Wachtwoord gezet en sheet',
        path,
        await _tryOpen(path),
      );
      // A half-successful reset still hands over a sheet, so say both: what was
      // written, and why the Office 365 half was refused (#216).
      _message = rights == null ? exported : '$rights $exported';
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
