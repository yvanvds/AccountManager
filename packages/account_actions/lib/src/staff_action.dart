import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'action_result.dart';
import 'apply_options.dart';
import 'change_set.dart';
import 'connectors.dart';
import 'staff_action_config.dart';

/// The staff action family (spec `docs/domain-model.md` §3.10). One subclass
/// per legacy `Action\StaffAccount\*` class, mirroring [StudentAction].
///
/// **Target binding.** Each action is bound to the [LinkedStaff] it acts on at
/// construction; [evaluate]/[describeChanges] read the bound [staff] (exposed
/// as [target]) and stay pure, while [apply] carries no target of its own.
///
/// **Purity boundary (INV-40/41/42).** [evaluate] and [describeChanges] are
/// pure and deterministic — no I/O, no globals. [apply] is the only impure
/// operation; it is retry-safe (a transient failure returns
/// [ActionOutcome.failed] without corrupting state) and never mutates the
/// bound [staff] or its snapshot records — every changed record is a fresh
/// copy.
///
/// **Staff vs student differences.** Staff bridge to Smartschool by
/// [wapi.WisaStaff.code] (not `wisaId`) — `AddToSmartschool` and
/// `UpdateWisaName` write the code into `accountId` (spec §4, OQ-1). Staff live
/// on the base [StaffActionConfig.azureDomain] (no student sub-domain). The
/// office-365 / Smartschool **group** placements the legacy add-actions perform
/// are out of scope here (see the package README) — they need a
/// membership-aware input, tracked as the `AddToAzureStaffGroup` /
/// `AddToStaffGroup` follow-up.
sealed class StaffAction {
  /// The linked staff record this action targets, bound at construction.
  final LinkedStaff staff;

  /// Injected configuration (domain, password/uid builders).
  final StaffActionConfig config;

  const StaffAction(this.staff, this.config);

  /// Alias for the bound [staff] — the "target" the spec's `evaluate(target)`
  /// refers to.
  LinkedStaff get target => staff;

  /// Whether this action applies to [staff]. Pure and deterministic (INV-40).
  bool evaluate();

  /// The field-level diff this action would make. Pure (INV-40).
  ChangeSet describeChanges();

  /// The key shared by mutually-exclusive alternatives resolving the same
  /// situation (#110). No staff action has alternatives today, so this is always
  /// `null`; the getter exists so the pending-list grouping treats every family
  /// uniformly. See [StudentAction.alternativeGroup].
  String? get alternativeGroup => null;

  /// Whether this action is the default alternative within its
  /// [alternativeGroup]. Ignored when [alternativeGroup] is `null`.
  bool get isDefaultAlternative => false;

  /// Performs the change on the target system. Impure. With
  /// [ApplyOptions.dryRun] set, performs **no** writes and returns the
  /// projected [ActionResult] (PAIN-3).
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options);

  // --- shared helpers -------------------------------------------------------

  wapi.WisaStaff get _wisa => staff.wisa! as wapi.WisaStaff;
  ss.SmartschoolAccount get _ss => staff.smartschool! as ss.SmartschoolAccount;
  az.AzureUser get _az => staff.azure! as az.AzureUser;

  ss.SmartschoolConnector _requireSmartschool(Connectors c) =>
      c.smartschool ??
      (throw StateError('$runtimeType.apply needs a Smartschool connector'));

  az.AzureConnector _requireAzure(Connectors c) =>
      c.azure ??
      (throw StateError('$runtimeType.apply needs an Azure connector'));

  ActionResult _failed(ChangeSet changes, Origin system, Object error) =>
      ActionResult(
        outcome: ActionOutcome.failed,
        changes: changes,
        system: system,
        error: error,
      );
}

// ---------------------------------------------------------------------------
// Lifecycle actions — evaluated only when a system is missing (§6.3).
// ---------------------------------------------------------------------------

/// Create an Office 365 account for a staff member present in WISA but not
/// Azure. Ported from `Action\StaffAccount\AddToAzure` (the `-Personeel` group
/// placement is deferred — see the README).
class AddStaffToAzure extends StaffAction {
  const AddStaffToAzure(super.staff, super.config);

  @override
  bool evaluate() => staff.wisa != null && staff.azure == null;

  String get _displayName => '${_wisa.firstName} ${_wisa.lastName}'.trim();

  String _projectedUpn() =>
      '${_slug(_wisa.firstName)}.${_slug(_wisa.lastName)}@${config.azureDomain}';

