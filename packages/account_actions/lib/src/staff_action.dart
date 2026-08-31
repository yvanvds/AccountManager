import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'action_result.dart';
import 'apply_options.dart';
import 'change_set.dart';
import 'connectors.dart';
import 'staff_action_config.dart';
import 'staff_placement.dart';

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
/// **Office 365** group placement the legacy add-actions perform is out of
/// scope here (see the package README) — it needs a membership-aware input,
/// tracked as the `AddToAzureStaffGroup` / `AddToStaffGroup` follow-up. The
/// Smartschool one is not: since #374 [AddStaffToSmartschool] seats its new
/// account from an injected [StaffPlacement], which needs no membership at all.
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

  /// Whether this action's write is stamped with [ApplyOptions.deletionDate]
  /// (#394) — see [StudentAction.usesDeletionDate] for why the flag lives on the
  /// action rather than in the screen.
  ///
  /// One staff action carries it: [RemoveStaffFromSmartschool], whose `deleteUser`
  /// takes the official date. The staff *departure* is otherwise a
  /// [DeactivateStaffInSmartschool], which writes a status and no date at all.
  bool get usesDeletionDate => false;

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
/// as its `accountId` (spec §4) and the WISA `wisaId` as its copy-code (`fax`),
/// and the new account is then seated in [smartschoolStaffGroupName] and taken
/// out of the platform default group (#374, see [_seatNewAccount]).
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
  const AddStaffToSmartschool(super.staff, super.config, {this.placement});

  /// Where the freshly created account has to be seated (#374): the staff group
  /// to add it to and the platform default group to take it out of. `null`
  /// leaves the account exactly where `saveUser` put it — the behaviour every
  /// release before #374 had, kept as the no-context default so a headless
  /// caller or a test that is not about the seat reads unchanged.
  final StaffPlacement? placement;

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
      // The seat is best-effort, so it cannot change this action's outcome —
      // the create is the success criterion (INV-41), exactly as the student
      // create's class placement is. Each write that *did* land names its
      // group, so the State layer can splice the membership without a re-pull;
      // each one that did not says so in a warning.
      final seated = await _seatNewAccount(connectors, built);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: built,
        joinedGroup: seated.joined,
        leftGroup: seated.left,
        warnings: seated.warnings,
        generatedPassword: password,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }

  /// Seats a freshly created staff account (#374), mirroring the two follow-up
  /// writes legacy `AddToSmartschool.Apply` chains after its `Save`:
  ///
  /// ```csharp
  /// await GroupManager.AddUserToGroup(smartschool, Root.Find("Leerkrachten"));
  /// await GroupManager.RemoveUserFromGroup(smartschool, Root.Find("Leerlingen"));
  /// ```
  ///
  /// Both are unconditional plumbing rather than a decision: Smartschool seats
  /// **every** `saveUser` account in the platform default group, whatever role
  /// it carries, so a staff create has to add the staff group and leave the
  /// default one or the teacher lands in the student subtree — where the port
  /// has been putting every staff account it ever made, and where nothing later
  /// finds them. That is why the writes need no membership knowledge and were
  /// wrongly deferred with the genuinely membership-aware `AddToStaffGroup` /
  /// `AddToAzureStaffGroup` (see the README).
  ///
  /// **Best-effort, by design.** The create is this action's success criterion;
  /// a failed seat must not fail — and so retry — the create (INV-41), which
  /// would write `saveUser` a second time for an account that already exists.
  /// Legacy likewise logs and continues.
  ///
  /// **Every way a seat misses warns**, and here the student create's rule (only
  /// a *throw* warns, #343) does not carry over: a mis-placed student is
  /// re-caught next pass by `MoveToSmartschoolClassGroup`, whereas nothing at all
  /// re-examines a staff member's Smartschool group membership — a `LinkedStaff`
  /// does not carry it, so no action can propose the repair. A seat that misses
  /// here is a mis-seated account with no safety net, so the operator reads "the
  /// account was made, the group was not" for a refusal and an unresolved group
  /// just as much as for a throw.
  ///
  /// The two writes are independent: the removal is attempted even when the add
  /// missed, because leaving the account in the student subtree is the worse
  /// half of the same bug and the two failures have nothing to do with each
  /// other.
  Future<_SeatOutcome> _seatNewAccount(
    Connectors connectors,
    ss.SmartschoolAccount built,
  ) async {
    final placement = this.placement;
    if (placement == null) return const _SeatOutcome();

    final warnings = <String>[];
    final joined =
        await _joinStaffGroup(connectors, built, placement, warnings);
    final left =
        await _leaveDefaultGroup(connectors, built, placement, warnings);
    return _SeatOutcome(joined: joined, left: left, warnings: warnings);
  }

  /// Adds [built] to the staff group, returning it only when the write landed.
  ///
  /// `saveUserToClassesAndGroups` addresses a group by **code**, so an
  /// unresolved group cannot be written to at all — and an official one is
  /// refused by Smartschool (legacy guards it in `AddUserToGroup`; the ported
  /// connector leaves the guard to the caller, like `moveUserToClass`).
  Future<Group?> _joinStaffGroup(
    Connectors connectors,
    ss.SmartschoolAccount built,
    StaffPlacement placement,
    List<String> warnings,
  ) async {
    final target = placement.staffGroup;
    if (target == null) {
      warnings.add(
        'Het Smartschool-account is aangemaakt, maar de groep '
        '$smartschoolStaffGroupName is niet gevonden in Smartschool. Voeg het '
        'account daar handmatig aan toe.',
      );
      return null;
    }
    if (target.official) {
      warnings.add(
        'Het Smartschool-account is aangemaakt, maar ${target.name} is een '
        'officiële klas: accounts kunnen daar niet als groepslid aan '
        'toegevoegd worden. Voeg het account handmatig toe aan de juiste '
        'personeelsgroep.',
      );
      return null;
    }

    try {
      final ok = await _requireSmartschool(connectors)
          .addUserToGroup(built.uid, target.id.value);
      if (ok) return target;
      warnings.add(
        'Het Smartschool-account is aangemaakt, maar Smartschool weigerde het '
        'toe te voegen aan ${target.name}. Voeg het account daar handmatig aan '
        'toe.',
      );
    } on Object catch (e) {
      warnings.add(
        'Het Smartschool-account is aangemaakt, maar het toevoegen aan '
        '${target.name} is mislukt: $e. Voeg het account daar handmatig aan '
        'toe.',
      );
    }
    return null;
  }

  /// Removes [built] from the platform default group, returning the group whose
  /// local membership row the State layer may drop.
  ///
  /// `removeUserFromGroup` addresses a group by **name**, so this write does not
  /// need the group to be in the snapshot — the account is seated there by
  /// Smartschool itself whether our root-scoped pull saw the node or not. The
  /// resolved node only decides whether there is a local row to splice away, so
  /// a successful removal against an unresolved group names nothing and is not
  /// a warning either.
  Future<Group?> _leaveDefaultGroup(
    Connectors connectors,
    ss.SmartschoolAccount built,
    StaffPlacement placement,
    List<String> warnings,
  ) async {
    final name = placement.defaultGroupName;
    final resolved = placement.defaultGroup;
    if (resolved != null && resolved.official) {
      warnings.add(
        'Het Smartschool-account is aangemaakt, maar $name is een officiële '
        'klas: leden kunnen daar niet uit verwijderd worden.',
      );
      return null;
    }

    try {
      // Legacy stamps the removal with the moment of the write
      // (`GroupManager.RemoveUserFromGroup`); the date carries no meaning for a
      // non-official group, but the API requires one.
      //
      // Deliberately **not** `options.deletionDate` (#394). That date is the
      // uitschrijvingsdatum — the day a person officially left — and this is a
      // membership end inside a provisioning chain: the account is being
      // *created*, and it is leaving the platform's own default group on the way
      // in. Feeding one into the other would let a remembered departure date
      // from an end-of-year batch stamp a new colleague's account creation, and
      // there is no reading of that date under which "now" is the wrong answer
      // here. So `now` stays, and the two dates stay separate.
      final ok = await _requireSmartschool(connectors)
          .removeUserFromGroup(built.uid, name, DateTime.now());
      if (ok) return resolved;
      warnings.add(
        'Het Smartschool-account is aangemaakt, maar Smartschool weigerde het '
        'uit de groep $name te verwijderen. Verwijder het account daar '
        'handmatig uit.',
      );
    } on Object catch (e) {
      warnings.add(
        'Het Smartschool-account is aangemaakt, maar het verwijderen uit de '
        'groep $name is mislukt: $e. Verwijder het account daar handmatig uit.',
      );
    }
    return null;
  }
}

