import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'action_result.dart';
import 'apply_options.dart';
import 'azure_class_placement.dart';
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
  ///
  /// **Every member of a group writes** (#329). An informational action — one
  /// whose [canApply] is `false` — may never join one: "here is what is wrong,
  /// go fix it by hand" and "here is the one thing the app can do about it" are
  /// not comparable answers to a single question, and offering them as radios
  /// asked the operator to choose between a diagnosis and a resolution. Such an
  /// action declares [noticeFor] instead and rides along as context. A dispatch
  /// test pins the rule over all three families.
  String? get alternativeGroup => null;

  /// Within an [alternativeGroup], whether this action is the sensible default
  /// pre-selection. Exactly one alternative in a group should return `true`;
  /// ignored when [alternativeGroup] is `null`.
  bool get isDefaultAlternative => false;

  /// The situation this **informational** action is context for (#329) — the
  /// [alternativeGroup] key of the decision it belongs beside, or `null` (the
  /// default) when this action is not a notice.
  ///
  /// A notice is not a decision and never an option: the collapse
  /// ([collapseAlternatives]) lifts it out of the option list and hands it to
  /// the decision it names, which renders it as context above its own action —
  /// no radio, no apply button, still marked "(manueel)" so it stays scannable.
  ///
  /// Only ever non-null where [canApply] is `false`, and never together with a
  /// non-null [alternativeGroup]: a notice writes nothing, so it cannot be one
  /// of the things a decision picks between.
  ///
  /// No student action carries one today — the family's one informational
  /// member, [AzureClassGroupMembership], stands on its own rather than beside a
  /// decision — but the member lives here so the rule is stated once for all
  /// three families instead of in the family that happened to need it first.
  String? get noticeFor => null;

  /// Whether [apply] can perform a change. `false` for an informational action
  /// (the legacy `CanBeApplied == false` case): it surfaces a diagnosis on the
  /// account but has no automated write of its own, so calling [apply] throws.
  /// Callers (UI / State layer) gate the "apply" affordance on this.
  ///
  /// The whole legacy student family is applyable; [AzureClassGroupMembership]
  /// (#245) is the first member that is not, and it mirrors how the group family
  /// has carried informational members since #54.
  bool get canApply => true;

  /// Whether this action may be written to **many** records in one pass (#293)
  /// — the port of legacy's `AccountAction.canBeAppliedToAll`
  /// (`Action\StudentAccount\AccountAction.cs:22`), which defaulted to `false`
  /// and was granted action by action.
  ///
  /// Distinct from [canApply], which says whether the app can write the action
  /// *at all*. A bulk affordance needs both: [canApply] is the mechanism,
  /// [canApplyToAll] is the sanction. It is therefore never `true` where
  /// [canApply] is `false`, and a test pins that for all three families.
  ///
  /// **A property of the action, never a list of kinds held in the UI.** Such a
  /// list drifts from what the domain actually sanctions, and an action added
  /// later silently inherits whatever the list's default happened to be.
  /// Declared here, a new action is conservative until someone decides
  /// otherwise — which is the whole reason the default is `false`.
  ///
  /// The line legacy drew over a decade of use, and this port keeps: mechanical
  /// corrections and provisioning may go in bulk; **destructive** actions
  /// ([RemoveStudentFromAzure], [DeleteStudentFromSmartschool],
  /// [UnregisterStudentFromSmartschool]) and **judgement** actions — the name
  /// and address modifiers, where the operator is meant to look at the record —
  /// never do.
  bool get canApplyToAll => false;

  /// Whether this action's write is stamped with [ApplyOptions.deletionDate] —
  /// the **uitschrijvingsdatum** (#394).
  ///
  /// Uitschrijving and deletion are official acts in Smartschool: the date goes
  /// on the record and has to be the real one, not the moment the operator
  /// happened to press the button. So the UI has to ask before it writes, and
  /// this is what tells it that this particular resolution is one of the ones
  /// worth asking about.
  ///
  /// **A property of the action, never a list of kinds held in the UI** — the
  /// same rule [canApplyToAll] states, for the same reason: a list in a screen
  /// drifts from what the actions actually consume, and an action added later
  /// inherits whatever the list's default happened to be. Declared here, a new
  /// action is silent about dates until someone decides otherwise, which is
  /// exactly how every action behaved before this member existed.
  ///
  /// True only where [apply] genuinely reads `options.deletionDate`. It is not
  /// "this action is destructive": [RemoveStudentFromAzure] deletes an Office
  /// 365 account and carries no date at all, because Graph records none.
  bool get usesDeletionDate => false;

  /// The action types this one **unlocks** on the same target (#230).
  ///
  /// Provisioning a brand-new student is a chain, not a single action: the
  /// Smartschool account is built with the Azure UPN as its `mail`, so
  /// [AddStudentToSmartschool] cannot even [evaluate] true until
  /// [AddStudentToAzure] has run. The dispatcher (§6.3) is a pure function of
  /// the *current* record, so it can only ever offer the first link of that
  /// chain — which is why a WISA-only student used to be offered one create,
  /// leaving the operator to apply, wait for the relink, and apply again.
  ///
  /// Declaring the follow-up here lets the State layer run it immediately
  /// against the **freshly relinked** record. It must be the relinked record
  /// and never a projection: `createPrincipalName` resolves a UPN collision by
  /// suffixing, so the UPN that actually landed can differ from the one
  /// [describeChanges] projected, and the Smartschool account would then carry
  /// the wrong `mail`.
  ///
  /// Pure and constant — it names what *may* follow, never what must: the
  /// follow-up's own [evaluate] still decides whether it applies, exactly as it
  /// would on the next sync.
  Set<Type> get unlocks => const {};

  /// The systems the [unlocks] chain would write to, beyond the one
  /// [describeChanges] already names (#234).
  ///
  /// A confirmed apply is not confined to the system the visible action targets:
  /// [AddStudentToAzure] writes Office 365 and then, through its chain, writes
  /// Smartschool as well. The apply-confirmation dialog has to be able to say so
  /// *before* the write, and at that point the follow-up does not exist yet —
  /// the dispatcher cannot produce it until the first write has relinked the
  /// record — so it cannot be read off a pending action. Declaring it here is
  /// what lets the UI name a system the pass will genuinely reach.
  ///
  /// Keep it in step with [unlocks]: it names the same follow-ups' target
  /// systems. Each family's dispatch test pins the two against the follow-up's
  /// own [ChangeSet.system], so they cannot drift apart unnoticed.
  ///
  /// Like [unlocks] it names what *may* follow, never what must — the
  /// follow-up's own [evaluate] still decides.
  Set<Origin> get unlockedSystems => const {};

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

  /// Whether a Smartschool class move is still **pending** for this student
  /// (#338): they already sit in an official class today *and*
  /// [MoveToSmartschoolClassGroup] would fire on the same account with the same
  /// [placement].
  ///
  /// `saveUser` carries `stamboeknummer` with no school-year parameter, while a
  /// Smartschool schoolloopbaan stores one stamnummer **per row** — and the
  /// write lands on the *last* row. Until the move into next year's class has
  /// run, that last row is the **running** year's, so a student switching
  /// between two of the group's schools has this year's row overwritten with
  /// next year's institute number. Waiting for the move to create the new row is
  /// what keeps the running year intact (66 of 66 such students were damaged the
  /// summer the stem write went first; the years where the moves ran first are
  /// all clean).
  ///
  /// The condition is per **account**, never per school: a student who holds no
  /// class yet — a virtual school's intake, a freshly created account — has no
  /// row to damage, so nothing is held back for them. And the move's own
  /// [MoveToSmartschoolClassGroup.evaluate] is asked directly rather than
  /// restated here, so "a move is pending" cannot drift from what the move
  /// actually does.
  ///
  /// A null [placement] means the caller wired no membership context at all
  /// (the dispatch's `placementFor` is optional), and then nothing is known
  /// about a pending move — the pre-#338 behaviour.
  bool _classMoveIsPending(ClassPlacement? placement) =>
      placement != null &&
      placement.currentClass != null &&
      MoveToSmartschoolClassGroup(account, config, placement).evaluate();
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
  bool evaluate() => account.isInOurWisa && account.azure == null;

  /// Creating the Office 365 account unlocks the Smartschool create, which
  /// needs the fresh UPN as the new account's `mail` (#230). Without the chain
  /// a new student's second create only appears on the *next* pass, so the
  /// Acties panel never showed the full provisioning intent.
  @override
  Set<Type> get unlocks => const {AddStudentToSmartschool};

  /// That follow-up writes Smartschool, so one confirmed apply of this action
  /// reaches both systems and the confirmation dialog says both (#234).
  @override
  Set<Origin> get unlockedSystems => const {Origin.smartschool};

  /// Provisioning goes in bulk (legacy `AddToAzure(…, true, true)`): a new
  /// intake arrives as a cohort, and creating their accounts is mechanical.
  @override
  bool get canApplyToAll => true;

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
        // Both halves of the licensing rule, or the account is created outside
        // the dynamic group that grants the licence and stays unlicensed until
        // somebody notices by hand (#358).
        FieldChange('jobTitle', after: config.studentJobTitle),
        // The create has always written the class here; naming it is what makes
        // the field the app's to keep current (#359) rather than a value stamped
        // once and forgotten.
        FieldChange('department', after: wisa.classGroup),
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
          jobTitle: config.studentJobTitle,
        ),
      );
    }

    try {
      final users = _requireAzure(connectors).users;
      // #224: never create a second account for a person who already has one.
      // The snapshot this action was derived from can be stale — or blind, when
      // the account carries neither our `companyName` nor our `department` — and
      // `createPrincipalName` resolves the UPN collision by suffixing, so the
      // duplicate create would succeed silently. `employeeId` is the one key
      // that survives a transfer between group schools, so a hit means the
      // account exists and the next sync must adopt it instead.
      final existing = await users.findByEmployeeId(wisa.wisaId.value);
      if (existing != null) {
        return _failed(
          changes,
          Origin.azure,
          StateError(
            'Office 365 already has an account with employeeId '
            '${wisa.wisaId.value} (${existing.upn}). Sync Azure again so the '
            'existing account is linked instead of creating a duplicate.',
          ),
        );
      }
      final upn = await users.createPrincipalName(
        given,
        wisa.name,
        config.azureDomain,
        isStudent: true,
      );
      final password = config.newAccountPassword();
      final created = await users.createUser(
        userPrincipalName: upn,
        displayName: wisa.fullName,
        password: password,
        givenName: given,
        surname: wisa.name,
        employeeId: wisa.wisaId.value,
        companyName: config.schoolPrefix,
        department: wisa.classGroup,
        jobTitle: config.studentJobTitle,
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
      account.isInOurWisa &&
      account.azure != null &&
      account.smartschool == null;

  /// Provisioning goes in bulk (legacy `AddToSmartschool(…, true, true)`), the
  /// second half of the same intake pass [AddStudentToAzure] leads. Note the
  /// staff twin [AddStaffToSmartschool] is deliberately **not** bulk-applyable:
  /// legacy withheld it there and this port keeps the asymmetry.
  @override
  bool get canApplyToAll => true;

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
      // The placement is best-effort, so it cannot change this action's
      // outcome — not by refusing and, since #343, not by throwing either. When
      // it *did* land it names its class, exactly as the standalone move does,
      // so the State layer can seat the new account in it (#342); a skipped or
      // refused placement names nothing, and one that threw hands its cause up
      // as a warning instead of failing the create it followed.
      final placed = await _placeNewAccount(connectors, built);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: built,
        movedToClass: placed.seated,
        warnings: placed.warnings,
        generatedPassword: password,
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
  /// Legacy likewise logs and continues. A target that is not one of our
  /// classes (#333), an unresolved or non-official one, a refused move, and —
  /// since #343 — a move that *threw*, are therefore all tolerated here: a
  /// mis-placed *non*-ANS/BNS student is re-caught next pass by
  /// [MoveToSmartschoolClassGroup] once the account is complete, so only the
  /// (rare) ANS/BNS → "Leerlingen" case has no safety net.
  ///
  /// Until #343 that contract held for the `false` branch only. The create ran
  /// this step inside its own `try`, so a `moveUserToClass` that threw — an
  /// HTTP error, a SOAP fault, unreadable XML — was caught by the create's
  /// `catch` and reported as a *failed create*, for an account `saveAccount`
  /// had just made. The State layer then spliced nothing, the card went on
  /// offering "Maak een nieuw Smartschool account" for an account that existed,
  /// and applying it again wrote `saveUser` a second time for the same uid.
  ///
  /// **Returns the official class the account was actually seated in**, or null
  /// when no placement happened — which is what the caller puts in
  /// [ActionResult.movedToClass] so the State layer can splice the membership
  /// the same way it does for the standalone move (#341/#342). Without it a
  /// student who had just been created *and correctly placed* was immediately
  /// offered [MoveToSmartschoolClassGroup] into the class they already sat in:
  /// the snapshot gained the account but no membership, so
  /// [ClassPlacement.currentClass] read null and the move evaluated true (and,
  /// since #338, blocked the stamboeknummer write behind it).
  ///
  /// Only a *written* seat is named, and best-effort is why: every way this
  /// helper declines — no placement context, a class that is not ours (#333),
  /// one that does not resolve, one that is not an official class (the ANS/BNS
  /// "Leerlingen" root among them, which is a tree node and holds no class
  /// membership), a `moveUserToClass` that came back false, or one that threw —
  /// names no class and leaves the snapshot's membership list alone. A claim
  /// here becomes the snapshot's truth until Smartschool is read again, so
  /// silence is the only honest answer to a placement that did not demonstrably
  /// land.
  ///
  /// **A swallowed exception is reported, not lost.** There is no log sink on
  /// this path, so the cause travels back in [_PlacementOutcome.warnings] for
  /// the caller to hand to the State layer as [ActionResult.warnings] — the
  /// operator sees "the account was made, the class was not" instead of a
  /// success line that quietly means half of one. Only the *throw* warns: a
  /// refused move and every declined target are ordinary, expected answers this
  /// path has always taken in stride, whereas a throw is the one outcome whose
  /// visibility this change takes away.
  Future<_PlacementOutcome> _placeNewAccount(
    Connectors connectors,
    ss.SmartschoolAccount built,
  ) async {
    final placement = this.placement;
    if (placement == null) return const _PlacementOutcome();

    final classGroup = _wisa.classGroup;
    final isAdultEducation =
        classGroup.contains('ANS') || classGroup.contains('BNS');

    // The same ours-check [MoveToSmartschoolClassGroup.evaluate] applies (#333):
    // a create must not be the way a foreign class name gets enrolled either.
    // The ANS/BNS branch is exempt because it targets the "Leerlingen" root,
    // which is a tree node rather than one of our classes — `_isOfficialClass`
    // below is what vets that one.
    if (!isAdultEducation && !placement.isOurClass(classGroup)) {
      return const _PlacementOutcome();
    }

    final targetName = isAdultEducation ? 'Leerlingen' : classGroup;
    final target = placement.resolveClass(targetName);
    if (target == null || !_isOfficialClass(target)) {
      return const _PlacementOutcome();
    }

    // Only the connector call is guarded. Everything above it is pure lookup
    // in data already in hand, so a throw there is a bug in this port rather
    // than a transient failure of Smartschool's, and it must still fail loudly.
    try {
      final seated = await _requireSmartschool(connectors)
          .moveUserToClass(built.uid, target.id.value, _wisa.classChange);
      return _PlacementOutcome(seated: seated ? target : null);
    } on Object catch (e) {
      return _PlacementOutcome(
        warnings: <String>[
          'Het Smartschool-account is aangemaakt, maar de klasplaatsing in '
              '${target.name} is mislukt: $e. De klaswijziging wordt bij de '
              'volgende ronde opnieuw voorgesteld.',
        ],
      );
    }
  }
}

/// What [AddStudentToSmartschool]'s best-effort placement step ended up doing:
/// the class it wrote the account into (null unless a move demonstrably
/// landed), plus any operator-facing note the caller must not drop (#343).
///
/// A record of two values rather than a bare `Group?` because the step now has
/// two things to say and exactly one of them may change the snapshot: the seat
/// is spliced in as fact, the warning is only shown.
class _PlacementOutcome {
  const _PlacementOutcome({
    this.seated,
    this.warnings = const <String>[],
  });

  /// The official class the account was actually written into, or null for
  /// every way the placement declined, was refused, or threw.
  final Group? seated;

  /// Reasons the placement did not land that the operator must still see —
  /// today only a `moveUserToClass` that threw, which this path swallows so it
  /// cannot fail the create it followed (INV-41).
  final List<String> warnings;
}

/// Unregister (but keep) a still-active Smartschool account whose student has
/// left *our* school — gone from WISA entirely, or moved to a sibling group
/// school we don't manage (#134). Ported from
/// `Action\StudentAccount\UnregisterSmartschool`.
class UnregisterStudentFromSmartschool extends StudentAction {
  const UnregisterStudentFromSmartschool(super.account, super.config);

  @override
  bool evaluate() =>
      account.hasLeftOurSchool &&
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

  /// The uitschrijving *is* the date (#394): Smartschool records the day the
  /// student left and evaluates the school year against it, so writing "now"
  /// for a departure that happened in March is a wrong entry in an official
  /// register, not a rounding error.
  @override
  bool get usesDeletionDate => true;

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

/// Delete a Smartschool account whose student has left *our* school — gone from
/// WISA entirely, or moved to a sibling group school we don't manage (#134).
/// Ported from `Action\StudentAccount\DeleteFromSmartschool`.
class DeleteStudentFromSmartschool extends StudentAction {
  const DeleteStudentFromSmartschool(super.account, super.config);

  @override
  bool evaluate() => account.hasLeftOurSchool && account.smartschool != null;

  /// Delete and [UnregisterStudentFromSmartschool] are the two mutually
  /// exclusive resolutions of a WISA-departed Smartschool account (#110). Delete
  /// is the destructive alternative, so it is not the default.
  @override
  String? get alternativeGroup => smartschoolDepartureAlternative;

  /// The delete carries the same official date as its conservative twin (#394),
  /// and getting it wrong here is the more consequential of the two: the account
  /// is gone afterwards, so the date it was struck off on is the only record of
  /// when the student actually left.
  @override
  bool get usesDeletionDate => true;

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

/// Delete an Azure-only account for a student gone from the **whole group** (no
/// WISA anywhere, no Smartschool) carrying the school's `companyName`. Ported
/// from `Action\StudentAccount\RemoveFromAzure`.
///
/// A student who merely left *our* school but is still present in a sibling
/// group school keeps a non-null WISA record ([WisaPresence.groupOnly]), so
/// [LinkedAccount.hasLeftGroup] is false and their Azure account is **kept**
/// (#134) — only a genuine group-departure removes it.
class RemoveStudentFromAzure extends StudentAction {
  const RemoveStudentFromAzure(super.account, super.config);

  @override
  bool evaluate() =>
      account.hasLeftGroup &&
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

  /// A mechanical domain correction, so it goes in bulk (legacy
  /// `ModifyAzureStudentEmail(…, true, true)`, and the same grant on the dead
  /// `ChangeEmail` that stated the rule twice).
  @override
  bool get canApplyToAll => true;

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
///
/// A **missing** `companyName` counts as differing (#224). The legacy guard
/// returned false for null, which made the transferred-student case
/// self-perpetuating: an adopted account whose `companyName` was never set is
/// invisible to the next sync's `$filter`, and the one action that would stamp
/// our prefix on it — this one — refused to fire precisely because the field was
/// unset. Setting it is what makes the adoption stick.
class ModifyAzureSchool extends StudentAction {
  const ModifyAzureSchool(super.account, super.config);

  @override
  bool evaluate() => !_eq(_az.companyName, config.schoolPrefix);

  /// Stamping our own prefix on our own students is mechanical, so it goes in
  /// bulk (legacy `ModifyAzureSchool(…, true, true)`) — and it is what makes a
  /// transferred student's adoption stick, a repair that arrives per intake.
  @override
  bool get canApplyToAll => true;

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

/// Correct a student's Azure `jobTitle` to the school's configured student job
/// title (#358) — the twin of [ModifyAzureSchool] for the *other* half of the
/// licensing rule.
///
/// Office 365 grants the student licence through a dynamic group whose rule
/// reads both fields:
///
///     (user.companyName -eq "<PREFIX>") and (user.jobTitle -eq "LeerlingSec")
///
/// The port wrote `companyName` and never `jobTitle`; the legacy app wrote
/// `JobTitle` and never `CompanyName`. Each generation satisfied one half of a
/// two-half rule, so accounts landed outside the group and stayed unlicensed
/// until an operator assigned a licence directly.
///
/// A **missing** `jobTitle` counts as differing, for the same reason it does in
/// [ModifyAzureSchool]: a blank field is exactly the state this port's own
/// creates left behind, and a repair that refused to fire on it would leave
/// every one of them unlicensed forever.
///
/// **Derived from the linked record, never from `companyName`.** The dispatch
/// only ever constructs this in the modify branch, which requires the student to
/// be present in *our* WISA as well as in Smartschool and Azure — so what gets
/// stamped follows from WISA saying "this is a pupil of this school", not from
/// what the Azure account happens to carry. Stamping the value on everything
/// bearing our prefix instead would hit genuine basisschool pupils whose account
/// wrongly carries it and hand them secondary licences they are not entitled to
/// (20 accounts in the live tenant carry `LeerlingBas` under our prefix).
class ModifyAzureJobTitle extends StudentAction {
  const ModifyAzureJobTitle(super.account, super.config);

  @override
  bool evaluate() => !_eq(_az.jobTitle, config.studentJobTitle);

  /// Mechanical, like its [ModifyAzureSchool] twin: the value follows from the
  /// kind of school the student is enrolled in, so it goes in bulk — the four
  /// moved-up pupils the live audit found are one cohort, not four judgements.
  @override
  bool get canApplyToAll => true;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Wijzig de functietitel in Azure',
        fields: [
          FieldChange(
            'jobTitle',
            before: _az.jobTitle,
            after: config.studentJobTitle,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _azurePatch(
        connectors,
        options,
        describeChanges(),
        (users) => users.updateUser(_az.id, jobTitle: config.studentJobTitle),
        () => _az.copyWith(jobTitle: config.studentJobTitle),
      );
}

/// Correct a **student's** Azure `department` to the class group WISA reports
/// for them (#359) — the third field of the profile the create stamps and
/// nothing ever reconciled.
///
/// `department` means two different things depending on who holds the account,
/// and this action writes only one of them:
///
/// - on a **student** it is the class group. [AddStudentToAzure] writes it at
///   creation, and until this action existed nothing rewrote it — so an account
///   kept naming the class its holder sat in the year it was made. The live
///   tenant carries secondary pupils whose `department` still names a
///   basisschool class.
/// - on a **staff member** it is the comma-separated list of school prefixes
///   other software maintains, which #237 established we must not rewrite (see
///   `departmentSchoolsExcept` in `account_core`'s `school_prefix.dart`).
///
/// Nothing but the student dispatch can reach this — it is a [StudentAction] of
/// a sealed family, constructed in one place, in the modify branch — so the
/// staff meaning of the field is structurally out of its reach.
///
/// **WISA is the authority, in one direction only.** The value written is
/// `WisaStudent.classGroup`, the same bare class name the create writes (never
/// the sub-grouped `2F ECO` widening a Smartschool placement may use, and never
/// the Office 365 group's `<PREFIX>-<KLAS>` name). The Azure field is output:
/// nothing may read a class back out of it, which is why the repair is derived
/// from the linked WISA row and the modify branch is the only place it runs.
///
/// A **missing** `department` counts as differing, like [ModifyAzureSchool]'s
/// and [ModifyAzureJobTitle]'s: an adopted account (#224) arrives carrying the
/// other school's class or nothing at all, and filling the field in is the same
/// repair as correcting it.
///
/// A **blank WISA class** stands the action down instead. WISA saying nothing is
/// not WISA saying "no class", and clearing a field on the strength of a silence
/// would destroy the one answer the record still had. The student keeps whatever
/// Azure holds until WISA names a class.
///
/// So does a class our own WISA schools do not have (#333), when a [placement]
/// is wired to say so: the same guard that stands the Smartschool move down
/// stands this write down, because a name our inventory does not carry is never
/// one to write into our systems — in Smartschool or in Office 365. Without a
/// placement nothing is known about the inventory and the write goes ahead, the
/// pre-#333 reading its sibling actions give a null placement.
class ModifyAzureDepartment extends StudentAction {
  const ModifyAzureDepartment(super.account, super.config, {this.placement});

  /// The class-placement context (#333), when the caller wired one. Read for
  /// [ClassPlacement.isOurClass] alone — the target class is WISA's bare
  /// `classGroup`, never the placement's (possibly sub-grouped) `className`,
  /// which is what Smartschool wants and not what the create stamps here.
  final ClassPlacement? placement;

  @override
  bool evaluate() =>
      _className.isNotEmpty &&
      (placement?.isOurClass(_className) ?? true) &&
      !_eq(_az.department, _className);

  /// The class WISA holds this student in, trimmed. Empty when WISA names none.
  String get _className => _wisa.classGroup.trim();

  /// Mechanical, like its [ModifyAzureSchool] and [ModifyAzureJobTitle] twins:
  /// the value is copied from WISA with no judgement to make. It also arrives as
  /// a cohort — a class moving up a year is one repair per pupil in it, which is
  /// precisely what a bulk apply is for.
  @override
  bool get canApplyToAll => true;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Wijzig de klas in Azure',
        fields: [
          FieldChange(
            'department',
            before: _az.department,
            after: _className,
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _azurePatch(
        connectors,
        options,
        describeChanges(),
        (users) => users.updateUser(_az.id, department: _className),
        () => _az.copyWith(department: _className),
      );
}

/// Correct the Smartschool internal number to equal the WISA id. Ported from
/// `Action\StudentAccount\ModifyAccountID`.
class ModifyAccountId extends StudentAction {
  const ModifyAccountId(super.account, super.config);

  @override
  bool evaluate() => _wisa.wisaId.value.trim() != _ss.accountId.trim();

  /// Copying one id onto another is mechanical, so it goes in bulk (legacy
  /// `ModifyAccountID(…, true, true)`).
  @override
  bool get canApplyToAll => true;

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

  /// Copying the Azure UPN down to Smartschool is mechanical, so it goes in
  /// bulk (legacy `ModifySmartschoolStudentEmail(…, true, true)`).
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

/// Sync the Smartschool home address from WISA. Ported from
/// `Action\StudentAccount\ModifySmartschoolStudentAddress`.
class ModifySmartschoolStudentAddress extends StudentAction {
  const ModifySmartschoolStudentAddress(super.account, super.config);

  // The action fires only on a genuine *home-address* difference — the five
  // fields the legacy `checkUserHomeAddress` compared. `country` is excluded
  // on purpose (WISA hardcodes 'BE', Smartschool returns a free-text `Land`, so
  // including it fired for ~all students, #153); a null/empty `houseNumberAdd`
  // is treated as unchanged. See `Address.sameHomeAddressAs`.
  @override
  bool evaluate() => !_ss.address.sameHomeAddressAs(_wisa.address);

  @override
  ChangeSet describeChanges() {
    final Address from = _ss.address;
    final Address to = _wisa.address;
    // Surface every field that actually differs — including postalCode and the
    // house-number components — so no real change is ever hidden behind an
    // identical-looking summary (#153). Fields that match are omitted rather
    // than shown as a misleading "X → X" row.
    final fields = <FieldChange>[
      if (from.street != to.street)
        FieldChange('street', before: from.street, after: to.street),
      if (from.houseNumber != to.houseNumber)
        FieldChange('houseNumber',
            before: from.houseNumber, after: to.houseNumber),
      if ((from.houseNumberAdd ?? '') != (to.houseNumberAdd ?? ''))
        FieldChange('houseNumberAdd',
            before: from.houseNumberAdd, after: to.houseNumberAdd),
      if (from.postalCode != to.postalCode)
        FieldChange('postalCode',
            before: from.postalCode, after: to.postalCode),
      if (from.city != to.city)
        FieldChange('city', before: from.city, after: to.city),
    ];
    return ChangeSet(
      system: Origin.smartschool,
      summary: 'Wijzig het adres in Smartschool',
      fields: fields,
    );
  }

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      _smartschoolSave(
        connectors,
        options,
        describeChanges(),
        // Write WISA's home-address fields but preserve Smartschool's country:
        // the legacy action never wrote Country, and WISA's hardcoded 'BE' is
        // not an authoritative value to push (#153).
        _ss.copyWith(
          address: Address(
            street: _wisa.address.street,
            houseNumber: _wisa.address.houseNumber,
            houseNumberAdd: _wisa.address.houseNumberAdd,
            postalCode: _wisa.address.postalCode,
            city: _wisa.address.city,
            country: _ss.address.country,
          ),
        ),
      );
}

/// Sync the Smartschool stamboeknummer from WISA. Ported from
/// `Action\StudentAccount\ModifySmartschoolStemID`.
///
/// **Held back while a class move is pending** (#338). Smartschool keeps one
/// stamnummer per schoolloopbaan row and `saveUser` writes it to the last one,
/// so running this before [MoveToSmartschoolClassGroup] stamps *next* year's
/// number onto the row of the year the student is still sitting in. The action
/// therefore evaluates false until the move has created the new row — see
/// [StudentAction._classMoveIsPending] for why the condition is per account.
class ModifySmartschoolStemId extends StudentAction {
  /// The class-placement context, when the caller wired one (#338).
  ///
  /// This action moves nobody; it reads the placement only to answer whether a
  /// class move is still pending, and defers to it when one is. Null — no
  /// membership context — restores the unconditional pre-#338 behaviour.
  final ClassPlacement? placement;

  const ModifySmartschoolStemId(super.account, super.config, {this.placement});

  int get _wisaStemId => int.tryParse(_wisa.stemId) ?? 0;

  @override
  bool evaluate() =>
      _wisaStemId != _ss.stemId && !_classMoveIsPending(placement);

  /// A mechanical WISA → Smartschool copy, so it goes in bulk (legacy
  /// `ModifySmartschoolStemID(…, true, true)`).
  @override
  bool get canApplyToAll => true;

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
        // The one action allowed to put a *different* stamboeknummer in the
        // `saveUser` payload (#338); every other save re-sends the current one.
        writesStemId: true,
      );
}

/// Sync the Smartschool birthplace from WISA. Ported from
/// `Action\StudentAccount\ModifySmartschoolBirthPlace`.
class ModifySmartschoolBirthPlace extends StudentAction {
  const ModifySmartschoolBirthPlace(super.account, super.config);

  @override
  bool evaluate() => !_eq(_ss.birthPlace, _wisa.birthPlace);

  /// A mechanical WISA → Smartschool copy, so it goes in bulk (legacy
  /// `ModifySmartschoolBirthPlace(…, true, true)`). Note the *name* and
  /// *address* modifiers beside it are deliberately withheld: those are the
  /// fields where WISA and Smartschool legitimately disagree and the operator is
  /// meant to look at the record.
  @override
  bool get canApplyToAll => true;

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

  /// Fires when the student's WISA class and their Smartschool class disagree —
  /// and only for a class that is **ours** (#333).
  ///
  /// The ours-check is the guard in front of the widest bulk action in the app:
  /// whatever named the target — a WISA quirk, a mis-scoped index (#332), a
  /// hand-edited rule — a class our own school does not have must end in
  /// silence rather than in a proposal an operator can apply to the whole
  /// school. It asks WISA, not Smartschool: at the rollover the target class
  /// legitimately does not exist in Smartschool yet, and suppressing *those*
  /// moves would gut the action (see [ClassPlacement.isOurClass]).
  @override
  bool evaluate() =>
      !_isAdultEducation &&
      placement.className != placement.currentClassName &&
      placement.isOurClass(placement.className);

  /// The bulk action the app exists for (legacy
  /// `MoveToSmartschoolClassGroup(…, true, true)`): at the September rollover
  /// **every** student changes class group, and the move is a mechanical
  /// consequence of the WISA class they already sit in.
  @override
  bool get canApplyToAll => true;

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
      // still exists, so the State layer keeps its record — and [target] is
      // named so it can reseat the membership too (#341). The record alone
      // could not tell it: it comes back byte-for-byte as it went in, so
      // patching the snapshot from it left the student sitting in the old
      // class, and this action kept evaluating true after its own write had
      // landed.
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        smartschool: account,
        movedToClass: target,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

/// The student's Office 365 class-group placement, when it disagrees with their
/// WISA class (#245): they are missing from `<PREFIX>-<KLAS>`, or still sitting
/// in the group of a class they left — or both.
///
/// The Azure counterpart of [MoveToSmartschoolClassGroup], and the per-account
/// half of #228: the roster diff was previously reported only on the class row
/// in Klasgroepen, so an operator looking at *one* student — the usual entry
/// point when a parent phones about a class team — saw nothing about their group
/// membership. It reads its [AzureClassPlacement] from the very same resolver
/// that builds the class-level `AzureClassGroupPlan`, so the two views can never
/// disagree about the same student.
///
/// **Informational** (`canApply == false`), deliberately. Class-group membership
/// is a class-level fact with exactly one automated remedy —
/// `SyncAzureClassGroupMembers`, which rewrites the whole roster in one batched
/// write — and this action names it. Giving the account its own write would ask
/// Graph to add the same member twice whenever an "apply all" pass ran both
/// (the class plan is computed off the snapshot, so it cannot know the
/// per-student write already landed), and would count one unit of work twice in
/// the pending totals. So the per-account row diagnoses, the class row applies.
class AzureClassGroupMembership extends StudentAction {
  /// The Office 365 class-group context this action reads, injected by the
  /// dispatch.
  final AzureClassPlacement placement;

  const AzureClassGroupMembership(
    super.account,
    super.config,
    this.placement,
  );

  @override
  bool evaluate() => account.azure != null && placement.differs;

  @override
  bool get canApply => false;

  String get _strays => placement.strayGroupNames.join(', ');

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: _summary(),
        fields: [
          FieldChange(
            'Office 365-klasgroep',
            before: _strays,
            after: placement.groupName ?? '',
          ),
        ],
      );

  String _summary() {
    final target = placement.groupName ?? placement.className;
    if (!placement.missingFromOwnGroup) {
      return 'Staat nog in de Office 365-klasgroep $_strays. '
          '${_instruction('die klas')}';
    }
    if (placement.strayGroupNames.isEmpty) {
      return 'Ontbreekt in de Office 365-klasgroep $target. '
          '${_instruction('klas ${placement.className}')}';
    }
    return 'Zit in de verkeerde Office 365-klasgroep: $_strays in plaats van '
        '$target. ${_instruction('beide klassen')}';
  }

  /// What the operator should do about it — and *where* (#331).
  ///
  /// Normally the remedy is the class-level `SyncAzureClassGroupMembers`, which
  /// this row deliberately does not duplicate. But when every group named here
  /// is mastered by Exchange Online, that write does not exist: the class card
  /// carries `AzureClassGroupNotManageable` instead, and telling the operator to
  /// go and update a roster the app will not offer to update sends them around
  /// the loop #331 was filed to break.
  String _instruction(String which) {
    if (!placement.onlyExchangeManagedGroups) {
      return 'Werk het ledenbestand van $which bij.';
    }
    final subject = placement.unmanagedGroupNames.length == 1
        ? 'Die groep wordt'
        : 'Die groepen worden';
    return '$subject in Exchange Online beheerd; Graph kan de ledenlijst niet '
        'bijwerken. Pas het lidmaatschap daar aan.';
  }

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'AzureClassGroupMembership is informational and cannot be applied '
        '(canApply is false) — the class-level SyncAzureClassGroupMembers '
        'performs the membership write',
      );
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
  /// unless dry-run, and returns the saved record as the mutated source record.
  ///
  /// **The stamboeknummer never rides along** (#338). `saveUser` sends the whole
  /// account, so every field modifier — mail, address, birthplace, roepnaam —
  /// carries a `stamboeknummer` it has no opinion about; Smartschool then stamps
  /// that value on the *last* schoolloopbaan row. So unless [writesStemId] says
  /// this is the action whose job is to change it, the payload re-sends the
  /// number Smartschool holds **right now** and that half of the write is a
  /// no-op. Default-safe on purpose: an action added later cannot smuggle a
  /// stamnummer through by forgetting about this.
  Future<ActionResult> _smartschoolSave(
    Connectors connectors,
    ApplyOptions options,
    ChangeSet changes,
    ss.SmartschoolAccount updated, {
    bool writesStemId = false,
  }) async {
    final payload =
        writesStemId ? updated : updated.copyWith(stemId: _ss.stemId);

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        smartschool: payload,
      );
    }
    try {
      // An empty password leaves the holder's existing password unchanged.
      final ok = await _requireSmartschool(connectors)
          .saveAccount(payload, password: '');
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
        smartschool: payload,
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
