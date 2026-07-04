import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'action_result.dart';
import 'apply_options.dart';
import 'change_set.dart';
import 'class_placement.dart';
import 'connectors.dart';
import 'student_action_config.dart';

/// The student action family (spec `docs/domain-model.md` §3.10). One subclass
/// per legacy `Action\StudentAccount\*` class.
///
/// **Target binding.** Each action is bound to the [LinkedAccount] it acts on
/// at construction. The spec draws the operations as `evaluate(account)` /
/// `describeChanges(account)` (§3.10) but applies as `apply(connectors,
/// options)` (§6.4, `apply(action, connectors, options)`); binding the target
/// reconciles the two — [evaluate] and [describeChanges] read the bound
/// [account] (exposed as [target]) and stay pure, while [apply] carries no
/// target of its own.
///
/// **Purity boundary (INV-40/41/42).** [evaluate] and [describeChanges] are
/// pure and deterministic — no I/O, no globals. [apply] is the only impure
/// operation; it is retry-safe (a transient failure returns
/// [ActionOutcome.failed] without corrupting state) and never mutates the
/// bound [account] or its snapshot records — every changed record is a fresh
/// copy.
sealed class StudentAction {
  /// The linked record this action targets, bound at construction.
  final LinkedAccount account;

  /// Injected configuration (domains, password/uid builders).
  final StudentActionConfig config;

  const StudentAction(this.account, this.config);

  /// Alias for the bound [account] — the "target" the spec's
  /// `evaluate(target)` refers to.
  LinkedAccount get target => account;

  /// Whether this action applies to [account]. Pure and deterministic
  /// (INV-40). The dispatcher constructs one instance per candidate type and
  /// keeps those returning true.
  bool evaluate();

  /// The field-level diff this action would make. Pure (INV-40); drives the
  /// diff UI and the dry-run path.
  ChangeSet describeChanges();

  /// The key shared by the mutually-exclusive alternatives that resolve the
  /// **same situation** (#110). Two actions bound to the same account that
  /// return the same non-null key are alternatives — the operator picks one and
  /// must never run both (e.g. unregister *vs* delete a departed student). A
  /// `null` key (the default) means the action stands on its own. Pure; lets the
  /// UI group alternatives without pattern-matching on concrete action types.
  String? get alternativeGroup => null;

  /// Within an [alternativeGroup], whether this action is the sensible default
  /// pre-selection. Exactly one alternative in a group should return `true`;
  /// ignored when [alternativeGroup] is `null`.
  bool get isDefaultAlternative => false;

  /// Performs the change on the target system. Impure. With
  /// [ApplyOptions.dryRun] set, performs **no** writes and returns the
  /// projected [ActionResult] (PAIN-3).
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options);

  // --- shared helpers -------------------------------------------------------

  wapi.WisaStudent get _wisa => account.wisa! as wapi.WisaStudent;
  ss.SmartschoolAccount get _ss =>
      account.smartschool! as ss.SmartschoolAccount;
  az.AzureUser get _az => account.azure! as az.AzureUser;

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

  /// Whether [group] is a valid `saveUserToClass` destination — an *official*
  /// class node (legacy `MoveUserToClass` guards `Type == Class && Official`;
  /// the ported `moveUserToClass` connector leaves that guard to the caller).
  bool _isOfficialClass(Group group) =>
      group.official && group.type == GroupType.classGroup;
}

/// The [StudentAction.alternativeGroup] key shared by the two mutually
/// exclusive resolutions of a WISA-departed Smartschool account (#110):
/// [UnregisterStudentFromSmartschool] (keep, the default) and
/// [DeleteStudentFromSmartschool] (remove).
const String smartschoolDepartureAlternative = 'smartschool-departure';

// ---------------------------------------------------------------------------
// Lifecycle actions — evaluated only when a system is missing (§6.3).
// ---------------------------------------------------------------------------

/// Create an Office 365 account for a student present in WISA but not Azure.
/// Ported from `Action\StudentAccount\AddToAzure`.
class AddStudentToAzure extends StudentAction {
  const AddStudentToAzure(super.account, super.config);

  @override
  bool evaluate() => account.wisa != null && account.azure == null;