/// What [AddStaffToSmartschool]'s best-effort seat step ended up doing (#374):
/// the groups it demonstrably joined and left, plus the operator-facing notes
/// the caller must not drop.
///
/// The staff twin of the student create's placement outcome, with two groups
/// rather than one class because the seat is two independent writes.
class _SeatOutcome {
  const _SeatOutcome({
    this.joined,
    this.left,
    this.warnings = const <String>[],
  });

  /// The staff group the account was actually added to, or null for every way
  /// the add declined, was refused, or threw.
  final Group? joined;

  /// The default group the account was actually removed from **and** whose node
  /// the snapshot in hand carries — null when the removal missed, and also when
  /// it landed against a group our pull never saw (there is no row to drop).
  final Group? left;

  /// Reasons a seat did not land that the operator must still see, since
  /// nothing downstream re-proposes a staff group placement.
  final List<String> warnings;
}

/// The [StaffAction.alternativeGroup] key shared by the two mutually exclusive
/// resolutions of a departed staff member's Smartschool account (#349):
/// [DeactivateStaffInSmartschool] (keep, the default) and
/// [RemoveStaffFromSmartschool] (delete).
///
/// The staff twin of [smartschoolDepartureAlternative], and it takes the same
/// polarity for the same reason: the conservative option leads. A teacher who
/// stops working here is not the same event as a teacher who must be erased —
/// their account may hold course material, and they may be back next term — so
/// one click deactivates and erasing stays a decision somebody has to take on
/// purpose.
const String staffSmartschoolDepartureAlternative =
    'staff-smartschool-departure';

