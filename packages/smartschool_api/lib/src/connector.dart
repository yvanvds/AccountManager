import 'package:account_core/account_core.dart' as core;

import 'errors/error_codes.dart';
import 'models/smartschool_account.dart';
import 'models/smartschool_group.dart';
import 'models/smartschool_membership.dart';
import 'parsing/account_json.dart';
import 'parsing/date_format.dart';
import 'parsing/group_tree.dart';
import 'parsing/mappings.dart';
import 'rules/import_rules.dart';
import 'snapshot.dart';
import 'soap/credentials.dart';
import 'soap/soap_envelope.dart';
import 'soap/soap_transport.dart';

/// Names of the Smartschool V3 SOAP operations the connector invokes.
/// Exposed so tests can pattern-match on them.
class SmartschoolMethod {
  SmartschoolMethod._();
  static const String getAllGroupsAndClasses = 'getAllGroupsAndClasses';
  static const String getAllAccountsExtended = 'getAllAccountsExtended';
  static const String returnJsonErrorCodes = 'returnJsonErrorCodes';
  static const String saveUser = 'saveUser';
  static const String savePassword = 'savePassword';
  static const String forcePasswordReset = 'forcePasswordReset';
  static const String saveUserParameter = 'saveUserParameter';
  static const String saveGroup = 'saveGroup';
  static const String saveClass = 'saveClass';
  static const String delClass = 'delClass';
  static const String delUser = 'delUser';
  static const String saveUserToClass = 'saveUserToClass';
  static const String saveUserToClassesAndGroups = 'saveUserToClassesAndGroups';
  static const String removeUserFromGroup = 'removeUserFromGroup';
  static const String unregisterStudent = 'unregisterStudent';
  static const String changeUsername = 'changeUsername';
  static const String changeInternNumber = 'changeInternNumber';
  static const String setAccountStatus = 'setAccountStatus';
}

/// The Smartschool user-parameter name used to store the internal number as
/// a QR code. Written after every successful save (legacy `UpdateQRCode`).
const String _qrCodeParameter = 'Interne nummer QR-code';

/// The Smartschool user-parameter name for the preferred name ("Roepnaam").
const String _preferredNameParameter = 'Roepnaam';

/// Smartschool's "no direct accounts in this group" result code, returned by
/// `getAllAccountsExtended` instead of a JSON list (legacy `Group.cs:377`).
const int _noDirectAccountsCode = 19;

/// One-instance Smartschool SOAP (V3) connector.
///
/// Mirrors the legacy single-instance design
/// (`legacy-wpf/AccountApi/Smartschool/Connector.cs`): one connector per
/// tenant per app run. Re-use the same instance across [sync] and the write
/// calls.
class SmartschoolConnector {
  final SmartschoolCredentials _credentials;
  final SmartschoolSoapTransport _transport;
  final core.ILog? _log;

  SmartschoolErrorCodes _errorCodes;
  bool _triedLoadingErrorCodes = false;

  SmartschoolConnector({
    required SmartschoolCredentials credentials,
    SmartschoolSoapTransport? transport,
    core.ILog? log,
    SmartschoolErrorCodes? errorCodes,
  })  : _credentials = credentials,
        _transport = transport ?? HttpSmartschoolSoapTransport(),
        _log = log,
        _errorCodes = errorCodes ?? SmartschoolErrorCodes.empty,
        _triedLoadingErrorCodes = errorCodes != null;

  /// Convenience constructor from the tenant subdomain and accesscode.
  factory SmartschoolConnector.fromParts({
    required String site,
    required String accessCode,
    SmartschoolSoapTransport? transport,
    core.ILog? log,
    SmartschoolErrorCodes? errorCodes,
  }) {
    return SmartschoolConnector(
      credentials: SmartschoolCredentials(site: site, accessCode: accessCode),
      transport: transport,
      log: log,
      errorCodes: errorCodes,
    );
  }

  SoapArg get _access =>
      SoapArg.string('accesscode', _credentials.accessCode);

  // ---------------------------------------------------------------------------
  // Read path
  // ---------------------------------------------------------------------------