  @override
  ChangeSet describeChanges() {
    final wisa = _wisa;
    return ChangeSet(
      system: Origin.azure,
      summary: 'Maak een nieuw Office 365 account',
      fields: [
        FieldChange('userPrincipalName', after: _projectedUpn()),
        FieldChange('displayName', after: _displayName),
        FieldChange('employeeId', after: wisa.wisaId?.value),
        FieldChange('department', after: config.schoolPrefix),
      ],
    );
  }

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final wisa = _wisa;

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        azure: az.AzureUser(
          id: '',
          upn: _projectedUpn(),
          employeeId: wisa.wisaId?.value,
          displayName: _displayName,
          givenName: wisa.firstName,
          surname: wisa.lastName,
          department: config.schoolPrefix,
        ),
      );
    }

    try {
      final users = _requireAzure(connectors).users;
      // #231 (the staff half of #224): never create a second account for
      // someone who already has one. The snapshot this action was derived from
      // can be stale — or blind, when the account's `department` still names
      // the sibling group school the member moved in from — and
      // `createPrincipalName` resolves the UPN collision by suffixing, so the
      // duplicate create would succeed silently. `employeeId` is the one key
      // that survives a move between group schools, so a hit means the account
      // exists and the next sync must adopt it instead.
      //
      // A staff row may carry no `wisaId` at all (`code` is the staff primary
      // key, spec §3.4): then there is no id to look up — and none to stamp on
      // the account either, so no future sync could confuse the two.
      final expectedId = wisa.wisaId?.value.trim() ?? '';
      if (expectedId.isNotEmpty) {
        final existing = await users.findByEmployeeId(expectedId);
        if (existing != null) {
          return _failed(
            changes,
            Origin.azure,
            StateError(
              'Office 365 already has an account with employeeId '
              '$expectedId (${existing.upn}). Sync Azure again so the existing '
              'account is linked instead of creating a duplicate.',
            ),
          );
        }
      }
      final upn = await users.createPrincipalName(
        wisa.firstName,
        wisa.lastName,
        config.azureDomain,
        isStudent: false,
      );
      final password = config.newAccountPassword();
      final created = await users.createUser(
        userPrincipalName: upn,
        displayName: _displayName,
        password: password,
        givenName: wisa.firstName,
        surname: wisa.lastName,
        employeeId: wisa.wisaId?.value,
        department: config.schoolPrefix,
        forceChangePasswordNextSignIn: true,
      );
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        azure: created,
        generatedPassword: password,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }
}

/// Create a Smartschool account for a staff member present in WISA and Azure
/// but not Smartschool. Ported from `Action\StaffAccount\AddToSmartschool` —
/// the account is built from the Azure record with the WISA [wapi.WisaStaff.code]
/// as its `accountId` (spec §4) and the WISA `wisaId` as its copy-code (`fax`);
/// the group placement (Leerkrachten / Leerlingen) is deferred (see README).
class AddStaffToSmartschool extends StaffAction {
  const AddStaffToSmartschool(super.staff, super.config);

  @override
  bool evaluate() =>
      staff.wisa != null && staff.azure != null && staff.smartschool == null;

  ss.SmartschoolAccount _build() {
    final wisa = _wisa;
    final azure = _az;
    return ss.SmartschoolAccount(
      uid: config.smartschoolUid(azure.givenName, azure.surname),
      accountId: wisa.code.value,
      mail: azure.upn,
      registerId: '',
      stemId: 0,
      role: PersonRole.teacher,
      givenName: azure.givenName,
      surname: azure.surname,
      extraNames: '',
      initials: '',
      preferredName: '',
      // Legacy hard-codes Female here; WISA staff rows carry no gender, so
      // there is nothing better to derive it from. Preserved verbatim.
      gender: Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: const Address(
        street: '',
        houseNumber: '',
        postalCode: '',
        city: '',
        country: '',
      ),
      mobilePhone: '',
      homePhone: '',
      fax: wisa.wisaId?.value ?? '',
      untisId: '',
      status: 'actief',
    );
  }