/// Deactivate — but keep — the Smartschool account of a staff member who has
/// left our school (#349): the conservative half of
/// [staffSmartschoolDepartureAlternative], and the staff analogue of
/// [UnregisterStudentFromSmartschool].
///
/// Smartschool's staff-side equivalent of the student `unregisterStudent` is
/// `setAccountStatus`, which is what this writes.
///
/// **Why the result reports [ActionResult.removed].** The account is *not*
/// deleted — that is the whole point of preferring this to
/// [RemoveStaffFromSmartschool] — but the Smartschool connector drops every
/// account whose status is `uitgeschakeld` at snapshot construction
/// (`connector.dart`, the legacy `Group.cs:400` filter), so the very next pull
/// will not contain this record. Reporting it as gone from the *snapshot* is
/// what keeps the local patch honest: the alternative is an in-memory view that
/// carries a record the next sync silently drops, which is the drift
/// `_applyWisaRule` exists to avoid on the WISA side.
class DeactivateStaffInSmartschool extends StaffAction {
  const DeactivateStaffInSmartschool(super.staff, super.config);

  @override
  bool evaluate() =>
      staff.hasLeftOurSchool &&
      staff.smartschool != null &&
      _ss.status == 'actief';

  @override
  String? get alternativeGroup => staffSmartschoolDepartureAlternative;