  @override
  ChangeSet describeChanges() {
    final wisa = _wisa;
    final given = _givenName(wisa);
    return ChangeSet(
      system: Origin.azure,
      summary: 'Maak een nieuw Office 365 account',
      fields: [
        FieldChange(
          'userPrincipalName',
          after: _projectedUpn(given, wisa.name),
        ),
        FieldChange('displayName', after: wisa.fullName),
        FieldChange('employeeId', after: wisa.wisaId.value),
        FieldChange('companyName', after: config.schoolPrefix),
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
    final given = _givenName(wisa);

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        azure: az.AzureUser(
          id: '',
          upn: _projectedUpn(given, wisa.name),
          employeeId: wisa.wisaId.value,
          displayName: wisa.fullName,
          givenName: given,
          surname: wisa.name,
          companyName: config.schoolPrefix,
          department: wisa.classGroup,
        ),
      );
    }

    try {
      final users = _requireAzure(connectors).users;
      final upn = await users.createPrincipalName(
        given,
        wisa.name,
        config.azureDomain,
        isStudent: true,
      );
      final created = await users.createUser(
        userPrincipalName: upn,
        displayName: wisa.fullName,
        password: config.newAccountPassword(),
        givenName: given,
        surname: wisa.name,
        employeeId: wisa.wisaId.value,
        companyName: config.schoolPrefix,
        department: wisa.classGroup,
        forceChangePasswordNextSignIn: true,
      );
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        azure: created,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }

  String _projectedUpn(String given, String surname) =>
      '${_slug(given)}.${_slug(surname)}@${config.studentDomain}';
}

/// Create a Smartschool account for a student present in WISA and Azure but not
/// Smartschool. Ported from `Action\StudentAccount\AddToSmartschool` — the
/// account is built from the WISA record with the Azure UPN as its mail. When a
/// [ClassPlacement] is wired (#55), a successful create is followed by a
/// best-effort move into the student's class group; without one the account is
/// created but not placed (see [_placeNewAccount]).
class AddStudentToSmartschool extends StudentAction {
  /// The class-placement context (#55). When non-null, a successful create is
  /// followed by a best-effort move into the student's class group (legacy
  /// chained `MoveToSmartschoolClassGroup.Move` after the create). When null —
  /// the caller wired no membership context — the account is created but not
  /// placed, exactly as this action shipped in #46.
  final ClassPlacement? placement;

  const AddStudentToSmartschool(super.account, super.config, {this.placement});

  @override
  bool evaluate() =>
      account.wisa != null &&
      account.azure != null &&
      account.smartschool == null;

  ss.SmartschoolAccount _build() {
    final wisa = _wisa;
    return ss.SmartschoolAccount(
      uid: config.smartschoolUid(_givenName(wisa), wisa.name),
      accountId: wisa.wisaId.value,
      mail: _az.upn,
      registerId: wisa.nationalId,
      stemId: int.tryParse(wisa.stemId) ?? 0,
      role: PersonRole.student,
      givenName: wisa.firstName,
      surname: wisa.name,
      extraNames: '',
      initials: '',
      preferredName: wisa.preferredName,
      gender: wisa.gender,
      birthDate: wisa.birthDate,
      birthPlace: wisa.birthPlace,
      birthCountry: '',
      address: wisa.address,
      mobilePhone: '',
      homePhone: '',
      fax: '',
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
      final ok = await _requireSmartschool(connectors).saveAccount(
        built,
        password: config.newAccountPassword(),
      );
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool saveAccount returned failure'),
        );
      }
      await _placeNewAccount(connectors, built);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: built,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }

  /// Places a freshly created account into its class group (#55), mirroring the
  /// `MoveToSmartschoolClassGroup.Move` legacy chained after the create. The
  /// target is the "Leerlingen" root for the ANS/BNS classes and the WISA
  /// `classGroup` otherwise (legacy `AddToSmartschool.Add`).
  ///
  /// **Best-effort, by design.** The create is this action's success criterion;
  /// a failed placement must not fail (and so retry) the create (INV-41).
  /// Legacy likewise logs and continues. An unresolved or non-official target,
  /// or a failed move, is therefore silently tolerated here — a mis-placed
  /// *non*-ANS/BNS student is re-caught next pass by [MoveToSmartschoolClassGroup]
  /// once the account is complete, so only the (rare) ANS/BNS → "Leerlingen"
  /// case has no safety net. There is no log sink on this path.
  Future<void> _placeNewAccount(
    Connectors connectors,
    ss.SmartschoolAccount built,
  ) async {
    final placement = this.placement;
    if (placement == null) return;

    final classGroup = _wisa.classGroup;
    final targetName =
        (classGroup.contains('ANS') || classGroup.contains('BNS'))
            ? 'Leerlingen'
            : classGroup;
    final target = placement.resolveClass(targetName);
    if (target == null || !_isOfficialClass(target)) return;

    await _requireSmartschool(connectors)
        .moveUserToClass(built.uid, target.id.value, _wisa.classChange);
  }
}