  @override
  ChangeSet describeChanges() {
    final built = _build();
    return ChangeSet(
      system: Origin.smartschool,
      summary: 'Maak een nieuw Smartschool account',
      fields: [
        FieldChange('uid', after: built.uid),
        FieldChange('accountId', after: built.accountId),
        FieldChange('mail', after: built.mail),
      ],
    );
  }

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final built = _build();

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        smartschool: built,
      );
    }

    try {
      final password = config.newAccountPassword();
      final ok = await _requireSmartschool(connectors).saveAccount(
        built,
        password: password,
      );
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool saveAccount returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: built,
        generatedPassword: password,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

/// Delete a Smartschool account whose staff member exists in neither WISA nor
/// Azure. Ported from `Action\StaffAccount\RemoveFromSmartschool`.
class RemoveStaffFromSmartschool extends StaffAction {
  const RemoveStaffFromSmartschool(super.staff, super.config);

  @override
  bool evaluate() =>
      staff.wisa == null && staff.azure == null && staff.smartschool != null;

  @override
  ChangeSet describeChanges() => const ChangeSet(
        system: Origin.smartschool,
        summary: 'Verwijder dit account uit Smartschool',
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        removed: true,
      );
    }

    try {
      final ok = await _requireSmartschool(connectors).deleteUser(
        _ss.uid,
        officialDate: options.deletionDate,
      );
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool deleteUser returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        removed: true,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

/// Delete an Azure-only account for a staff member absent from WISA and
/// Smartschool. Ported from `Action\StaffAccount\RemoveFromAzure` — which, like
/// legacy, gates only on system presence (the linker already restricts a
/// [LinkedStaff]'s Azure record to one belonging to the school, INV-22).
class RemoveStaffFromAzure extends StaffAction {
  const RemoveStaffFromAzure(super.staff, super.config);

  @override
  bool evaluate() =>
      staff.wisa == null && staff.smartschool == null && staff.azure != null;

  @override
  ChangeSet describeChanges() => const ChangeSet(
        system: Origin.azure,
        summary: 'Verwijder Azure account',
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        removed: true,
      );
    }

    try {
      await _requireAzure(connectors).users.deleteUser(_az.id);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        removed: true,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }
}

/// Stop importing a staff member from WISA. Ported from
/// `Action\StaffAccount\DontImportFromWisa`: the member exists in WISA but not
/// Smartschool, and the operator judges they are no longer in service, so a
/// [wapi.DontImportUserFromWisa] rule is added keyed on the WISA code.
///
/// Unlike the other actions this writes nothing: WISA is read-only, so [apply]
/// returns the rule via [ActionResult.wisaRule] for the State layer to add to
/// its import-rule set and re-sync (which drops the record next snapshot).
class DontImportStaffFromWisa extends StaffAction {
  const DontImportStaffFromWisa(super.staff, super.config);

  @override
  bool evaluate() => staff.wisa != null && staff.smartschool == null;

  wapi.DontImportUserFromWisa _rule() =>
      wapi.DontImportUserFromWisa(_wisa.code.value);

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.wisa,
        summary: 'Negeer dit account bij het importeren uit WISA',
        fields: [
          FieldChange('DontImportUserFromWisa', after: _wisa.code.value)
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    return ActionResult(
      outcome: options.dryRun ? ActionOutcome.dryRun : ActionOutcome.applied,
      changes: changes,
      system: Origin.wisa,
      wisaRule: _rule(),
    );
  }
}

// ---------------------------------------------------------------------------
// Modify actions — evaluated only when all three systems are present (§6.3).
// ---------------------------------------------------------------------------

/// Stamp the school prefix on a staff member's Azure `department` — the staff
/// counterpart of [ModifyAzureSchool], which the legacy family never had
/// (#233).
///
/// **Why the family needs one.** Students carry the school marker in
/// `companyName`; staff carry it in `department`. #231 taught the Azure pull to
/// adopt a moved staff member's existing account by `employeeId`, but nothing
/// then wrote our marker onto it, so the account stayed invisible to the
/// school-scoped bulk read (`UserManager.filterFor`'s
/// `startswith(department, <prefix>)` leg) and had to be re-adopted by the
/// back-fill on *every* pass. Worse, once the member leaves WISA their id drops
/// out of `managedStaffEmployeeIds`, the back-fill stops asking, and the account
/// goes invisible for good — no `RemoveStaffFromAzure` is ever proposed. Setting
/// the field is what makes the adoption stick.
///
/// **Trigger.** A `department` that does not *start with* the prefix — a
/// **missing** one included, exactly as #224 taught [ModifyAzureSchool] to treat
/// a null `companyName`. `startswith` (not the linker's laxer `contains`) is the
/// criterion on purpose: it is precisely the server-side test the next bulk read
/// applies, so one apply is guaranteed to make the account visible on its own.
///
/// **What it writes — an assumption worth stating.** Staff `department` values
/// in real data carry a suffix (`Arcadia - Wiskunde`) where a student's
/// `companyName` is flat, so overwriting the field with the bare prefix would
/// discard whatever the other school wrote there. This action assumes the shape
/// `<school>` or `<school> - <suffix>` and replaces **only** the leading school
/// segment, preserving the rest: `OTHER - Wiskunde` → `<prefix> - Wiskunde`, a
/// bare `OTHER` → `<prefix>`, and an unset field → `<prefix>` (what
/// [AddStaffToAzure] writes on create). The legacy staff `RemoveFromAzure`
/// renders this field under a **"Active Schools"** header and both linkers test
/// it with `contains`, which hints it might instead enumerate several schools —
/// in which case replacing the head segment evicts a sibling school's claim and
/// this is the line to revisit. Filed as #237; nothing in either codebase ever
/// writes such a value today.
class ModifyStaffAzureSchool extends StaffAction {
  const ModifyStaffAzureSchool(super.staff, super.config);

  /// The repaired `department`: our prefix, plus whatever the field already
  /// carried after the first ` - `.
  String get _department =>
      _withSchoolPrefix(_az.department, config.schoolPrefix);

  @override
  bool evaluate() {
    final prefix = _n(config.schoolPrefix);
    // No prefix configured: there is nothing to stamp, and blanking the field
    // would only make the account less findable than it already is.
    if (prefix == null) return false;
    final department = _n(_az.department);
    return department == null || !department.startsWith(prefix);
  }

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Wijzig de school in Azure',
        fields: [
          FieldChange(
            'department',
            before: _az.department,
            after: _department,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) {
    final department = _department;
    return _azurePatch(
      connectors,
      options,
      describeChanges(),
      (users) => users.updateUser(_az.id, department: department),
      () => _az.copyWith(department: department),
    );
  }
}

/// Correct the Smartschool internal number to equal the WISA staff
/// [wapi.WisaStaff.code] (staff bridge to Smartschool, spec §4). Ported from
/// `Action\StaffAccount\UpdateWisaName`.
class UpdateStaffWisaName extends StaffAction {
  const UpdateStaffWisaName(super.staff, super.config);

  @override
  bool evaluate() =>
      _wisa.code.value.trim().toLowerCase() !=
      _ss.accountId.trim().toLowerCase();

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig het WISA ID in Smartschool',
        fields: [
          FieldChange(
            'accountId',
            before: _ss.accountId,
            after: _wisa.code.value,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final updated = _ss.copyWith(accountId: _wisa.code.value);

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        smartschool: updated,
      );
    }

    try {
      final ok = await _requireSmartschool(connectors)
          .changeAccountId(_ss.uid, _wisa.code.value);
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool changeAccountId returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: updated,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

/// Sync the Smartschool mail to the Azure UPN, but only when Smartschool still
/// holds a base-domain address. Ported from
/// `Action\StaffAccount\ModifySmartschoolStaffEmail`.
class ModifySmartschoolStaffEmail extends StaffAction {
  const ModifySmartschoolStaffEmail(super.staff, super.config);

  @override
  bool evaluate() =>
      _domainOf(_ss.mail) == config.azureDomain.toLowerCase() &&
      !_eq(_ss.mail, _az.upn);

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig het e-mailadres in Smartschool',
        fields: [FieldChange('mail', before: _ss.mail, after: _az.upn)],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _smartschoolSave(
        connectors,
        options,
        describeChanges(),
        _ss.copyWith(mail: _az.upn),
      );
}

/// Sync the Smartschool copy-code (photocopier PIN) to the WISA `wisaId`.
/// Ported from `Action\StaffAccount\SetCopyCode`: the code is stored both in
/// the account's `fax` field and in the `PINCODE CANON` user parameter, and is
/// left-padded with zeros to at least four digits.
///
/// **Divergence from legacy.** Legacy compares the *padded* code against `fax`
/// but writes the *unpadded* `wisaId`, so a sub-4-digit id makes the action
/// re-trigger forever (it never converges). We write the padded code to both
/// targets so the action is idempotent — apply once, and `evaluate` is false
/// thereafter.
class SetStaffCopyCode extends StaffAction {
  const SetStaffCopyCode(super.staff, super.config);

  String get _code => _copyCode(_wisa.wisaId?.value);

  @override
  bool evaluate() => _code != _ss.fax;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig de kopie code in Smartschool',
        fields: [FieldChange('fax', before: _ss.fax, after: _code)],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final code = _code;
    final updated = _ss.copyWith(fax: code);

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        smartschool: updated,
      );
    }

    try {
      final smartschool = _requireSmartschool(connectors);
      // An empty password leaves the holder's existing password unchanged.
      final saved = await smartschool.saveAccount(updated, password: '');
      if (!saved) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool saveAccount returned failure'),
        );
      }
      final pinOk = await smartschool.saveUserParameter(
        updated.uid,
        _pincodeParameter,
        code,
      );
      if (!pinOk) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool saveUserParameter returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: updated,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

// ---------------------------------------------------------------------------
// Shared apply helpers for the modify actions.
// ---------------------------------------------------------------------------

extension _AzurePatch on StaffAction {
  /// Runs an Azure PATCH ([write]) unless dry-run, and returns the projected
  /// [record] as the mutated source record.
  Future<ActionResult> _azurePatch(
    Connectors connectors,
    ApplyOptions options,
    ChangeSet changes,
    Future<void> Function(az.UserManager users) write,
    az.AzureUser Function() record,
  ) async {
    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        azure: record(),
      );
    }
    try {
      await write(_requireAzure(connectors).users);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        azure: record(),
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }
}

extension _SmartschoolSave on StaffAction {
  /// Saves [updated] to Smartschool (`saveUser` with an unchanged password)
  /// unless dry-run, and returns [updated] as the mutated source record.
  Future<ActionResult> _smartschoolSave(
    Connectors connectors,
    ApplyOptions options,
    ChangeSet changes,
    ss.SmartschoolAccount updated,
  ) async {
    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        smartschool: updated,
      );
    }
    try {
      final ok = await _requireSmartschool(connectors)
          .saveAccount(updated, password: '');
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool saveAccount returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: updated,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

// ---------------------------------------------------------------------------
// Free helpers.
// ---------------------------------------------------------------------------

/// The Smartschool user parameter the copy-code (photocopier PIN) is stored
/// in, alongside the account's `fax` field. Legacy literal: `PINCODE CANON`.
const String _pincodeParameter = 'PINCODE CANON';

/// Left-pads [wisaId] with zeros to at least four digits — the canonical
/// copy-code form. Blank/null → `'0000'`.
String _copyCode(String? wisaId) {
  var code = wisaId ?? '';
  while (code.length < 4) {
    code = '0$code';
  }
  return code;
}

/// Separates the school segment of a staff `department` from the rest of the
/// value (`Arcadia - Wiskunde`). See [ModifyStaffAzureSchool] for the shape
/// this assumes.
const String _departmentSeparator = ' - ';

/// [department] with its leading school segment replaced by [schoolPrefix], the
/// suffix after the first [_departmentSeparator] preserved verbatim. A value
/// with no separator is all school segment, so it is replaced whole; a blank or
/// missing one becomes the bare prefix (what [AddStaffToAzure] writes on
/// create).
String _withSchoolPrefix(String? department, String schoolPrefix) {
  final current = department?.trim() ?? '';
  final at = current.indexOf(_departmentSeparator);
  return at < 0 ? schoolPrefix : '$schoolPrefix${current.substring(at)}';
}

/// Trims + lower-cases for case-insensitive comparison (INV-12); blank → null.
String? _n(String? v) {
  if (v == null) return null;
  final t = v.trim();
  return t.isEmpty ? null : t.toLowerCase();
}

/// Case-insensitive, trimmed equality (INV-12).
bool _eq(String? a, String? b) => _n(a) == _n(b);

/// The normalized domain of an email/UPN (`x.be` from `jane@X.BE`); '' if none.
String _domainOf(String mail) =>
    mail.contains('@') ? mail.split('@').last.trim().toLowerCase() : '';

/// A UPN-safe slug for the projected new-account UPN: lower-cased, keeping only
/// the characters Azure accepts in a local part. Approximates the connector's
/// own normalization for display/dry-run purposes.
String _slug(String input) => input
    .toLowerCase()
    .split('')
    .where((c) => RegExp(r'[a-z0-9_.+-]').hasMatch(c))
    .join();