  /// Keeping the account is the conservative resolution, so it leads.
  @override
  bool get isDefaultAlternative => true;

  /// Releasing the Office 365 account is the other half of the same departure
  /// (#349), so it rides along rather than waiting for the operator to notice it
  /// on the next pass — the retirement twin of [AddStaffToAzure]'s provisioning
  /// chain. Which of the two Azure actions applies is decided by the
  /// `department` list, and the applier takes whichever the freshly relinked
  /// record's own dispatch offers.
  @override
  Set<Type> get unlocks =>
      const {ReleaseStaffFromAzureSchool, RemoveStaffFromAzure};

  /// So one confirmed apply reaches Office 365 as well, and says so (#234).
  @override
  Set<Origin> get unlockedSystems => const {Origin.azure};

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Schakel het Smartschool account uit',
        fields: [
          FieldChange('status', before: _ss.status, after: ss.disabledStatus),
        ],
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
      final ok = await _requireSmartschool(connectors)
          .setAccountStatus(_ss.uid, AccountState.inactive);
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool setAccountStatus returned failure'),
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

/// Delete the Smartschool account of a staff member who has left our school.
/// Ported from `Action\StaffAccount\RemoveFromSmartschool`.
///
/// **The gate widened in #349.** It used to demand `wisa == null && azure ==
/// null`, which meant a departed teacher still holding an Office 365 account was
/// offered nothing at all: this action wanted the Azure record gone and
/// [RemoveStaffFromAzure] wanted the Smartschool record gone, so neither could
/// ever fire. Keying on [LinkedStaff.hasLeftOurSchool] instead — exactly as
/// [DeleteStudentFromSmartschool] does — is what makes a staff departure
/// expressible at all. The two systems are then cleaned in order rather than
/// waiting for each other.
class RemoveStaffFromSmartschool extends StaffAction {
  const RemoveStaffFromSmartschool(super.staff, super.config);

  @override
  bool evaluate() => staff.hasLeftOurSchool && staff.smartschool != null;

  /// The destructive half of [staffSmartschoolDepartureAlternative] (#349), so
  /// it is never the default: an operator has to pick it.
  @override
  String? get alternativeGroup => staffSmartschoolDepartureAlternative;

  /// Deleting an account is judgement work, one record at a time — the same line
  /// legacy drew, and the reason [RetireStaffMember] carries no bulk grant
  /// either.
  @override
  bool get canApplyToAll => false;

  /// The staff counterpart of the student delete (#394): `deleteUser` records an
  /// official date, and the operator's answer belongs on it rather than the
  /// moment they pressed the button.
  @override
  bool get usesDeletionDate => true;

  /// Same chain as the conservative half: the Office 365 side of the departure
  /// follows the Smartschool side (#349).
  @override
  Set<Type> get unlocks =>
      const {ReleaseStaffFromAzureSchool, RemoveStaffFromAzure};

  @override
  Set<Origin> get unlockedSystems => const {Origin.azure};

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

/// What the two Azure departure actions split on (#349): who, besides us, still
/// has a claim on a departed staff member's Office 365 account.
///
/// **Both sources are asked, and neither is sufficient alone.**
///
/// - `department` — the comma list other software maintains — is the only thing
///   that survives a [wapi.DontImportUserFromWisa] rule. The rule is keyed on
///   the staff code and applied at snapshot construction, so it drops the member
///   from *every* group school's rows at once: after one has been written,
///   [LinkedStaff.hasLeftGroup] reads true even for a teacher a sibling school
///   genuinely still employs. Deleting on WISA presence alone would destroy that
///   school's account.
/// - [LinkedStaff.hasLeftGroup] is the only thing that catches the *opposite*
///   error. `department` is neither ours to write nor guaranteed current
///   (#237), so a teacher who moved to a sibling school last term may still be
///   listed under our prefix alone — and deleting on the list alone would then
///   destroy the account of somebody WISA can see is still employed by the
///   group. That is exactly the loss #340 kept the group-wide staff pull for.
///
/// So an account may be deleted only when **nothing** claims it: WISA has no row
/// for the person anywhere in the group, and the list names no school but ours.
/// Anything less is a release — our entry struck out, the account left standing.
///
/// [_listNamesUs] is asked from both directions (#373): the release strikes our
/// entry only when it is there, and [ClaimStaffForAzureSchool] appends it only
/// when it is not. One definition, so the two can never both fire — or both
/// decline — on the same list.
extension _DepartmentClaims on StaffAction {
  /// The other group schools the `department` list names.
  List<String> get _otherSchools =>
      departmentSchoolsExcept(_az.department, config.schoolPrefix);

