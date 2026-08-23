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
  /// situation (#110). `null` (the default) means the action stands on its own.
  /// The staff family's one key is [staffImportAlternative] (#248). See
  /// [StudentAction.alternativeGroup].
  ///
  /// **Every member of a group writes** (#329): an informational action states
  /// [noticeFor] instead and is context on a decision rather than one of its
  /// answers. [staffImportAlternative] is a genuine either/or — three real
  /// writes — and keeps its radios.
  String? get alternativeGroup => null;

  /// Whether this action is the default alternative within its
  /// [alternativeGroup]. Ignored when [alternativeGroup] is `null`.
  bool get isDefaultAlternative => false;

  /// The situation this **informational** action is context for (#329) — see
  /// [StudentAction.noticeFor]. No staff action carries one: every member of the
  /// family is applyable today.
  String? get noticeFor => null;

  /// Whether [apply] can perform a change. `false` for an informational action
  /// (the legacy `CanBeApplied == false` case): it surfaces a diagnosis but has
  /// no automated write, so calling [apply] throws. Every staff action is
  /// applyable today, so this is always `true`; the getter exists so the UI's
  /// apply affordance and the follow-up walk (#240) read the flag off the action
  /// for every family instead of assuming it for this one. See
  /// [StudentAction.canApply] and [GroupAction.canApply].
  bool get canApply => true;

  /// Whether this action may be written to **many** records in one pass (#293)
  /// — the staff half of [StudentAction.canApplyToAll], ported from legacy's
  /// `AccountAction.canBeAppliedToAll`
  /// (`Action\StaffAccount\AccountAction.cs:23`). Defaults to `false`; see
  /// [StudentAction.canApplyToAll] for why the flag lives on the action rather
  /// than in the screen, and for the line legacy drew between mechanical and
  /// judgement work.
  ///
  /// Legacy granted it to three staff actions. Two are ported and override this
  /// ([AddStaffToAzure], [ModifySmartschoolStaffEmail]); the third,
  /// `AddToStaffGroup`, is the Office 365 `-Personeel` placement this package
  /// still defers (see the README), so there is no Dart action to carry the
  /// grant yet.
  bool get canApplyToAll => false;

  /// The action types this one **unlocks** on the same target (#240) — the staff
  /// family's half of the chaining [StudentAction.unlocks] introduced for
  /// students (#230) and extended to class groups in #245, deliberately the same
  /// mechanism rather than a third one.
  ///
  /// Provisioning a brand-new staff member is a chain, not a single action: the
  /// Smartschool account is built with the Azure UPN as its `mail`, so
  /// [AddStaffToSmartschool] cannot even [evaluate] true until [AddStaffToAzure]
  /// has run. The dispatch (§6.3) is a pure function of the *current* record and
  /// can only ever offer the first link, which is why a WISA-only staff member
  /// used to be offered one create and the operator had to apply, notice the
  /// relink, and apply again.
  ///
  /// Declaring the follow-up here lets the State layer run it immediately
  /// against the **freshly relinked** record. It must be the relinked record and
  /// never a projection: `createPrincipalName` resolves a UPN collision by
  /// suffixing, so the UPN that actually landed can differ from the one
  /// [describeChanges] projected, and the Smartschool account would then carry
  /// the wrong `mail`.
  ///
  /// Pure and constant — it names what *may* follow, never what must: the
  /// follow-up's own [evaluate] still decides whether it applies, exactly as it
  /// would on the next sync.
  Set<Type> get unlocks => const {};

  /// The systems the [unlocks] chain would write to, beyond the one
  /// [describeChanges] already names (#234) — the staff half of
  /// [StudentAction.unlockedSystems], which documents why the UI cannot derive
  /// this from a pending action.
  Set<Origin> get unlockedSystems => const {};

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

/// The [StaffAction.alternativeGroup] key shared by the mutually exclusive
/// readings of a WISA staff member with no Smartschool account (#248): finish
/// provisioning them ([AddStaffToAzure] when the Office 365 account is still
/// missing, [AddStaffToSmartschool] once it exists) *or* stop importing them
/// ([DontImportStaffFromWisa]).
///
/// They are opposite decisions, so they are one choice and never two to-dos.
/// Both used to return `null`, so `_choicesFor` made each its own choice-of-one
/// and `applyEntry` ran every selected choice: one click on a newly hired
/// teacher created their Office 365 *and* Smartschool accounts (the #240 chain)
/// and then wrote a [wapi.DontImportUserFromWisa] rule on the very code it had
/// just provisioned. The rule set is persisted and re-applied on every WISA
/// pull, so the next sync dropped the staff member the operator had just
/// provisioned — and their fresh accounts went unmanaged.
///
/// The two create actions never fire together — [AddStaffToAzure] needs
/// `azure == null` and [AddStaffToSmartschool] needs `azure != null` — so all
/// three can share the single key and exactly one default is ever offered.
///
/// **The default is the create action**, the same polarity the group family's
/// [classImportAlternative] chose and deliberately the opposite of
/// [smartschoolDepartureAlternative], where the conservative "keep the account"
/// option leads. Provisioning a new hire is the normal operation; a
/// mis-defaulted bulk apply that silently blacklists a term's worth of new
/// staff — dropping them from the next snapshot entirely — is far worse than
/// one that creates their accounts.
///
/// The [AddStaffToAzure] → [AddStaffToSmartschool] chain of #240 is unaffected:
/// the applier's follow-up walk keys on [StaffAction.unlocks] and never reads
/// this, so the Azure create still pulls the Smartschool create in behind it.
/// The key matters for the Smartschool create in its *own* right — a record
/// that is already WISA + Azure (an account adopted by `employeeId`, #231, or a
/// chain whose second write failed) raises it beside the opt-out as the same
/// two contradictory to-dos.
const String staffImportAlternative = 'staff-import';