  /// Runs a full sync: the group tree plus the account contents of every
  /// surviving group.
  ///
  /// [rules] are applied to the group tree at construction time
  /// ([DiscardSmartschoolGroup], [NoSmartschoolSubgroups]). Disabled
  /// (`uitgeschakeld`) accounts are dropped. One [SmartschoolMembership] is
  /// emitted per (account, group) pair, so an account appearing in several
  /// subtrees produces several membership rows (PAIN-1); the account record
  /// itself is deduplicated by `uid`.
  Future<SmartschoolSnapshot> sync({
    Iterable<SmartschoolImportRule> rules = const [],
  }) async {
    final treeXml = await _call(
      SmartschoolMethod.getAllGroupsAndClasses,
      [_access],
    );
    final payload = decodeReturn(treeXml).text;
    final forest = applyImportRules(parseGroupTree(payload), rules);

    final groups = <core.Group>[];
    final accountsByUid = <String, SmartschoolAccount>{};
    final memberships = <SmartschoolMembership>[];

    await _walkGroups(forest, groups, accountsByUid, memberships);

    return SmartschoolSnapshot(
      fetchedAt: DateTime.now(),
      groups: groups,
      accounts: accountsByUid.values.toList(),
      memberships: memberships,
    );
  }

  Future<void> _walkGroups(
    List<SmartschoolGroup> nodes,
    List<core.Group> groups,
    Map<String, SmartschoolAccount> accountsByUid,
    List<SmartschoolMembership> memberships,
  ) async {
    for (final node in nodes) {
      groups.add(node.toCoreGroup());

      if (node.code.isNotEmpty) {
        final accounts = await _loadAccounts(node.code, node.name);
        for (final account in accounts) {
          accountsByUid.putIfAbsent(account.uid, () => account);
          memberships.add(
            SmartschoolMembership(
              uid: account.uid,
              groupId: core.GroupId(node.code),
            ),
          );
        }
      }

      await _walkGroups(node.children, groups, accountsByUid, memberships);
    }
  }

  /// Loads the direct accounts of one group (non-recursive), filtering out
  /// disabled accounts. Returns an empty list when the group has no direct
  /// accounts (Smartschool code 19) or the payload is empty.
  Future<List<SmartschoolAccount>> _loadAccounts(
    String groupCode,
    String groupName,
  ) async {
    final responseXml = await _call(
      SmartschoolMethod.getAllAccountsExtended,
      [
        _access,
        SoapArg.string('code', groupCode),
        const SoapArg.string('recursive', '0'),
      ],
    );
    final ret = decodeReturn(responseXml);

    if (ret.isInt) {
      final code = ret.asInt!;
      if (code == _noDirectAccountsCode) {
        _log?.addMessage(
          core.Origin.smartschool,
          'No direct accounts in $groupName',
        );
      } else if (code != 0) {
        _log?.addError(core.Origin.smartschool, await _message(code));
      }
      return const [];
    }

    final parsed = parseSmartschoolAccounts(ret.text);
    final kept = [
      for (final a in parsed)
        if (a.status != disabledStatus) a,
    ];
    _log?.addMessage(
      core.Origin.smartschool,
      'Added ${kept.length} accounts to $groupName',
    );
    return kept;
  }

  // ---------------------------------------------------------------------------
  // Account writes
  // ---------------------------------------------------------------------------

  /// Creates or updates a Smartschool account (`saveUser`), then writes the
  /// QR-code parameter and, when set, the preferred name.
  ///
  /// [password] is the holder's new password (empty leaves an existing
  /// password unchanged). [coAccountPasswords] supplies up to two co-account
  /// passwords (slots 1 and 2 → `passwd2`/`passwd3`); `saveUser` only accepts
  /// these two. Returns `false` (and logs) when the role is unsupported, the
  /// save fails, or the QR-code write fails — matching legacy `Save`.
  Future<bool> saveAccount(
    SmartschoolAccount account, {
    required String password,
    List<String?> coAccountPasswords = const [],
  }) async {
    final role = account.role;
    if (role == null) {
      _log?.addError(
        core.Origin.smartschool,
        'Cannot save ${account.uid}: role is unknown',
      );
      return false;
    }
    final String basisrol;
    try {
      basisrol = smartschoolRole(role);
    } on UnsupportedSmartschoolRole catch (e) {
      _log?.addError(core.Origin.smartschool, e.toString());
      return false;
    }

    final pw2 = coAccountPasswords.isNotEmpty ? coAccountPasswords[0] : null;
    final pw3 = coAccountPasswords.length > 1 ? coAccountPasswords[1] : null;

    final ok = await _writeResult(SmartschoolMethod.saveUser, [
      _access,
      SoapArg.string('internnumber', account.accountId),
      SoapArg.string('username', account.uid),
      SoapArg.string('passwd1', password),
      SoapArg.string('passwd2', pw2 ?? ''),
      SoapArg.string('passwd3', pw3 ?? ''),
      SoapArg.string('name', account.givenName),
      SoapArg.string('surname', account.surname),
      SoapArg.string('extranames', account.extraNames),
      SoapArg.string('initials', account.initials),
      SoapArg.string('sex', smartschoolGender(account.gender)),
      SoapArg.string('birthday', formatSmartschoolDate(account.birthDate)),
      SoapArg.string('birthplace', account.birthPlace),
      SoapArg.string('birthcountry', account.birthCountry),
      SoapArg.string('address', account.address.streetAddress),
      SoapArg.string('postalcode', account.address.postalCode),
      SoapArg.string('location', account.address.city),
      SoapArg.string('country', account.address.country),
      SoapArg.string('email', account.mail),
      SoapArg.string('mobilephone', account.mobilePhone),
      SoapArg.string('homephone', account.homePhone),
      SoapArg.string('fax', account.fax),
      SoapArg.string('prn', account.registerId),
      SoapArg.string('stamboeknummer', formatStamboek(account.stemId)),
      SoapArg.string('basisrol', basisrol),
      SoapArg.string('untis', account.untisId),
    ]);
    if (!ok) return false;

    final qrOk = await updateQrCode(account.uid, account.accountId);
    if (!qrOk) {
      _log?.addError(core.Origin.smartschool, 'Failed to update QR Code');
    }

    if (account.preferredName.isNotEmpty) {
      final nameOk = await saveUserParameter(
        account.uid,
        _preferredNameParameter,
        account.preferredName,
      );
      if (!nameOk) {
        _log?.addError(
          core.Origin.smartschool,
          'Failed to update preferred name',
        );
      }
    }
    return qrOk;
  }