  /// Whether the list names *us* — an exact list-item match
  /// ([departmentSchoolsExcept]), never the substring test the read side uses.
  /// False for a blank or absent `department`, which nobody has maintained.
  ///
  /// For a departure it answers "is there a claim of ours left to strike"; for
  /// [ClaimStaffForAzureSchool] it answers "are we already in the list".
  bool get _listNamesUs =>
      departmentSchools(_az.department).length != _otherSchools.length;

  /// Whether the account is ours alone — nobody else in the group has a claim on
  /// it, by either signal — and may therefore be deleted rather than released.
  bool get _accountIsOursAlone => staff.hasLeftGroup && _otherSchools.isEmpty;
}

/// Release a departed staff member from **our** school by striking our prefix
/// out of the Azure `department` list, leaving the account itself alone (#349).
/// Fires whenever the list still carries a claim of ours and the account is not
/// ours alone to delete — see [_DepartmentClaims]. Striking our only entry leaves
/// the field empty, which is the correct statement about an account no school of
/// ours has a claim on any more.
///
/// **The one edit to `department` we are entitled to make.** #237 removed
/// `ModifyStaffAzureSchool` because it *rewrote* the field — it fired for every
/// teacher whose list merely names us second, and its repair collapsed
/// `GBS,SSM` to a bare `SSM`, destroying a sibling school's claim in a field
/// other software maintains. Striking our own entry is the opposite operation:
/// it is subtractive, it is scoped to a member who has demonstrably left us, and
/// every other entry survives verbatim, in place. The removal is an exact list
/// match ([departmentSchoolsExcept]) rather than the substring test the *read*
/// side uses, so a longer school code that merely contains our prefix cannot be
/// struck by accident.
///
/// After it lands, the Azure bulk read no longer matches this account for our
/// school, so the member drops out of our snapshot on the next pull — which is
/// the intended end state, and why the action is self-cleaning rather than
/// something an operator has to remember to undo.
class ReleaseStaffFromAzureSchool extends StaffAction {
  const ReleaseStaffFromAzureSchool(super.staff, super.config);

  /// Fires whenever there is a claim of ours to strike and the account is not
  /// ours alone — the complement of [RemoveStaffFromAzure], so exactly one of
  /// the two is ever offered.
  @override
  bool evaluate() =>
      staff.hasLeftOurSchool &&
      staff.azure != null &&
      _listNamesUs &&
      !_accountIsOursAlone;

  /// Never in bulk: a departure is read and recognised one name at a time
  /// (#349). See [RetireStaffMember].
  @override
  bool get canApplyToAll => false;

  String get _remaining => _otherSchools.join(',');

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Haal onze school uit het Office 365 account',
        fields: [
          FieldChange(
            'department',
            before: _az.department,
            after: _remaining,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final remaining = _remaining;
    final updated = _az.copyWith(department: remaining);

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        azure: updated,
      );
    }