/// Create an Office 365 account for a staff member present in WISA but not
/// Azure. Ported from `Action\StaffAccount\AddToAzure` (the `-Personeel` group
/// placement is deferred — see the README).
class AddStaffToAzure extends StaffAction {
  const AddStaffToAzure(super.staff, super.config);

  @override
  bool evaluate() => staff.wisa != null && staff.azure == null;

  /// Creating the Office 365 account unlocks the Smartschool create, which
  /// needs the fresh UPN as the new account's `mail` (#240) — the staff twin of
  /// [AddStudentToAzure]'s chain (#230). Without it a new staff member's second
  /// create only appeared on the *next* pass, so Acties → Personeel never showed
  /// the full provisioning intent.
  @override
  Set<Type> get unlocks => const {AddStaffToSmartschool};

  /// That follow-up writes Smartschool, so one confirmed apply of this action
  /// reaches both systems and the confirmation dialog says both (#234).
  @override
  Set<Origin> get unlockedSystems => const {Origin.smartschool};

  /// Provisioning the staff member is the leading half of the
  /// [staffImportAlternative] choice (#248), and its **default**: hiring is the
  /// normal operation, so a bulk apply provisions rather than blacklists.
  @override
  String? get alternativeGroup => staffImportAlternative;

  @override
  bool get isDefaultAlternative => true;

  /// Provisioning goes in bulk (legacy `AddToAzure(…, true, true)`), the staff
  /// twin of [AddStudentToAzure]'s grant: a term's new hires arrive together.
  ///
  /// It is the applyable half of [staffImportAlternative], so a bulk pass only
  /// ever provisions — the opt-out beside it is not the default and is not
  /// bulk-applyable either, so no pass can blacklist a cohort of new staff.
  ///
  /// Its [unlocks] chain still runs per record, so the Smartschool create rides
  /// along even though [AddStaffToSmartschool] withholds the grant on its own:
  /// the chain is a consequence of *this* action being sanctioned, and the same
  /// two writes legacy performed.
  @override
  bool get canApplyToAll => true;

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
///
/// **Not bulk-applyable** (#293), deliberately unlike its student twin
/// [AddStudentToSmartschool]: legacy passed `AddToSmartschool(…, true, false)`
/// here and `(…, true, true)` there, the one place the two families disagree
/// about the same operation. The asymmetry is preserved rather than tidied — a
/// staff account raised on its own means the #240 chain did not carry it, so
/// something about that record is unusual and an operator should look. The
/// ordinary new-hire path is unaffected: [AddStaffToAzure] is bulk-applyable and
/// [unlocks] this create behind it, per record.
class AddStaffToSmartschool extends StaffAction {
  const AddStaffToSmartschool(super.staff, super.config);

  @override
  bool evaluate() =>
      staff.wisa != null && staff.azure != null && staff.smartschool == null;

  /// Once the Office 365 account exists this create stands in for
  /// [AddStaffToAzure] inside the [staffImportAlternative] choice (#248), and is
  /// the default in its place — the two are separated by the `azure == null`
  /// test, so exactly one default is ever offered. It needs the key in its own
  /// right: a record that is already WISA + Azure (adopted by `employeeId`
  /// (#231), or a #240 chain whose second write failed) raises this create and
  /// [DontImportStaffFromWisa] as the same pair of contradictory to-dos.
  @override
  String? get alternativeGroup => staffImportAlternative;

  @override
  bool get isDefaultAlternative => true;

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

  /// Blacklisting the staff member is one half of the [staffImportAlternative]
  /// choice (#248) — never a to-do beside the create it contradicts. It is not
  /// the default: an operator has to pick it.
  @override
  String? get alternativeGroup => staffImportAlternative;

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

// There is deliberately **no** staff `department` repair here (#237). A staff
// member's `department` is not ours to write: it is maintained by other
// software as a comma-separated list of the school prefixes the teacher is
// currently active at (`GBS,SSM`), and we only ever *read* it — the linker's
// `contains` test (INV-22) is the correct way to ask "is this teacher active at
// our school?".
//
// The `ModifyStaffAzureSchool` action added in #233 wrote it, and both halves
// were wrong. It fired whenever `department` did not *start with* our prefix,
// so it fired for every teacher whose list merely names us second — an ordinary
// state, not an edge case. And its repair looked for a ` - ` separator that a
// comma list does not contain, so applying it collapsed `GBS,SSM` to a bare
// `SSM` and silently destroyed the sibling school's claim in a field we do not
// own. Removed whole rather than narrowed: there is no value of this field we
// are entitled to write onto an account that already exists.
//
// [AddStaffToAzure] still writes the bare prefix when it *creates* an account,
// which cannot destroy anything — the account, and therefore the field, did not
// exist a moment earlier.
//
// The two real problems #233 was aimed at survive the removal and are tracked
// separately: the bulk read's `startswith(department, …)` leg misses staff
// whose list does not lead with us, and a staff member who leaves WISA drops
// out of the `employeeId` back-fill and so goes invisible instead of raising a
// [RemoveStaffFromAzure].

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

  /// Copying the Azure UPN down to Smartschool is mechanical, so it goes in bulk
  /// (legacy `ModifySmartschoolStaffEmail(…, true, true)`) — the staff twin of
  /// [ModifySmartschoolStudentEmail]'s grant.
  @override
  bool get canApplyToAll => true;

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

// The staff family has no Azure-PATCH helper: the only staff modify action that
// ever wrote to Azure was the `department` repair removed in #237, and
// `RemoveStaffFromAzure` deletes rather than patches. The student family keeps
// its own `_azurePatch`.

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