  /// Sets a new password for [uid]'s [slot] (`savePassword`). Smartschool
  /// requires the holder to pick a new password on next login.
  Future<bool> setPassword(
    String uid,
    core.AccountType slot,
    String password,
  ) {
    return _writeResult(SmartschoolMethod.savePassword, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('password', password),
      SoapArg.int('accountType', slot.smartschoolValue),
    ]);
  }

  /// Forces [uid]'s [slot] holder to change their password on next login.
  Future<bool> forcePasswordReset(String uid, core.AccountType slot) {
    return _writeResult(SmartschoolMethod.forcePasswordReset, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.int('accountType', slot.smartschoolValue),
    ]);
  }

  /// Writes the QR-code user parameter (the account's internal number).
  /// Called after every successful [saveAccount]; also usable on its own.
  Future<bool> updateQrCode(String uid, String accountId) =>
      saveUserParameter(uid, _qrCodeParameter, accountId);

  /// Writes an arbitrary user parameter (`saveUserParameter`).
  Future<bool> saveUserParameter(
    String uid,
    String paramName,
    String paramValue,
  ) {
    return _writeResult(SmartschoolMethod.saveUserParameter, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('paramName', paramName),
      SoapArg.string('paramValue', paramValue),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Group writes
  // ---------------------------------------------------------------------------

  /// Saves a non-class group (`saveGroup`). Smartschool rejects groups with
  /// an empty [description].
  Future<bool> saveGroup({
    required String name,
    required String description,
    required String code,
    required String parentCode,
    String untis = '',
  }) {
    return _writeResult(SmartschoolMethod.saveGroup, [
      _access,
      SoapArg.string('name', name),
      SoapArg.string('desc', description),
      SoapArg.string('code', code),
      SoapArg.string('parent', parentCode),
      SoapArg.string('untis', untis),
    ]);
  }

  /// Saves an official class (`saveClass`). Official classes need an
  /// [instituteNumber] and [adminNumber]; the institute number must already
  /// exist in Smartschool or the call is rejected.
  Future<bool> saveClass({
    required String name,
    required String description,
    required String code,
    required String parentCode,
    String untis = '',
    String instituteNumber = '',
    int adminNumber = 0,
    String schoolYearDate = '',
  }) {
    return _writeResult(SmartschoolMethod.saveClass, [
      _access,
      SoapArg.string('name', name),
      SoapArg.string('desc', description),
      SoapArg.string('code', code),
      SoapArg.string('parent', parentCode),
      SoapArg.string('untis', untis),
      SoapArg.string('instituteNumber', instituteNumber),
      SoapArg.string('adminNumber', '$adminNumber'),
      SoapArg.string('schoolYearDate', schoolYearDate),
    ]);
  }

  /// Deletes a class group by its [code] (`delClass`).
  Future<bool> deleteClass(String code) {
    return _writeResult(SmartschoolMethod.delClass, [
      _access,
      SoapArg.string('code', code),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Membership writes
  // ---------------------------------------------------------------------------

  /// Moves a student to an official class (`saveUserToClass`). [date] is the
  /// official change date — important, evaluation history depends on it. The
  /// caller must ensure [classCode] refers to an official class.
  Future<bool> moveUserToClass(String uid, String classCode, DateTime date) {
    return _writeResult(SmartschoolMethod.saveUserToClass, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('class', classCode),
      SoapArg.string('officialDate', formatSmartschoolDate(date)),
    ]);
  }

  /// Adds a user to a non-official group, keeping existing memberships
  /// (`saveUserToClassesAndGroups`, `keepOld = 1`). [groupCode] is the
  /// group's code.
  Future<bool> addUserToGroup(String uid, String groupCode) {
    return _writeResult(SmartschoolMethod.saveUserToClassesAndGroups, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('csvList', groupCode),
      const SoapArg.int('keepOld', 1),
    ]);
  }

  /// Removes a user from a non-official group (`removeUserFromGroup`).
  /// Smartschool identifies the group here by **name**, not code (legacy
  /// `RemoveUserFromGroup`). [date] defaults to nothing meaningful for
  /// non-official groups but is required by the API.
  Future<bool> removeUserFromGroup(
    String uid,
    String groupName,
    DateTime date,
  ) {
    return _writeResult(SmartschoolMethod.removeUserFromGroup, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('class', groupName),
      SoapArg.string('officialDate', formatSmartschoolDate(date)),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Account lifecycle writes
  // ---------------------------------------------------------------------------

  /// Deletes an account (`delUser`). When the account belongs to an official
  /// class, pass [officialDate] (the change date); otherwise the legacy
  /// sentinel `1-1-1` is sent.
  Future<bool> deleteUser(String uid, {DateTime? officialDate}) {
    final date =
        officialDate == null ? '1-1-1' : formatSmartschoolDate(officialDate);
    return _writeResult(SmartschoolMethod.delUser, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('officialDate', date),
    ]);
  }

  /// Officially deactivates a student (`unregisterStudent`) as of [date].
  /// Does not delete the account.
  Future<bool> unregisterStudent(String uid, DateTime date) {
    return _writeResult(SmartschoolMethod.unregisterStudent, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('officialDate', formatSmartschoolDate(date)),
    ]);
  }

  /// Changes a holder's login name (`changeUsername`), addressing the account
  /// by its internal number [accountId].
  Future<bool> changeUid(String accountId, String newUid) {
    return _writeResult(SmartschoolMethod.changeUsername, [
      _access,
      SoapArg.string('internNumber', accountId),
      SoapArg.string('newUsername', newUid),
    ]);
  }

  /// Changes a holder's internal number (`changeInternNumber`), addressing
  /// the account by its login name [uid].
  Future<bool> changeAccountId(String uid, String newAccountId) {
    return _writeResult(SmartschoolMethod.changeInternNumber, [
      _access,
      SoapArg.string('username', uid),
      SoapArg.string('newInternNumber', newAccountId),
    ]);
  }

  /// Sets an account's lifecycle status (`setAccountStatus`).
  Future<bool> setAccountStatus(String uid, core.AccountState state) {
    return _writeResult(SmartschoolMethod.setAccountStatus, [
      _access,
      SoapArg.string('userIdentifier', uid),
      SoapArg.string('accountStatus', statusFromAccountState(state)),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  /// Sends one RPC call and returns the raw response XML.
  Future<String> _call(String method, List<SoapArg> args) {
    final envelope = buildRpcEnvelope(
      namespace: _credentials.namespace,
      method: method,
      args: args,
    );
    return _transport.send(
      endpoint: _credentials.endpoint,
      soapAction: soapActionFor(_credentials.namespace, method),
      envelope: envelope,
    );
  }

  /// Sends a write-style call, decodes the integer result, and translates a
  /// non-zero code to a logged error. Returns `true` only on code `0`.
  Future<bool> _writeResult(String method, List<SoapArg> args) async {
    final responseXml = await _call(method, args);
    final code = decodeIntResult(responseXml);
    if (code != 0) {
      _log?.addError(core.Origin.smartschool, await _message(code));
      return false;
    }
    return true;
  }

  /// Translates a Smartschool result code to a message, loading the error
  /// table lazily on first need. Loading is best-effort — a failure leaves a
  /// generic fallback message.
  Future<String> _message(int code) async {
    await _ensureErrorCodes();
    return _errorCodes.translate(code);
  }

  Future<void> _ensureErrorCodes() async {
    if (_triedLoadingErrorCodes) return;
    _triedLoadingErrorCodes = true;
    try {
      final xml = await _call(
        SmartschoolMethod.returnJsonErrorCodes,
        [_access],
      );
      _errorCodes = SmartschoolErrorCodes.fromJson(decodeReturn(xml).text);
    } on Object catch (e) {
      _log?.addError(
        core.Origin.smartschool,
        'Failed to load Smartschool error codes: $e',
      );
    }
  }
}