    try {
      await _requireAzure(connectors)
          .users
          .updateUser(_az.id, department: remaining);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        azure: updated,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }
}

/// Delete the Office 365 account of a departed staff member no other group
/// school claims. Ported from `Action\StaffAccount\RemoveFromAzure`.
///
/// **The gate changed shape in #349.** It used to be `wisa == null &&
/// smartschool == null`, which deadlocked against
/// [RemoveStaffFromSmartschool] (see there) and, worse, said nothing about the
/// sibling schools: a teacher the group still employs elsewhere could reach it
/// through their Smartschool account being removed first. It now asks the two
/// questions that actually matter — have they left *us*
/// ([LinkedStaff.hasLeftOurSchool]), and is the account ours alone
/// ([_DepartmentClaims._accountIsOursAlone]) — and defers to
/// [ReleaseStaffFromAzureSchool] whenever anybody else has a claim.
class RemoveStaffFromAzure extends StaffAction {
  const RemoveStaffFromAzure(super.staff, super.config);

  @override
  bool evaluate() =>
      staff.hasLeftOurSchool && staff.azure != null && _accountIsOursAlone;

  /// Never in bulk (#349) — and this one deletes.
  @override
  bool get canApplyToAll => false;

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
/// its import-rule set and filter its snapshot by (which drops the record on
/// the spot, with no re-pull — #345).
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

/// Retire a staff member WISA still reports as employed — the "medewerker uit
/// dienst" command (#349).
///
/// **Why this exists.** WISA's `SmaSyncPer` carries no employment-status column;
/// whether somebody is in *actief dienstverband* is decided server-side from the
/// werkdatum. When HR leaves a dienstverband open for a teacher who will not be
/// hired again — the standing reality this was built for, not an edge case —
/// they arrive in every pull forever and no state-derived action can tell that
/// they are gone. This is the operator saying so.
///
/// **It writes the import rule, and the rule is the load-bearing half.** Deleting
/// the accounts on their own would not survive the next sync: the record would
/// go back to `wisa != null, smartschool == null, azure == null`, which is
/// exactly [AddStaffToAzure] — the *default* alternative of
/// [staffImportAlternative], and bulk-applyable — so the next "Toepassen op
/// alle" would re-create the accounts that had just been removed and chain the
/// Smartschool create in behind them. The [wapi.DontImportUserFromWisa] rule is
/// what stops that loop, and (through the caller, #276/#285) it is also the
/// standing record of who decided this and when.
///
/// **It is deliberately not dispatched.** [staffActionsFor] never returns it, so
/// nobody employed here gains a standing destructive to-do and no pending count
/// moves. Dispatch (§6.3) is a pure function of the record as it stands, and
/// "this person is not coming back" is not in the record — it is a judgement
/// only an operator holds. So the UI constructs this action for the one staff
/// member on screen and hands it straight to the applier.
///
/// **One record, never a cohort.** [canApplyToAll] is false and there is no path
/// that could bulk it: a departure has to be read, the name recognised, and the
/// case judged on its own. That is the safety property the command is designed
/// around, not an incidental default.
///
/// Like [DontImportStaffFromWisa] it writes nothing itself — WISA is read-only —
/// and hands the rule back via [ActionResult.wisaRule]. The two produce the same
/// rule and stay separate on purpose: that one is an *alternative* inside the
/// import choice for a member with no Smartschool account (#248), offered by the
/// dispatch and answering "provision or ignore"; this one is a command that
/// opens a departure and pulls the account cleanup along behind it.
class RetireStaffMember extends StaffAction {
  const RetireStaffMember(super.staff, super.config);

  /// True for any staff member WISA still lists. Once the rule has landed they
  /// are an ordinary departed record and the dispatch offers the removals
  /// directly, so there is nothing left for this command to open.
  @override
  bool evaluate() => staff.wisa != null;

  /// Never in bulk — see the class doc. This is the flag that keeps the command
  /// out of "Toepassen op alle" and out of every cohort the Acties screen can
  /// arm.
  @override
  bool get canApplyToAll => false;