/// Unregister (but keep) a still-active Smartschool account whose student has
/// left WISA. Ported from `Action\StudentAccount\UnregisterSmartschool`.
class UnregisterStudentFromSmartschool extends StudentAction {
  const UnregisterStudentFromSmartschool(super.account, super.config);

  @override
  bool evaluate() =>
      account.wisa == null &&
      account.smartschool != null &&
      _ss.status == 'actief';

  /// Unregister and [DeleteStudentFromSmartschool] are the two mutually
  /// exclusive resolutions of a WISA-departed Smartschool account (#110).
  @override
  String? get alternativeGroup => smartschoolDepartureAlternative;

  /// Unregistering keeps the account (the conservative resolution), so it is the
  /// pre-selected default of the departure choice.
  @override
  bool get isDefaultAlternative => true;

  @override
  ChangeSet describeChanges() => const ChangeSet(
        system: Origin.smartschool,
        summary: 'Schrijf de leerling uit in Smartschool',
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final account = _ss;

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        smartschool: account,
      );
    }

    try {
      final ok = await _requireSmartschool(connectors).unregisterStudent(
        account.uid,
        options.deletionDate ?? DateTime.now(),
      );
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool unregisterStudent returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: account,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

/// Delete a Smartschool account whose student no longer exists in WISA. Ported
/// from `Action\StudentAccount\DeleteFromSmartschool`.
class DeleteStudentFromSmartschool extends StudentAction {
  const DeleteStudentFromSmartschool(super.account, super.config);

  @override
  bool evaluate() => account.wisa == null && account.smartschool != null;

  /// Delete and [UnregisterStudentFromSmartschool] are the two mutually
  /// exclusive resolutions of a WISA-departed Smartschool account (#110). Delete
  /// is the destructive alternative, so it is not the default.
  @override
  String? get alternativeGroup => smartschoolDepartureAlternative;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: _ss.status == 'actief'
            ? 'Verwijder dit account uit Smartschool'
            : 'Verwijder dit account uit Smartschool (al uitgeschakeld)',
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

/// Delete an Azure-only account for a former student (no WISA, no Smartschool)
/// carrying the school's `companyName`. Ported from
/// `Action\StudentAccount\RemoveFromAzure`.
class RemoveStudentFromAzure extends StudentAction {
  const RemoveStudentFromAzure(super.account, super.config);

  @override
  bool evaluate() =>
      account.wisa == null &&
      account.smartschool == null &&
      account.azure != null &&
      _eq(_az.companyName, config.schoolPrefix);

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

// ---------------------------------------------------------------------------
// Modify actions — evaluated only when all three systems are present (§6.3).
// ---------------------------------------------------------------------------

/// Move a student's Azure UPN onto the student domain. Ported from
/// `Action\StudentAccount\ModifyAzureStudentEmail`.
class ModifyAzureStudentEmail extends StudentAction {
  const ModifyAzureStudentEmail(super.account, super.config);

  @override
  bool evaluate() {
    final upn = _n(_az.upn);
    return upn != null && !upn.endsWith(config.studentDomain.toLowerCase());
  }

  String get _newUpn => '${_localPart(_az.upn)}@${config.studentDomain}';

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Wijzig het e-mailadres in Azure',
        fields: [
          FieldChange('userPrincipalName', before: _az.upn, after: _newUpn),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _azurePatch(
        connectors,
        options,
        describeChanges(),
        (users) => users.updateUser(_az.id, userPrincipalName: _newUpn),
        () => _az.copyWith(upn: _newUpn),
      );
}

/// Sync a student's Azure display/given name from WISA. Ported from
/// `Action\StudentAccount\ModifyAzureName`.
class ModifyAzureName extends StudentAction {
  const ModifyAzureName(super.account, super.config);

  @override
  bool evaluate() => !_eq(_wisa.fullName, _az.displayName);

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Wijzig de naam in Azure',
        fields: [
          FieldChange(
            'displayName',
            before: _az.displayName,
            after: _wisa.fullName,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) {
    final wisa = _wisa;
    final given = _givenName(wisa);
    return _azurePatch(
      connectors,
      options,
      describeChanges(),
      (users) => users.updateUser(
        _az.id,
        displayName: wisa.fullName,
        givenName: given,
        surname: wisa.name,
      ),
      () => _az.copyWith(
        displayName: wisa.fullName,
        givenName: given,
        surname: wisa.name,
      ),
    );
  }
}

/// Correct a student's Azure `companyName` to the school prefix. Ported from
/// `Action\StudentAccount\ModifyAzureSchool`.
class ModifyAzureSchool extends StudentAction {
  const ModifyAzureSchool(super.account, super.config);

  @override
  bool evaluate() {
    final company = _az.companyName;
    return company != null && !_eq(company, config.schoolPrefix);
  }

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Wijzig de school in Azure',
        fields: [
          FieldChange(
            'companyName',
            before: _az.companyName,
            after: config.schoolPrefix,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _azurePatch(
        connectors,
        options,
        describeChanges(),
        (users) => users.updateUser(_az.id, companyName: config.schoolPrefix),
        () => _az.copyWith(companyName: config.schoolPrefix),
      );
}

/// Correct the Smartschool internal number to equal the WISA id. Ported from
/// `Action\StudentAccount\ModifyAccountID`.
class ModifyAccountId extends StudentAction {
  const ModifyAccountId(super.account, super.config);

  @override
  bool evaluate() => _wisa.wisaId.value.trim() != _ss.accountId.trim();

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig het intern nummer in Smartschool',
        fields: [
          FieldChange(
            'accountId',
            before: _ss.accountId,
            after: _wisa.wisaId.value,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final updated = _ss.copyWith(accountId: _wisa.wisaId.value);

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
          .changeAccountId(_ss.uid, _wisa.wisaId.value);
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
/// `Action\StudentAccount\ModifySmartschoolStudentEmail`.
class ModifySmartschoolStudentEmail extends StudentAction {
  const ModifySmartschoolStudentEmail(super.account, super.config);

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

/// Sync the Smartschool home address from WISA. Ported from
/// `Action\StudentAccount\ModifySmartschoolStudentAddress`.
class ModifySmartschoolStudentAddress extends StudentAction {
  const ModifySmartschoolStudentAddress(super.account, super.config);

  @override
  bool evaluate() => _ss.address != _wisa.address;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig het adres in Smartschool',
        fields: [
          FieldChange(
            'address',
            before: _ss.address.streetAddress,
            after: _wisa.address.streetAddress,
          ),
          FieldChange(
            'city',
            before: _ss.address.city,
            after: _wisa.address.city,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _smartschoolSave(
        connectors,
        options,
        describeChanges(),
        _ss.copyWith(address: _wisa.address),
      );
}

/// Sync the Smartschool stamboeknummer from WISA. Ported from
/// `Action\StudentAccount\ModifySmartschoolStemID`.
class ModifySmartschoolStemId extends StudentAction {
  const ModifySmartschoolStemId(super.account, super.config);

  int get _wisaStemId => int.tryParse(_wisa.stemId) ?? 0;

  @override
  bool evaluate() => _wisaStemId != _ss.stemId;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig het stamboeknummer in Smartschool',
        fields: [
          FieldChange('stemId', before: '${_ss.stemId}', after: '$_wisaStemId'),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _smartschoolSave(
        connectors,
        options,
        describeChanges(),
        _ss.copyWith(stemId: _wisaStemId),
      );
}

/// Sync the Smartschool birthplace from WISA. Ported from
/// `Action\StudentAccount\ModifySmartschoolBirthPlace`.
class ModifySmartschoolBirthPlace extends StudentAction {
  const ModifySmartschoolBirthPlace(super.account, super.config);

  @override
  bool evaluate() => !_eq(_ss.birthPlace, _wisa.birthPlace);

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig de geboorteplaats in Smartschool',
        fields: [
          FieldChange(
            'birthPlace',
            before: _ss.birthPlace,
            after: _wisa.birthPlace,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _smartschoolSave(
        connectors,
        options,
        describeChanges(),
        _ss.copyWith(birthPlace: _wisa.birthPlace),
      );
}

/// Sync the Smartschool preferred name ("Roepnaam") from WISA. Skipped when the
/// student has no distinct preferred name. Ported from
/// `Action\StudentAccount\ModifySmartschoolName`.
class ModifySmartschoolName extends StudentAction {
  const ModifySmartschoolName(super.account, super.config);

  @override
  bool evaluate() {
    final wisa = _wisa;
    if (wisa.firstName == wisa.preferredName) return false;
    return wisa.preferredName != _ss.preferredName;
  }

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig de roepnaam in Smartschool',
        fields: [
          FieldChange(
            'preferredName',
            before: _ss.preferredName,
            after: _wisa.preferredName,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _smartschoolSave(
        connectors,
        options,
        describeChanges(),
        _ss.copyWith(preferredName: _wisa.preferredName),
      );
}

/// Move a student into the official Smartschool class named by their WISA
/// class, when the two disagree (#55). Ported from
/// `Action\StudentAccount\MoveToSmartschoolClassGroup`.
///
/// This is the membership-dependent action #46 deferred: it reads the student's
/// current class and resolves the target class through the [ClassPlacement]
/// companion, neither of which a [LinkedAccount] carries. The ANS/BNS classes
/// are **excluded** here — legacy `Evaluate` skips them, so their placement
/// happens only at create time (see [AddStudentToSmartschool]).
class MoveToSmartschoolClassGroup extends StudentAction {
  /// The membership + group-tree context this action reads (#55).
  final ClassPlacement placement;

  const MoveToSmartschoolClassGroup(
    super.account,
    super.config,
    this.placement,
  );

  bool get _isAdultEducation {
    final classGroup = _wisa.classGroup;
    return classGroup.contains('ANS') || classGroup.contains('BNS');
  }

  @override
  bool evaluate() =>
      !_isAdultEducation && placement.className != placement.currentClassName;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Wijzig de klas in Smartschool',
        fields: [
          FieldChange(
            'class',
            before: placement.currentClassName,
            after: placement.className,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final account = _ss;

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        smartschool: account,
      );
    }

    final target = placement.resolveClass(placement.className);
    if (target == null) {
      return _failed(
        changes,
        Origin.smartschool,
        StateError(
          'Smartschool class "${placement.className}" does not exist',
        ),
      );
    }
    if (!_isOfficialClass(target)) {
      return _failed(
        changes,
        Origin.smartschool,
        StateError(
          'Cannot move ${account.uid} to "${target.name}": '
          'only official classes accept members',
        ),
      );
    }

    try {
      final ok = await _requireSmartschool(connectors).moveUserToClass(
        account.uid,
        target.id.value,
        _wisa.classChange,
      );
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool moveUserToClass returned failure'),
        );
      }
      // A move changes membership, not the account's own fields; the account
      // still exists, so the State layer keeps its record (and updates its
      // membership index from the target it built into [placement]).
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: account,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

// ---------------------------------------------------------------------------
// Shared apply helpers for the modify actions.
// ---------------------------------------------------------------------------

extension _AzurePatch on StudentAction {
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
      // An empty password leaves the holder's existing password unchanged.
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

String _givenName(wapi.WisaStudent wisa) =>
    wisa.preferredName.isNotEmpty ? wisa.preferredName : wisa.firstName;

/// Trims + lower-cases for case-insensitive comparison (INV-12); blank → null.
String? _n(String? v) {
  if (v == null) return null;
  final t = v.trim();
  return t.isEmpty ? null : t.toLowerCase();
}

/// Case-insensitive, trimmed equality (INV-12).
bool _eq(String? a, String? b) => _n(a) == _n(b);

/// The local part of an email/UPN (`jane.doe` from `jane.doe@x.be`).
String _localPart(String mail) =>
    mail.contains('@') ? mail.split('@').first : mail;

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