  /// The cleanup the rule opens, in the order it has to happen: Smartschool
  /// first (its `mail` is the Azure UPN, so releasing Office 365 first would
  /// leave it dangling), then whichever Azure action the `department` list calls
  /// for. The applier takes each link off the freshly relinked record's own
  /// dispatch, so the conservative Smartschool half leads and the operator's one
  /// confirmation performs the whole retirement.
  @override
  Set<Type> get unlocks => const {
        DeactivateStaffInSmartschool,
        RemoveStaffFromSmartschool,
        ReleaseStaffFromAzureSchool,
        RemoveStaffFromAzure,
      };

  /// So the confirmation names both systems this one click reaches (#234).
  @override
  Set<Origin> get unlockedSystems => const {Origin.smartschool, Origin.azure};

  wapi.DontImportUserFromWisa _rule() =>
      wapi.DontImportUserFromWisa(_wisa.code.value);

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.wisa,
        summary: 'Medewerker uit dienst — negeer dit account bij het '
            'importeren uit WISA',
        fields: [
          FieldChange('DontImportUserFromWisa', after: _wisa.code.value),
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

// There is deliberately **no** staff `department` *repair* here (#237), and
// there must never be one. A staff member's `department` is not ours to own: it
// is maintained by other software as a comma-separated list of the school
// prefixes the teacher is currently active at (`GBS,SSM`), and the linker's
// `contains` test (INV-22) is the only thing we read out of it.
//
// The `ModifyStaffAzureSchool` action added in #233 rewrote it, and both halves
// were wrong. It fired whenever `department` did not *start with* our prefix,
// so it fired for every teacher whose list merely names us second — an ordinary
// state, not an edge case. And its repair looked for a ` - ` separator that a
// comma list does not contain, so applying it collapsed `GBS,SSM` to a bare
// `SSM` and silently destroyed the sibling school's claim in a field we do not
// own. Removed whole rather than narrowed.
//
// What *is* admissible is an edit scoped to **our own entry**, leaving every
// other entry verbatim and in place, matched as an exact list item rather than
// by the substring test the read side uses. #349 established that shape
// subtractively with [ReleaseStaffFromAzureSchool]; [ClaimStaffForAzureSchool]
// below is the same operation with the sign flipped (#373). Neither is a repair
// of the list, and neither may grow into one.
//
// [AddStaffToAzure] still writes the bare prefix when it *creates* an account,
// which cannot destroy anything — the account, and therefore the field, did not
// exist a moment earlier.
//
// The other real problem #233 was aimed at survives the removal and is tracked
// separately: the bulk read's `startswith(department, …)` leg misses staff whose
// list does not lead with us (#268), which the claim below makes rarer over time
// rather than by widening the `$filter`.

/// Claim an **adopted** staff member for our school by appending our prefix to
/// the Azure `department` list (#373) — the additive mirror of
/// [ReleaseStaffFromAzureSchool].
///
/// **The state it repairs.** A teacher who starts here while already holding an
/// Office 365 account from a sibling group school arrives with a `department`
/// that names that school and not us. The Azure bulk read's server-side
/// `$filter` (`companyName eq '<prefix>' or startswith(department,'<prefix>')`)
/// cannot see them at all, so they are only in the snapshot because the
/// `employeeId` back-fill (#231) adopts every staff member WISA lists — and the
/// back-fill is fed from the *current* WISA rows. The day WISA stops listing
/// them there is no id to back-fill from and no `department` naming us, so
/// [LinkedStaff.belongsToOurSchool] goes false and the account becomes invisible
/// to us — which is exactly when [RemoveStaffFromAzure] /
/// [ReleaseStaffFromAzureSchool] were supposed to clean it up. Claiming them now
/// is what keeps that cleanup reachable later.
///
/// **Why this is allowed to write `department` at all.** See the note above: it
/// touches our own item and nothing else, so `SBE` becomes `SBE,SSM`, `` becomes
/// `SSM`, and `GBS,SBE` becomes `GBS,SBE,SSM` — every sibling claim survives
/// verbatim and in order. It is not the #237 rewrite and must never become one.
///
/// **The "are we already listed" test is [_DepartmentClaims._listNamesUs]**, the
/// exact list-item match the release uses, deliberately *not*
/// [LinkedStaff.azureNamesOurSchool] — which is built from the read side's
/// `staffBelongsToSchool` substring test (INV-22). The two differ on exactly one
/// shape, a longer school code that merely contains our prefix (`SSMB`), and
/// there the substring answer is the wrong one: it would suppress a claim we do
/// not in fact hold, and leave the account unclaimed forever. Read-wide,
/// write-narrow is the same asymmetry [departmentSchoolsExcept] documents.
///
/// **A blank prefix claims nobody.** An unconfigured prefix would otherwise
/// append an empty item to every staff account in the tenant, and `''` is not a
/// school (INV-22's own rule).
class ClaimStaffForAzureSchool extends StaffAction {
  const ClaimStaffForAzureSchool(super.staff, super.config);

  /// True iff WISA places them in a school we manage, they hold an Office 365
  /// account, and the `department` list does not already name us.
  ///
  /// [LinkedStaff.isInOurWisa] rather than a bare `wisa != null`: a teacher WISA
  /// lists only at a sibling group school is not ours to claim, and the
  /// departure pair is what applies to them.
  @override
  bool evaluate() =>
      staff.isInOurWisa &&
      staff.azure != null &&
      config.schoolPrefix.trim().isNotEmpty &&
      !_listNamesUs;

  /// **Bulk-applyable** (#373), and the decision is deliberate.
  ///
  /// The cohort is real: an intake of new staff adopted from sibling group
  /// schools arrives together, at the start of a term, and every one of them is
  /// in the same unclaimed state for the same mechanical reason. Withholding the
  /// grant means the repair is never done, and the accounts stay one WISA pull
  /// away from invisible.
  ///
  /// Nothing about it is judgement work. WISA has already decided the person
  /// works here; this action only writes that decision into a field the read
  /// side needs it in. It destroys nothing — every existing entry survives — and
  /// it is exactly reversible by [ReleaseStaffFromAzureSchool], which is the
  /// action a mistaken claim raises on the very next pass.
  ///
  /// So it lands with [AddStaffToAzure], which already stamps the same prefix in
  /// bulk on a create, and not with the #349 pair, whose refusal is about a
  /// *departure* having to be read one name at a time — one of them deletes an
  /// account, and neither is triggered by a fact WISA states.
  @override
  bool get canApplyToAll => true;

  /// The existing entries verbatim and in order, with our prefix appended.
  ///
  /// Built from [departmentSchools], so the only normalisation is the one the
  /// release already performs: surrounding whitespace and empty items go, and
  /// every surviving entry keeps its own casing.
  String get _claimed => <String>[
        ...departmentSchools(_az.department),
        config.schoolPrefix.trim(),
      ].join(',');

  /// Shows the whole field before and after, not just our addition, so the
  /// operator can see the sibling claims survive the write (#352 makes the same
  /// list legible on the card).
  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Voeg onze school toe aan het Office 365 account',
        fields: [
          FieldChange(
            'department',
            before: _az.department,
            after: _claimed,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final claimed = _claimed;
    final updated = _az.copyWith(department: claimed);

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        azure: updated,
      );
    }

    try {
      await _requireAzure(connectors)
          .users
          .updateUser(_az.id, department: claimed);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        azure: updated,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
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

// The staff family has no shared Azure-PATCH helper. The two actions that do
// PATCH — `ReleaseStaffFromAzureSchool` (#349) and `ClaimStaffForAzureSchool`
// (#373) — write the one field `department` from a value each derives itself,
// so a helper would abstract over nothing; `RemoveStaffFromAzure` deletes rather
// than patches. The student family keeps its own `_azurePatch`.

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
