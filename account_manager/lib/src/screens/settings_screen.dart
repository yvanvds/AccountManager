import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import '../auth/aad_app_config.dart';
import '../reconcile/reconcile_bootstrap.dart' show StoreEndpoints;
import '../settings/connection_config.dart';
import '../settings/settings_bootstrap.dart';
import '../settings/wisa_rule_labels.dart';
import '../update/app_release.dart' show AppRelease;
import '../update/release_notes.dart' show ReleaseNotesDialog;
import '../update/update_controller.dart';

/// The Settings view (#106): edit the full [AppSettings] config document and
/// write the two credentials (WISA password, Smartschool passphrase) through the
/// [SecretProvider] seam.
///
/// The operator had no way to change any of this from the app — the #99 live
/// bring-up seeded the settings document and the vault secrets with a one-off
/// script, and the Smartschool group paths / grade-year vocabulary stayed at
/// empty defaults, so placement-dependent actions could not resolve a parent
/// group. This view closes that gap.
///
/// Two disciplines the seam enforces are honoured in the UI:
///
/// - **Secrets are write-only.** The WISA password and Smartschool passphrase
///   fields start empty and are never populated from the provider — the value
///   is never echoed back. Leaving a field blank on save keeps the stored
///   secret; typing one replaces it via [SecretProvider.write].
/// - **No restart needed.** A reload affordance re-reads the document from the
///   store into the form, so a settings change another operator made (or the
///   operator's own save) can be pulled back without relaunching — and every
///   document this view loads or saves is published into the shared
///   [LiveSettings] holder, so the reconcile stack's WISA pull honours it on the
///   very next Synchroniseer rather than on the next app launch (#238).
///
/// Both connectors' import rules are authored here — add / edit / remove,
/// persisted through the existing rule codecs and applied on the next pull:
///
/// - **Smartschool** (#202): the two rules the legacy app offers
///   (`DiscardSmartschoolGroup`, `NoSmartschoolSubgroups`).
/// - **WISA** (#273): the three rules with no other surface —
///   `DontImportClass`, `DontImportUserFromWisa` and `ReplaceInstitute`. Neither
///   school-marking rule is left: `MarkAsOurs` was deleted in #286 and
///   `MarkAsVirtual` in #277, both because the WISA-scholen grid above marks the
///   same flag per school **id** and two surfaces for one flag could disagree.
///   A document that still carries either loads fine — the entry is ignored, and
///   a `markAsVirtual` mark is carried over to the grid's own checkbox first.
///
/// The WISA list shows the **persisted** rules — the operator's standing
/// configuration, which is what a pull unions with whatever this session earned.
/// Since #276 that includes the rules a `DontImportFromWisa` apply earns: the
/// apply writes its rule to this same document, so it shows up in this list
/// (after a **Herladen**, or in the next session) and is removed here like any
/// hand-typed one. The reconcile stack's `WisaImportRules` holder still carries
/// its own copy for the life of the process — that is what re-syncs WISA the
/// instant the rule is earned — but the document is now the record.
///
/// **The screen opens even when the settings document does not (#370).** The tab
/// frame, the header and the **Verbinding** tab render from the first frame, and
/// only the four document-backed tabs wait on the load. That is the whole point
/// of the Verbinding tab: it edits the local `connection.json` the store's own
/// coordinates come from, so a wrong Cosmos endpoint must not be able to lock the
/// operator out of the one screen that can fix it. A failed load brings that tab
/// forward by itself rather than leaving a dead end behind a retry button.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.bootstrap,
    this.connection,
    this.update,
  });

  /// Assembles (or returns the already-assembled) settings seams, or `null` when
  /// Azure AD is not configured for this build (no session to mint the Cosmos /
  /// Key Vault tokens the stores need).
  final Future<SettingsServices> Function()? bootstrap;

  /// Where this machine's backend coordinates are read and written (#370).
  ///
  /// `null` falls back to an [InMemoryConnectionStore] with no probe: a build
  /// (or a test) that wires nothing still renders the section, editing a
  /// throwaway copy rather than the operator's real `connection.json`.
  final ConnectionServices? connection;

  /// This session's update check (#371) — owned by the [AppShell], which is why
  /// it arrives as a live controller rather than as seams to assemble.
  ///
  /// `null` renders the Versie section with the version unknown and no check
  /// button, which is what a build with no update mechanism honestly is.
  final UpdateController? update;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// The index of the **Verbinding** tab — after the four document-backed ones
/// (#370) — and the resulting tab count.
const int _connectionTabIndex = 4;
const int _settingsTabCount = _connectionTabIndex + 1;

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  SettingsServices? _services;
  AppSettings? _loaded;
  Object? _error;
  bool _busy = false;
  int _attempts = 0;

  // ---------------------------------------------------------------------------
  // Verbinding (#370) — the local connection.json, not the settings document.
  // Deliberately independent of everything above: none of it is loaded, saved or
  // disabled by the state of the Cosmos store, because the Cosmos store is what
  // this section repairs.
  // ---------------------------------------------------------------------------

  late final ConnectionServices _connection =
      widget.connection ?? ConnectionServices(store: InMemoryConnectionStore());

  final _cosmosEndpoint = TextEditingController();
  final _cosmosDatabase = TextEditingController();
  final _vaultUri = TextEditingController();
  final _blobEndpoint = TextEditingController();
  final _blobContainer = TextEditingController();
  final _signalrEndpoint = TextEditingController();
  final _signalrHub = TextEditingController();

  // The Azure AD app registration (#384) — the same local file, the same tab.
  // Not the settings document and not `_azClientId`/`_azTenantId` below: those
  // are the *Azure connector's* profile inside the Cosmos document, which is
  // read with a token these four are what mints.
  final _aadClientId = TextEditingController();
  final _aadTenantId = TextEditingController();
  final _aadDomain = TextEditingController();
  final _aadSchoolPrefix = TextEditingController();

  /// The last resolution read from the store — the values on screen and, more
  /// importantly, where they came from and any warning the file earned.
  ResolvedConnection? _resolved;

  /// What this session bootstrapped against, captured the first time the screen
  /// resolves. A save that differs from it is the one that needs a relaunch to
  /// take effect; a save that matches it changes nothing that is running.
  StoreEndpoints? _connectionAtOpen;

  /// The same for the sign-in half (#384). A changed tenant additionally makes
  /// every cached token the wrong audience, which is why it is tracked rather
  /// than folded into [_connectionAtOpen].
  AadAppConfig? _aadAtOpen;

  bool _connectionBusy = false;
  bool _connectionNeedsRelaunch = false;
  String _connectionMessage = '';
  List<ConnectionProbeResult>? _probed;

  /// The tab frame, owned here rather than by a [DefaultTabController] so a
  /// failed settings load can bring the Verbinding tab forward (#370).
  ///
  /// Built in [initState] rather than lazily: a `late final` initializer would
  /// first run inside [dispose] on a build that never rendered the tabs (the
  /// not-configured panel), and creating a ticker off a deactivated element
  /// trips the framework's ancestor-lookup assertion.
  late final TabController _tabs;

  /// Whether the Verbinding tab has already been revealed by a failed load, so
  /// a retry the operator abandons cannot yank them back off the tab they went
  /// to next.
  bool _revealedConnection = false;

  // Global.
  final _schoolPrefix = TextEditingController();
  bool _debugMode = false;

  // The two WiFi networks printed on the password sheets (#368). Plain fields
  // rather than `_SecretField`s on purpose: the key is handed to every student
  // on paper, and the operator opens this section precisely to read what is
  // being printed.
  final _staffWifiSsid = TextEditingController();
  final _staffWifiCode = TextEditingController();
  final _studentWifiSsid = TextEditingController();
  final _studentWifiCode = TextEditingController();

  // WISA profile.
  final _wisaServer = TextEditingController();
  final _wisaPort = TextEditingController();
  final _wisaDatabase = TextEditingController();
  final _wisaUsername = TextEditingController();
  final _wisaPassword = TextEditingController(); // write-only secret
  bool _workDateIsNow = true;
  DateTime? _workDate;
  bool _virtualWorkDateIsNow = true;
  DateTime? _virtualWorkDate;

  // Smartschool profile.
  final _ssUri = TextEditingController();
  final _ssTestUser = TextEditingController();
  final _ssStudentGroup = TextEditingController();
  final _ssStaffGroup = TextEditingController();

  /// The group roots the Smartschool pull is scoped to (#351), as one
  /// comma-separated field — the shape the operator reads them in ("Leerlingen,
  /// Personeel") and the shortest thing to correct when a tree spells them
  /// otherwise.
  final _ssRoots = TextEditingController();
  final _ssPassphrase = TextEditingController(); // write-only secret
  bool _ssUseGrades = false;
  bool _ssUseYears = false;
  late final List<TextEditingController> _grades = List.generate(
    SmartschoolConnection.gradeCount,
    (_) => TextEditingController(),
  );
  late final List<TextEditingController> _years = List.generate(
    SmartschoolConnection.yearCount,
    (_) => TextEditingController(),
  );

  // The Smartschool import rules (#202): a mutable working copy the rule editor
  // edits in place and `_collect` commits on save, mirroring how the WISA school
  // list below is handled. Empty means the whole Smartschool group tree is
  // imported — which is what every install did while nothing could author one.
  List<SmartschoolImportRule> _ssRules = const <SmartschoolImportRule>[];

  // The WISA import rules (#273): the same working-copy treatment. These are the
  // *persisted* rules — the operator's standing configuration, which `wisaSyncer`
  // unions with the session's own `WisaImportRules` holder at pull time (#263) —
  // so authoring one here reaches the very next Synchroniseer.
  List<WisaImportRule> _wisaRules = const <WisaImportRule>[];

  // Who added each of those rules, when, and for whom (#285), keyed by
  // `wisaRuleKey` exactly as the document keys it. Edited alongside `_wisaRules`
  // and pruned to them on save, so removing a rule takes its provenance with it
  // rather than leaving a stamp that a later, unrelated rule with the same key
  // would inherit.
  Map<String, RuleProvenance> _wisaRuleProvenance =
      const <String, RuleProvenance>{};

  // Azure profile.
  final _azClientId = TextEditingController();
  final _azTenantId = TextEditingController();
  final _azDomain = TextEditingController();

  // The complete known-WISA-school list (#171): id + name + managed flag. The
  // shared credentials see every group school; "Scholen ophalen" fills this
  // list (merging by id, preserving the `ours` marks) and it persists so the
  // tab renders the full set — with the managed ones marked — without a re-fetch.
  // Held as a mutable working copy edited in place; committed on save.
  List<WisaSchoolProfile> _wisaSchools = const <WisaSchoolProfile>[];
  bool _fetchingSchools = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _settingsTabCount, vsync: this);
    // Two independent loads. The connection file is local and cannot fail the
    // way the Cosmos document can, so its tab is on screen either way.
    _loadConnection();
    // Nothing to load without a sign-in to load it with, and no retry that could
    // ever change that — so go straight to the tab that can (#384). A first
    // launch on a fresh install is *expected* to land here.
    if (widget.bootstrap == null) {
      _revealConnection();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final c in <TextEditingController>[
      _cosmosEndpoint,
      _cosmosDatabase,
      _vaultUri,
      _blobEndpoint,
      _blobContainer,
      _signalrEndpoint,
      _signalrHub,
      _aadClientId,
      _aadTenantId,
      _aadDomain,
      _aadSchoolPrefix,
      _schoolPrefix,
      _staffWifiSsid,
      _staffWifiCode,
      _studentWifiSsid,
      _studentWifiCode,
      _wisaServer,
      _wisaPort,
      _wisaDatabase,
      _wisaUsername,
      _wisaPassword,
      _ssUri,
      _ssTestUser,
      _ssStudentGroup,
      _ssStaffGroup,
      _ssRoots,
      _ssPassphrase,
      _azClientId,
      _azTenantId,
      _azDomain,
      ..._grades,
      ..._years,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Bootstraps the seams (once, memoized) if needed, then reads the document
  /// into the form.
  Future<void> _load() async {
    final make = widget.bootstrap;
    if (make == null) return;
    setState(() {
      _attempts++;
      _busy = true;
      _error = null;
    });
    try {
      final services = _services ?? await make();
      final settings = await services.store.load();
      services.liveSettings?.publish(settings);
      if (!mounted) return;
      setState(() {
        _services = services;
        _loaded = settings;
      });
      _populate(settings);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      _revealConnection();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Verbinding (#370)
  // ---------------------------------------------------------------------------

  /// Reads this machine's coordinates into the Verbinding fields.
  ///
  /// [ConnectionStore.read] never throws — a malformed or unreadable file comes
  /// back as the compiled defaults plus a [ResolvedConnection.warning] the
  /// section renders — so this has no failure path of its own to handle. That is
  /// deliberate: dying here would take down the screen the file is fixed on.
  Future<void> _loadConnection() async {
    final ResolvedConnection resolved = await _connection.store.read();
    if (!mounted) return;
    setState(() {
      _resolved = resolved;
      _connectionAtOpen ??= resolved.endpoints;
      _aadAtOpen ??= resolved.aad;
    });
    _populateConnection(resolved.endpoints);
    _populateAad(resolved.aad);
  }

  void _populateConnection(StoreEndpoints e) {
    _cosmosEndpoint.text = e.cosmosEndpoint;
    _cosmosDatabase.text = e.cosmosDatabase;
    _vaultUri.text = e.vaultUri;
    _blobEndpoint.text = e.blobEndpoint;
    _blobContainer.text = e.blobContainer;
    _signalrEndpoint.text = e.signalrEndpoint;
    _signalrHub.text = e.signalrHub;
  }

  void _populateAad(AadAppConfig a) {
    _aadClientId.text = a.clientId;
    _aadTenantId.text = a.tenantId;
    _aadDomain.text = a.azureDomain;
    _aadSchoolPrefix.text = a.schoolPrefix;
  }

  StoreEndpoints _collectConnection() => StoreEndpoints(
        cosmosEndpoint: _cosmosEndpoint.text.trim(),
        cosmosDatabase: _cosmosDatabase.text.trim(),
        vaultUri: _vaultUri.text.trim(),
        blobEndpoint: _blobEndpoint.text.trim(),
        blobContainer: _blobContainer.text.trim(),
        signalrEndpoint: _signalrEndpoint.text.trim(),
        signalrHub: _signalrHub.text.trim(),
      );

  AadAppConfig _collectAad() => AadAppConfig(
        clientId: _aadClientId.text.trim(),
        tenantId: _aadTenantId.text.trim(),
        azureDomain: _aadDomain.text.trim(),
        schoolPrefix: _aadSchoolPrefix.text.trim(),
      );

  /// Writes the typed coordinates **and** the typed Azure AD app registration to
  /// this machine's connection file (#370 endpoints, #384 AAD).
  ///
  /// One button for both halves because they are one file, and because on a
  /// fresh install they are one job: an operator who has just typed a client id
  /// to get signed in should not have to discover that a second, differently
  /// named save is what commits it.
  ///
  /// Separate from the document's **Opslaan** on purpose: the two write to
  /// different places (a local file vs the shared Cosmos document) and only one
  /// of them still works when the store is unreachable — or when there is no
  /// sign-in to reach it with at all.
  ///
  /// The running stack is *not* re-bootstrapped. It is memoized and already
  /// handed out — its connectors, its controller and the password queue are held
  /// by four other screens, and the broker built from the old client id is
  /// already wired into the session — so quietly swapping either underneath them
  /// would be the dishonest half of the choice the issue leaves open. The tab
  /// says a relaunch is needed instead, and only when the saved values actually
  /// differ from what this session started on.
  ///
  /// A changed **tenant** additionally drops the cached tokens: they were minted
  /// by the previous tenant's STS for the previous tenant's resources, so
  /// keeping them would make the next launch fail a silent acquisition it could
  /// never have won.
  Future<void> _saveConnection() async {
    final StoreEndpoints next = _collectConnection();
    final AadAppConfig nextAad = _collectAad();
    // Only a tenant that was actually *set* and has now moved. A first install
    // going from no tenant to a tenant has nothing cached to invalidate, and
    // saying "these belonged to the previous tenant" about a previous tenant
    // that never existed would be its own small lie.
    final AadAppConfig? before = _aadAtOpen;
    final bool tenantChanged = before != null &&
        before.tenantId.isNotEmpty &&
        nextAad.tenantId != before.tenantId;
    setState(() {
      _connectionBusy = true;
      _connectionMessage = '';
      _probed = null;
    });
    try {
      await _connection.store.write(endpoints: next, aad: nextAad);
      final Future<void> Function()? forget = _connection.forgetTokens;
      if (tenantChanged && forget != null) await forget();
      final ResolvedConnection resolved = await _connection.store.read();
      if (!mounted) return;
      setState(() {
        _resolved = resolved;
        if (next != _connectionAtOpen || nextAad != _aadAtOpen) {
          _connectionNeedsRelaunch = true;
        }
        _connectionMessage =
            'Verbinding bewaard in ${_connection.store.location}.'
            '${tenantChanged ? ' De opgeslagen aanmeldingen zijn gewist: ze '
                'horen bij de vorige tenant.' : ''}';
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() => _connectionMessage = 'Kon de verbinding niet '
            'bewaren: $e');
      }
    } finally {
      if (mounted) setState(() => _connectionBusy = false);
    }
  }

  /// Probes the coordinates **as typed**, before they are committed — so a typo
  /// in a Cosmos URI costs a button press rather than a relaunch.
  Future<void> _testConnection() async {
    final ConnectionProbe? probe = _connection.probe;
    if (probe == null) return;
    setState(() {
      _connectionBusy = true;
      _connectionMessage = '';
      _probed = null;
    });
    try {
      final List<ConnectionProbeResult> results = await probe(
        _collectConnection(),
      );
      if (mounted) setState(() => _probed = results);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _connectionMessage = 'De verbindingstest kon niet '
            'uitgevoerd worden: $e');
      }
    } finally {
      if (mounted) setState(() => _connectionBusy = false);
    }
  }

  /// Fills the **endpoint** fields with what this build ships — the escape hatch
  /// for an install that saved coordinates nobody can reach any more. It only
  /// fills them in; **Verbinding bewaren** is still what commits.
  ///
  /// It deliberately leaves the Azure AD fields alone. Their compiled defaults
  /// are empty by design (#384: the school's tenant and client id are kept out
  /// of this public repository), so "restore the defaults" would mean erasing
  /// the sign-in config the operator just typed — the one thing on this tab that
  /// cannot be recovered from the build.
  void _fillConnectionDefaults() {
    setState(() {
      _connectionMessage = 'Standaardwaarden voor de opslag ingevuld. De '
          'Azure AD-gegevens zijn ongemoeid gelaten. Bewaar om ze te '
          'gebruiken.';
      _probed = null;
    });
    _populateConnection(StoreEndpoints.fromEnvironment());
  }

  /// Brings the Verbinding tab forward when the four document-backed tabs have
  /// nothing to show — the settings document could not be loaded (#370), or
  /// Azure AD is not configured so there is no session to load it with (#384).
  ///
  /// The index is set rather than animated so the tab is simply *there*, and
  /// once only: a second failed retry must not drag the operator off whichever
  /// tab they moved to in the meantime.
  void _revealConnection() {
    if (_revealedConnection || _loaded != null) return;
    _revealedConnection = true;
    _tabs.index = _connectionTabIndex;
  }

  /// Re-reads the stored document into the form, discarding unsaved edits — the
  /// reload affordance that spares a restart. Clears the write-only secret
  /// fields too (they are never repopulated from the vault).
  Future<void> _reload() async {
    final services = _services;
    if (services == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await services.store.load();
      // A reload can pull in another operator's save; the reconcile stack must
      // see the same document this form now shows (#238).
      services.liveSettings?.publish(settings);
      if (!mounted) return;
      setState(() => _loaded = settings);
      _populate(settings);
      _toast('Instellingen herladen.');
    } on Object catch (e) {
      if (mounted) _toast('Kon niet herladen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _populate(AppSettings s) {
    _schoolPrefix.text = s.schoolPrefix;
    _debugMode = s.debugMode;

    _staffWifiSsid.text = s.staffWifi.ssid;
    _staffWifiCode.text = s.staffWifi.code;
    _studentWifiSsid.text = s.studentWifi.ssid;
    _studentWifiCode.text = s.studentWifi.code;

    _wisaServer.text = s.wisa.server;
    _wisaPort.text = s.wisa.port;
    _wisaDatabase.text = s.wisa.database;
    _wisaUsername.text = s.wisa.username;
    _wisaPassword.clear();
    _workDateIsNow = s.wisa.workDate.isNow;
    _workDate = s.wisa.workDate.date;
    _virtualWorkDateIsNow = s.wisa.virtualWorkDate.isNow;
    _virtualWorkDate = s.wisa.virtualWorkDate.date;

    _ssUri.text = s.smartschool.uri;
    _ssTestUser.text = s.smartschool.testUser;
    _ssStudentGroup.text = s.smartschool.studentGroup;
    _ssStaffGroup.text = s.smartschool.staffGroup;
    _ssRoots.text = s.smartschoolRoots.join(', ');
    _ssPassphrase.clear();
    _ssUseGrades = s.smartschool.useGrades;
    _ssUseYears = s.smartschool.useYears;
    for (var i = 0; i < _grades.length; i++) {
      _grades[i].text =
          i < s.smartschool.grades.length ? s.smartschool.grades[i] : '';
    }
    for (var i = 0; i < _years.length; i++) {
      _years[i].text =
          i < s.smartschool.years.length ? s.smartschool.years[i] : '';
    }
    _ssRules = List<SmartschoolImportRule>.of(s.smartschoolRules);
    _wisaRules = List<WisaImportRule>.of(s.wisaRules);
    _wisaRuleProvenance = Map<String, RuleProvenance>.of(s.wisaRuleProvenance);

    _azClientId.text = s.azure.clientId;
    _azTenantId.text = s.azure.tenantId;
    _azDomain.text = s.azure.domain;

    _wisaSchools = List<WisaSchoolProfile>.of(s.wisaSchools);
  }

  /// Flips the `ours` flag on the profile at [index] (the toggle the operator
  /// uses to mark a managed school).
  void _toggleSchoolOurs(int index, bool ours) {
    toggle(
        () => _wisaSchools[index] = _wisaSchools[index].copyWith(ours: ours));
  }

  /// Flips the `virtual` flag on the profile at [index] (#203). Independent of
  /// `ours`: a virtual school is pulled with the separate virtual work date,
  /// whether or not we manage it.
  void _toggleSchoolVirtual(int index, bool virtual) {
    toggle(() =>
        _wisaSchools[index] = _wisaSchools[index].copyWith(virtual: virtual));
  }

  // ---------------------------------------------------------------------------
  // Smartschool import rules (#202)
  // ---------------------------------------------------------------------------

  /// Prompts for a group name and appends a new rule of [kind]. Cancelling the
  /// prompt leaves the list untouched.
  Future<void> _addSmartschoolRule(_SmartschoolRuleKind kind) async {
    final name = await _promptRuleGroupName(kind: kind);
    if (name == null || !mounted) return;
    toggle(() => _ssRules = <SmartschoolImportRule>[..._ssRules, kind(name)]);
  }

  /// Re-prompts for the group name of the rule at [index], keeping its kind.
  Future<void> _editSmartschoolRule(int index) async {
    final rule = _ssRules[index];
    final kind = _SmartschoolRuleKind.of(rule);
    final name = await _promptRuleGroupName(
      kind: kind,
      initial: _smartschoolRuleGroupName(rule),
    );
    if (name == null || !mounted) return;
    toggle(() {
      _ssRules = List<SmartschoolImportRule>.of(_ssRules)..[index] = kind(name);
    });
  }

  /// Drops the rule at [index] from the working list.
  void _removeSmartschoolRule(int index) {
    toggle(() {
      _ssRules = List<SmartschoolImportRule>.of(_ssRules)..removeAt(index);
    });
  }

  /// Asks for the Smartschool group name a rule applies to. Returns the trimmed
  /// name, or `null` when the operator cancels.
  ///
  /// Free text rather than a picker on purpose: this view's seams are the
  /// settings store, the vault and the WISA school fetcher — there is no
  /// Smartschool snapshot here to pick from — and a rule has to be authorable
  /// *before* the first pull, which is exactly the state a fresh install is in.
  /// It also matches the legacy dialog.
  Future<String?> _promptRuleGroupName({
    required _SmartschoolRuleKind kind,
    String initial = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _RuleGroupNameDialog(kind: kind, initial: initial),
    );
  }

  // ---------------------------------------------------------------------------
  // WISA import rules (#273)
  // ---------------------------------------------------------------------------

  /// Prompts for the rule's field(s) and appends a new rule of [kind].
  /// Cancelling the prompt leaves the list untouched.
  Future<void> _addWisaRule(_WisaRuleKind kind) async {
    final values = await _promptWisaRule(kind: kind);
    if (values == null || !mounted) return;
    final rule = kind(values);
    toggle(() {
      _wisaRules = <WisaImportRule>[..._wisaRules, rule];
      _stampWisaRule(rule);
    });
  }

  /// Re-prompts for the field(s) of the rule at [index], keeping its kind. Every
  /// kind is editable, including the two school-marking ones **Toevoegen** does
  /// not offer — a document that already carries one must stay correctable.
  ///
  /// The edited rule is re-stamped (#285): changing what a rule matches makes it
  /// a different standing decision, and attributing it to whoever wrote the
  /// *previous* one would be a lie about a record whose whole purpose is saying
  /// who to ask.
  Future<void> _editWisaRule(int index) async {
    final rule = _wisaRules[index];
    final kind = _WisaRuleKind.of(rule);
    final values = await _promptWisaRule(
      kind: kind,
      initial: _wisaRuleValues(rule),
    );
    if (values == null || !mounted) return;
    final edited = kind(values);
    toggle(() {
      _wisaRules = List<WisaImportRule>.of(_wisaRules)..[index] = edited;
      _pruneWisaProvenance();
      _stampWisaRule(edited);
    });
  }

  /// Drops the WISA rule at [index] from the working list, and its provenance
  /// with it (#285).
  void _removeWisaRule(int index) {
    toggle(() {
      _wisaRules = List<WisaImportRule>.of(_wisaRules)..removeAt(index);
      _pruneWisaProvenance();
    });
  }

  /// Records this session as the author of [rule] (#285).
  ///
  /// No subject: this view holds no WISA snapshot to resolve a code against —
  /// the same reason #273's prompts are free text — so the name genuinely is
  /// unknown here and is recorded as such rather than guessed from the code the
  /// operator typed. The two fields that *are* known are the two the issue calls
  /// load-bearing: who, and when.
  void _stampWisaRule(WisaImportRule rule) {
    _wisaRuleProvenance = <String, RuleProvenance>{
      ..._wisaRuleProvenance,
      wisaRuleKey(rule): RuleProvenance(
        addedBy: _services?.operatorName ?? '',
        addedAt: DateTime.now(),
      ),
    };
  }

  /// Drops every provenance entry no rule in the working list claims any more.
  void _pruneWisaProvenance() {
    _wisaRuleProvenance = _prunedWisaProvenance(_wisaRules);
  }

  Map<String, RuleProvenance> _prunedWisaProvenance(
    List<WisaImportRule> rules,
  ) {
    return <String, RuleProvenance>{
      for (final rule in rules)
        if (_wisaRuleProvenance[wisaRuleKey(rule)] case final RuleProvenance p)
          wisaRuleKey(rule): p,
    };
  }

  /// Asks for the one or two values a WISA rule matches on. Returns the trimmed
  /// values in field order, or `null` when the operator cancels.
  ///
  /// Free text for the same reason the Smartschool prompt is: this view holds no
  /// WISA snapshot to pick a class name or institute code from, and a rule has to
  /// be authorable *before* the first pull.
  Future<List<String>?> _promptWisaRule({
    required _WisaRuleKind kind,
    List<String> initial = const <String>[],
  }) {
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _WisaRuleDialog(kind: kind, initial: initial),
    );
  }

  /// Whether the persisted WISA connection is complete enough to fetch the
  /// school list (#142): a non-empty server and a numeric port. Gated on the
  /// *loaded* document — "config is valid" means a saved, valid profile — so the
  /// operator saves a good profile before the fetch action lights up.
  bool get _wisaConfigValid {
    final w = _loaded?.wisa;
    if (w == null) return false;
    return w.server.trim().isNotEmpty && int.tryParse(w.port.trim()) != null;
  }

  /// Whether the "fetch schools" action can run right now: a valid config, a
  /// wired fetcher, and no fetch already in flight.
  bool get _canFetchSchools =>
      _wisaConfigValid &&
      !_fetchingSchools &&
      _services?.fetchWisaSchools != null;

  /// Refreshes the known-WISA-school list from the API (#171). "Scholen ophalen"
  /// is a *refresh* now, not the primary way to build the list: it merges the
  /// fetched id+name records into [_wisaSchools], updating each name, adding any
  /// genuinely new school (unmanaged by default), and preserving the `ours` and
  /// `virtual` marks on schools already known. Prefers a freshly typed password;
  /// otherwise resolves the stored secret. Failures surface as a toast.
  ///
  /// The merged list stays **dirty until Opslaan**, deliberately (#207): a fetch
  /// adds schools to the operator's curated list, and the working copy it merges
  /// into may already hold unsaved `ours`/`virtual` edits — persisting behind
  /// their back would commit those too and take away the reload escape hatch.
  /// What used to make that a trap was that the names arrived here and nowhere
  /// else; every sync now writes the two derived halves back into the document
  /// on its own, so the grid names its schools whether or not this button was
  /// ever pressed.
  Future<void> _fetchWisaSchools() async {
    final services = _services;
    final fetcher = services?.fetchWisaSchools;
    final loaded = _loaded;
    if (services == null || fetcher == null || loaded == null) return;
    setState(() => _fetchingSchools = true);
    try {
      var password = _wisaPassword.text;
      if (password.isEmpty) {
        password = await services.secrets.read(loaded.wisa.passwordRef) ?? '';
      }
      if (password.isEmpty) {
        if (mounted) {
          _toast('Geen WISA-wachtwoord beschikbaar. Vul het wachtwoord in en '
              'bewaar eerst.');
        }
        return;
      }
      final schools = await fetcher(loaded.wisa, password);
      if (!mounted) return;
      toggle(() => _wisaSchools = _mergeFetchedSchools(schools));
      _toast('${schools.length} scholen opgehaald.');
    } on Object catch (e) {
      if (mounted) _toast('Kon scholen niet ophalen: $e');
    } finally {
      if (mounted) setState(() => _fetchingSchools = false);
    }
  }

  /// Merges the [fetched] WISA schools (id + code + name) into the current known
  /// list: keeps every already-known school (preserving its
  /// `ours`/`virtual`/`prefix` marks, refreshing its code and name when the
  /// fetch supplies them) and appends any fetched school not yet known as
  /// neither managed nor virtual. Order is stable by school id so the grid does
  /// not jump.
  ///
  /// The merge rule itself lives in [mergeWisaSchoolProfiles], shared with the
  /// repair every sync runs against the stored profiles (#207), so the button
  /// and the silent backfill can never disagree about what a pull may overwrite.
  List<WisaSchoolProfile> _mergeFetchedSchools(List<WisaSchool> fetched) =>
      mergeWisaSchoolProfiles(
        profiles: _wisaSchools,
        schools: fetched,
        addUnknown: true,
      )..sort((a, b) => a.schoolId.compareTo(b.schoolId));

  /// Assembles an [AppSettings] from the form, preserving the loaded document's
  /// secret refs.
  /// The Smartschool roots as the document stores them: the comma-separated
  /// field split, trimmed, and stripped of the empties a stray comma leaves
  /// (#351).
  ///
  /// An emptied field really is an empty list, which the connector reads as
  /// "walk the whole tree" — the escape hatch for a tenant whose Smartschool
  /// has no such roots.
  List<String> _parsedRoots() => <String>[
        for (final name in _ssRoots.text.split(','))
          if (name.trim().isNotEmpty) name.trim(),
      ];

  AppSettings _collect(AppSettings base) {
    return base.copyWith(
      schoolPrefix: _schoolPrefix.text.trim(),
      debugMode: _debugMode,
      // Trimmed like every other field: the value is printed on paper and typed
      // back in by hand, so leading or trailing whitespace in a network name or
      // key is invisible on the sheet and unreproducible by the reader.
      staffWifi: WifiNetwork(
        ssid: _staffWifiSsid.text.trim(),
        code: _staffWifiCode.text.trim(),
      ),
      studentWifi: WifiNetwork(
        ssid: _studentWifiSsid.text.trim(),
        code: _studentWifiCode.text.trim(),
      ),
      wisa: base.wisa.copyWith(
        server: _wisaServer.text.trim(),
        port: _wisaPort.text.trim(),
        database: _wisaDatabase.text.trim(),
        username: _wisaUsername.text.trim(),
        workDate: WorkDateSetting(isNow: _workDateIsNow, date: _workDate),
        virtualWorkDate: WorkDateSetting(
          isNow: _virtualWorkDateIsNow,
          date: _virtualWorkDate,
        ),
      ),
      smartschool: base.smartschool.copyWith(
        uri: _ssUri.text.trim(),
        testUser: _ssTestUser.text.trim(),
        studentGroup: _ssStudentGroup.text.trim(),
        staffGroup: _ssStaffGroup.text.trim(),
        useGrades: _ssUseGrades,
        useYears: _ssUseYears,
        grades: <String>[for (final c in _grades) c.text.trim()],
        years: <String>[for (final c in _years) c.text.trim()],
      ),
      azure: base.azure.copyWith(
        clientId: _azClientId.text.trim(),
        tenantId: _azTenantId.text.trim(),
        domain: _azDomain.text.trim(),
      ),
      smartschoolRules: List<SmartschoolImportRule>.of(_ssRules),
      smartschoolRoots: _parsedRoots(),
      wisaRules: List<WisaImportRule>.of(_wisaRules),
      wisaRuleProvenance: _prunedWisaProvenance(_wisaRules),
      wisaSchools: List<WisaSchoolProfile>.of(_wisaSchools),
    );
  }

  Future<void> _save() async {
    final services = _services;
    final base = _loaded;
    if (services == null || base == null) return;

    setState(() => _busy = true);
    try {
      final next = _collect(base);
      await services.store.save(next);
      // Hand the saved document to the running reconcile stack (#238). Without
      // this the WISA pull kept using the werkdatum read at bootstrap, so the
      // save only took effect after a relaunch — and said so nowhere.
      services.liveSettings?.publish(next);

      // Secrets are write-only: a non-empty field replaces the stored value; a
      // blank one leaves it untouched. The value is never read back into the UI.
      final wisaPassword = _wisaPassword.text;
      if (wisaPassword.isNotEmpty) {
        await services.secrets.write(next.wisa.passwordRef, wisaPassword);
      }
      final passphrase = _ssPassphrase.text;
      if (passphrase.isNotEmpty) {
        await services.secrets
            .write(next.smartschool.passphraseRef, passphrase);
      }

      if (!mounted) return;
      setState(() => _loaded = next);
      _wisaPassword.clear();
      _ssPassphrase.clear();
      _toast('Instellingen opgeslagen.');
    } on Object catch (e) {
      if (mounted) _toast('Kon niet opslaan: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickWorkDate({required bool virtual}) async {
    final current = virtual ? _virtualWorkDate : _workDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (virtual) {
        _virtualWorkDate = picked;
      } else {
        _workDate = picked;
      }
    });
  }

  /// Applies [mutate] inside `setState` — the seam the form widget flips its
  /// switches through, so no `setState` call leaks outside this State subclass.
  void toggle(VoidCallback mutate) => setState(mutate);

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Whether Azure AD is configured for this launch. `null` bootstrap is exactly
  /// that claim: `main()` wires the settings seams only when the resolved
  /// [AadAppConfig] has a client and a tenant, because without them there is no
  /// token to read the settings document with.
  bool get _aadConfigured => widget.bootstrap != null;

  @override
  Widget build(BuildContext context) {
    // No early return for a failed or pending load (#370), and none for an
    // unconfigured Azure AD either (#384): the frame, the header and the
    // Verbinding tab render regardless, and only the four document-backed tabs
    // stand in with a panel until the document arrives.
    //
    // The second half is the whole point of #384. The screen that supplies the
    // sign-in configuration cannot sit behind the sign-in — an installed v1.0.0
    // did exactly that and had no way out of it.
    return _SettingsForm(state: this);
  }

  /// What the four document-backed tabs show while [_loaded] is `null` — no
  /// sign-in to load with, the load in flight, or the failure that stopped it.
  ///
  /// The retry lives here rather than in the header because this *is* the state
  /// it belongs to; the header's Herladen is wired to the same [_load] so either
  /// press does the same thing.
  Widget documentPanel() {
    if (!_aadConfigured) {
      // Deliberately no retry: there is nothing to retry *with* until the app is
      // relaunched against a saved app registration, and a button that cannot
      // work is worse than a sentence saying where to go.
      return const _MessagePanel(
        eyebrow: 'Arcadia · instellingen',
        title: 'Niet geconfigureerd',
        message: 'Azure AD is niet geconfigureerd, dus er is geen aanmelding '
            'om de gedeelde instellingen mee op te halen.\n\nVul de '
            'app-registratie in onder het tabblad Verbinding, bewaar, en start '
            'de app opnieuw op.',
      );
    }
    final Object? error = _error;
    if (error == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · instellingen',
        title: 'Laden…',
        message: 'De instellingen worden opgehaald.',
        progress: true,
      );
    }
    final String retryNote =
        _attempts > 1 ? '\n\n(Poging $_attempts mislukt.)' : '';
    return _MessagePanel(
      eyebrow: 'Arcadia · instellingen',
      title: 'Kon de instellingen niet laden',
      message: '$error$retryNote\n\nDe backend-coördinaten waar deze '
          'instellingen vandaan komen, staan onder het tabblad Verbinding.',
      action: FilledButton(
        key: const ValueKey('settings-retry'),
        onPressed: _busy ? null : _load,
        child: const Text('Opnieuw proberen'),
      ),
    );
  }
}

/// The scrolling settings form. A thin view over [_SettingsScreenState]'s
/// controllers and working copies, so all mutation — and, since #273, every
/// value the form renders — stays in one place.
class _SettingsForm extends StatelessWidget {
  const _SettingsForm({required this.state});

  final _SettingsScreenState state;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;

    final bool hasDocument = state._loaded != null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Shared header + actions: kept above the tabs so Save/Herladen
            // act on the whole document regardless of the active tab.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PlinkSpacing.s6,
                PlinkSpacing.s6,
                PlinkSpacing.s6,
                PlinkSpacing.s4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Eyebrow('Arcadia · instellingen', onInk: ink),
                  const SizedBox(height: PlinkSpacing.s4),
                  Text('Instellingen', style: text.headlineMedium),
                  const SizedBox(height: PlinkSpacing.s3),
                  Text(
                    'Bewerk de configuratie en bewaar. Wachtwoorden worden '
                    'alleen geschreven — laat een veld leeg om de bestaande '
                    'waarde te behouden.',
                    style: text.bodyMedium,
                  ),
                  const SizedBox(height: PlinkSpacing.s4),
                  Wrap(
                    spacing: PlinkSpacing.s3,
                    runSpacing: PlinkSpacing.s2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      FilledButton.icon(
                        key: const ValueKey('settings-save'),
                        // Nothing to save without a document to base the save
                        // on (#370) — `_collect` needs one, and an enabled
                        // button that silently does nothing is worse than a
                        // disabled one.
                        onPressed:
                            state._busy || !hasDocument ? null : state._save,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Opslaan'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('settings-reload'),
                        // The same button is the retry while the document is
                        // missing: `_reload` needs the seams `_load`
                        // bootstraps, so a failed bootstrap has to go through
                        // `_load` or nothing happens at all. With no Azure AD
                        // configured there is nothing to bootstrap *from*
                        // (#384), so it is disabled rather than a button that
                        // silently does nothing.
                        onPressed: state._busy || !state._aadConfigured
                            ? null
                            : (hasDocument ? state._reload : state._load),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Herladen'),
                      ),
                    ],
                  ),
                  if (state._busy) ...<Widget>[
                    const SizedBox(height: PlinkSpacing.s4),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
            TabBar(
              key: const ValueKey('settings-tabs'),
              controller: state._tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: const <Widget>[
                Tab(key: ValueKey('settings-tab-algemeen'), text: 'Algemeen'),
                Tab(key: ValueKey('settings-tab-wisa'), text: 'Wisa'),
                Tab(
                  key: ValueKey('settings-tab-smartschool'),
                  text: 'Smartschool',
                ),
                Tab(key: ValueKey('settings-tab-azure'), text: 'Azure'),
                // Last, and the only tab that does not need the document
                // (#370).
                Tab(
                  key: ValueKey('settings-tab-verbinding'),
                  text: 'Verbinding',
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: state._tabs,
                children: <Widget>[
                  if (hasDocument) ...<Widget>[
                    _algemeenTab(),
                    _wisaTab(),
                    _smartschoolTab(),
                    _azureTab(),
                  ] else
                    for (var i = 0; i < _connectionTabIndex; i++)
                      state.documentPanel(),
                  _connectionTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A scrolling tab body with the shared page padding.
  Widget _tab(String keyValue, List<Widget> children) {
    return ListView(
      key: ValueKey(keyValue),
      padding: const EdgeInsets.symmetric(
        horizontal: PlinkSpacing.s6,
        vertical: PlinkSpacing.s5,
      ),
      children: children,
    );
  }

  /// App-wide options: school prefix, debug mode, and the werkdatum controls
  /// (app-wide, not connector-specific — #140).
  Widget _algemeenTab() {
    return _tab('settings-tab-algemeen-body', <Widget>[
      _Section(
        title: 'Algemeen',
        children: <Widget>[
          _Field(
            keyValue: 'settings-school-prefix',
            label: 'Schoolprefix',
            controller: state._schoolPrefix,
          ),
          SwitchListTile(
            key: const ValueKey('settings-debug-mode'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Debugmodus'),
            value: state._debugMode,
            onChanged: (v) => state.toggle(() => state._debugMode = v),
          ),
        ],
      ),
      _Section(
        title: 'Werkdatum',
        children: <Widget>[
          _WorkDateField(
            keyValue: 'settings-workdate',
            label: 'Werkdatum',
            isNow: state._workDateIsNow,
            date: state._workDate,
            onIsNowChanged: (v) => state.toggle(() => state._workDateIsNow = v),
            onPick: () => state._pickWorkDate(virtual: false),
          ),
          _WorkDateField(
            keyValue: 'settings-virtual-workdate',
            label: 'Werkdatum Virtuele School',
            isNow: state._virtualWorkDateIsNow,
            date: state._virtualWorkDate,
            onIsNowChanged: (v) =>
                state.toggle(() => state._virtualWorkDateIsNow = v),
            onPick: () => state._pickWorkDate(virtual: true),
          ),
        ],
      ),
      _wifiSection(),
    ]);
  }

  /// The per-machine bootstrap: the Azure AD app registration (#384) and the
  /// backend coordinates (#370).
  ///
  /// A tab rather than a section under Algemeen, and the last one, because it is
  /// the only body here that does not read the settings document: everything
  /// else on this screen is unreachable exactly when this is needed. The version
  /// and its update check (#371) slot in for the same reason: it is deployment
  /// identity, not school configuration, and it has to be readable on an install
  /// whose settings document will not load — "which version is this operator
  /// on?" is the first question a support conversation asks.
  ///
  /// Azure AD comes **first** on the tab. It is the outermost of the three: with
  /// no app registration there is no token, with no token there is no Cosmos,
  /// and with no Cosmos there are no settings. A fresh install works down the
  /// tab in exactly that order.
  Widget _connectionTab() {
    return _tab('settings-tab-verbinding-body', <Widget>[
      _aadSection(),
      _connectionSection(),
      _versionSection(),
    ]);
  }

  /// How this tab names the layer that answered for one half of the bootstrap
  /// (#370 endpoints, #384 Azure AD, #387 the seed beside the executable).
  ///
  /// Two files can be called `connection.json` since #387 — this machine's own
  /// under `%APPDATA%` and a seed IT dropped next to the installed program — so
  /// "uit connection.json" stopped being a complete sentence: the operator has
  /// to be told *which* one answered. The shadowed case is said out loud for the
  /// same reason and is the sharper one: an IT that edits the seed on a machine
  /// which already has a local file sees nothing change, and this line is the
  /// only place in the app that can explain why.
  ///
  /// [subject] names what the sentence is about, so the fallback case can say
  /// which values the files are silent on rather than making the operator infer
  /// it from an empty field.
  String _sourceNote({
    required ResolvedConnection? resolved,
    required ConnectionSource? source,
    required String reading,
    required String subject,
  }) {
    if (resolved == null || source == null) return reading;
    final String location = state._connection.store.location;
    final String seed = resolved.seedLocation;
    return switch (source) {
      ConnectionSource.file => 'Huidige bron: uit $location.'
          '${resolved.hasSeed ? ' Naast het programma staat ook een '
              '$connectionFileName ($seed); dit bestand heeft voorrang '
              'daarop.' : ''}',
      ConnectionSource.seed =>
        'Huidige bron: uit $seed — de $connectionFileName die naast het '
            'programma staat. Bewaren schrijft naar $location, dat daarna '
            'voorrang heeft.',
      ConnectionSource.defaults => 'Huidige bron: standaardwaarde van deze '
          'build. $subject staan niet in $location'
          '${resolved.hasSeed ? ' en niet in $seed' : ''}.',
    };
  }

  /// The Azure AD app registration this install signs in with (#384).
  ///
  /// Four identifiers, no secret: a public-client app registration needs none,
  /// and the tokens it mints live in the DPAPI-encrypted broker cache. That is
  /// why they can sit in the same plain-JSON file as the endpoints, and why the
  /// section can render before anybody has signed in.
  Widget _aadSection() {
    final ResolvedConnection? resolved = state._resolved;
    final bool configured = resolved?.aad.isConfigured ?? false;

    return _Section(
      title: 'Azure AD',
      children: <Widget>[
        _Note(
          keyValue: 'settings-aad-note',
          text: 'De app-registratie waarmee deze installatie zich aanmeldt. '
              'Deze waarden staan lokaal op deze machine, in hetzelfde bestand '
              'als de verbindingsgegevens hieronder — niet in het gedeelde '
              'instellingendocument, want dat document staat achter deze '
              'aanmelding. Het zijn identificatoren, geen geheimen.',
        ),
        _Note(
          keyValue: 'settings-aad-source',
          text: _sourceNote(
            resolved: resolved,
            source: resolved?.aadSource,
            reading: 'De app-registratie wordt gelezen…',
            subject: 'De Azure AD-gegevens',
          ),
        ),
        // Said plainly rather than left to be inferred from two empty fields:
        // this is the state an installed build launches in, and the operator
        // needs to know that filling these in is the whole job.
        if (resolved != null && !configured)
          _Note(
            keyValue: 'settings-aad-incomplete',
            text: 'Aanmelden is nog niet mogelijk: vul minstens de client-id '
                'en de tenant-id in, bewaar, en start de app opnieuw op.',
          ),
        _Field(
          keyValue: 'settings-aad-client-id',
          label: 'Client-id (app-registratie)',
          controller: state._aadClientId,
        ),
        _Field(
          keyValue: 'settings-aad-tenant-id',
          label: 'Tenant-id',
          controller: state._aadTenantId,
        ),
        _Field(
          keyValue: 'settings-aad-domain',
          label: 'Azure-domein (bv. school.onmicrosoft.com)',
          controller: state._aadDomain,
        ),
        _Field(
          keyValue: 'settings-aad-school-prefix',
          label: 'Schoolprefix (terugval; de instellingen winnen)',
          controller: state._aadSchoolPrefix,
        ),
        _Note(
          keyValue: 'settings-aad-save-hint',
          text: 'Bewaren gebeurt met "Verbinding bewaren" hieronder: beide '
              'delen staan in één bestand.',
        ),
      ],
    );
  }

  /// The running build's version, and the check for a newer one (#371).
  Widget _versionSection() {
    final UpdateController? update = state.widget.update;
    if (update == null) return const _VersionSection(controller: null);
    return ListenableBuilder(
      listenable: update,
      builder: (BuildContext context, Widget? _) =>
          _VersionSection(controller: update),
    );
  }

  Widget _connectionSection() {
    final ResolvedConnection? resolved = state._resolved;
    final ConnectionProbe? probe = state._connection.probe;
    final List<ConnectionProbeResult>? probed = state._probed;
    final bool busy = state._connectionBusy;

    return _Section(
      title: 'Verbinding',
      children: <Widget>[
        _Note(
          keyValue: 'settings-connection-note',
          text: 'Waar de gedeelde opslag van deze installatie staat. Deze '
              'waarden staan lokaal op deze machine — niet in het gedeelde '
              'instellingendocument, want dat document staat er zelf achter.',
        ),
        _Note(
          keyValue: 'settings-connection-source',
          text: _sourceNote(
            resolved: resolved,
            source: resolved?.source,
            reading: 'De verbindingsgegevens worden gelezen…',
            subject: 'De verbindingsgegevens',
          ),
        ),
        if (resolved != null && resolved.hasWarning)
          _Note(
            keyValue: 'settings-connection-warning',
            text: resolved.warning,
          ),
        _Field(
          keyValue: 'settings-connection-cosmos-endpoint',
          label: 'Cosmos-endpoint',
          controller: state._cosmosEndpoint,
        ),
        _Field(
          keyValue: 'settings-connection-cosmos-database',
          label: 'Cosmos-database',
          controller: state._cosmosDatabase,
        ),
        _Field(
          keyValue: 'settings-connection-vault-uri',
          label: 'Key Vault-URI',
          controller: state._vaultUri,
        ),
        _Field(
          keyValue: 'settings-connection-blob-endpoint',
          label: 'Blob-endpoint',
          controller: state._blobEndpoint,
        ),
        _Field(
          keyValue: 'settings-connection-blob-container',
          label: 'Blob-container',
          controller: state._blobContainer,
        ),
        _Field(
          keyValue: 'settings-connection-signalr-endpoint',
          label: 'SignalR-endpoint (leeg = geen realtime updates)',
          controller: state._signalrEndpoint,
        ),
        _Field(
          keyValue: 'settings-connection-signalr-hub',
          label: 'SignalR-hub',
          controller: state._signalrHub,
        ),
        Wrap(
          spacing: PlinkSpacing.s3,
          runSpacing: PlinkSpacing.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            // Writes both halves of the file — the coordinates above and the
            // Azure AD app registration at the top of the tab (#384). One
            // button because it is one file, and because on a fresh install
            // filling both in is one job.
            FilledButton.icon(
              key: const ValueKey('settings-connection-save'),
              onPressed: busy ? null : state._saveConnection,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Verbinding bewaren'),
            ),
            // Absent rather than present-and-inert on a build with no session to
            // mint tokens from: a button that can never answer is worse than no
            // button.
            if (probe != null)
              OutlinedButton.icon(
                key: const ValueKey('settings-connection-test'),
                onPressed: busy ? null : state._testConnection,
                icon: const Icon(Icons.network_check_outlined),
                label: const Text('Verbinding testen'),
              ),
            OutlinedButton(
              key: const ValueKey('settings-connection-defaults'),
              onPressed: busy ? null : state._fillConnectionDefaults,
              child: const Text('Standaardwaarden invullen'),
            ),
          ],
        ),
        if (busy) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          const LinearProgressIndicator(
            key: ValueKey('settings-connection-busy'),
          ),
        ],
        if (state._connectionMessage.isNotEmpty) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          _Note(
            keyValue: 'settings-connection-message',
            text: state._connectionMessage,
          ),
        ],
        if (state._connectionNeedsRelaunch)
          _Note(
            keyValue: 'settings-connection-relaunch',
            text: 'Herstart de app om deze gegevens te gebruiken. De huidige '
                'sessie praat nog met de opslag waarmee ze opgestart is, en is '
                'nog aangemeld met de app-registratie waarmee ze opgestart is.',
          ),
        if (probed != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          for (final ConnectionProbeResult r in probed)
            _Note(
              keyValue: 'settings-connection-probe-${r.id}',
              text: r.ok
                  ? '${r.label}: bereikbaar.'
                  : '${r.label}: niet bereikbaar — ${r.detail}',
            ),
        ],
      ],
    );
  }

  /// The two networks printed on the password sheets (#368).
  ///
  /// They used to be string literals in the export code, so rotating a WiFi key
  /// — the ordinary reason to change one, or the urgent one after it leaks —
  /// meant editing Dart and redistributing the app. Emptying an SSID omits that
  /// sheet's WiFi block entirely, the same way the Office 365 and Smartschool
  /// blocks disappear when there is no password to print.
  Widget _wifiSection() {
    return _Section(
      title: 'WiFi op de wachtwoordbladen',
      children: <Widget>[
        _Note(
          keyValue: 'settings-wifi-note',
          text:
              'Deze netwerken worden op de afgedrukte wachtwoordbladen gezet. '
              'Laat een netwerknaam leeg om het WiFi-blok van dat blad weg te '
              'laten.',
        ),
        _Field(
          keyValue: 'settings-wifi-staff-ssid',
          label: 'WiFi personeel — netwerknaam',
          controller: state._staffWifiSsid,
        ),
        _Field(
          keyValue: 'settings-wifi-staff-code',
          label: 'WiFi personeel — code',
          controller: state._staffWifiCode,
        ),
        _Field(
          keyValue: 'settings-wifi-student-ssid',
          label: 'WiFi leerlingen — netwerknaam',
          controller: state._studentWifiSsid,
        ),
        _Field(
          keyValue: 'settings-wifi-student-code',
          label: 'WiFi leerlingen — code',
          controller: state._studentWifiCode,
        ),
      ],
    );
  }

  /// WISA connector config: connection, credentials, managed-school list, and
  /// the WISA import-rule editor (#273).
  Widget _wisaTab() {
    return _tab('settings-tab-wisa-body', <Widget>[
      _Section(
        title: 'WISA',
        children: <Widget>[
          _Field(
            keyValue: 'settings-wisa-server',
            label: 'Server',
            controller: state._wisaServer,
          ),
          _Field(
            keyValue: 'settings-wisa-port',
            label: 'Poort',
            controller: state._wisaPort,
            keyboardType: TextInputType.number,
          ),
          _Field(
            keyValue: 'settings-wisa-database',
            label: 'Database',
            controller: state._wisaDatabase,
          ),
          _Field(
            keyValue: 'settings-wisa-username',
            label: 'Gebruikersnaam',
            controller: state._wisaUsername,
          ),
          _SecretField(
            keyValue: 'settings-wisa-password',
            label: 'Wachtwoord (alleen schrijven)',
            controller: state._wisaPassword,
          ),
        ],
      ),
      _Section(
        title: 'WISA-scholen (beheerd)',
        children: <Widget>[
          _WisaSchoolsEditor(state: state),
        ],
      ),
      _Section(
        title: 'Importregels',
        children: <Widget>[
          _WisaRulesEditor(state: state),
        ],
      ),
    ]);
  }

  /// Smartschool connector config: connection, credentials, grade/year
  /// vocabulary, and the Smartschool import-rule editor (#202).
  Widget _smartschoolTab() {
    return _tab('settings-tab-smartschool-body', <Widget>[
      _Section(
        title: 'Smartschool',
        children: <Widget>[
          _Field(
            keyValue: 'settings-ss-uri',
            label: 'URI',
            controller: state._ssUri,
          ),
          _Field(
            keyValue: 'settings-ss-test-user',
            label: 'Testgebruiker',
            controller: state._ssTestUser,
          ),
          _Field(
            keyValue: 'settings-ss-student-group',
            label: 'Pad leerlingengroep',
            controller: state._ssStudentGroup,
          ),
          _Field(
            keyValue: 'settings-ss-staff-group',
            label: 'Pad personeelsgroep',
            controller: state._ssStaffGroup,
          ),
          _Field(
            keyValue: 'settings-ss-roots',
            label: 'Hoofdgroepen om op te halen (gescheiden door komma\'s)',
            controller: state._ssRoots,
          ),
          _SecretField(
            keyValue: 'settings-ss-passphrase',
            label: 'Passphrase (alleen schrijven)',
            controller: state._ssPassphrase,
          ),
          SwitchListTile(
            key: const ValueKey('settings-ss-use-grades'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Gebruik graden'),
            value: state._ssUseGrades,
            onChanged: (v) => state.toggle(() => state._ssUseGrades = v),
          ),
          for (var i = 0; i < state._grades.length; i++)
            _Field(
              keyValue: 'settings-ss-grade-$i',
              label: 'Graad ${i + 1}',
              controller: state._grades[i],
            ),
          SwitchListTile(
            key: const ValueKey('settings-ss-use-years'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Gebruik jaren'),
            value: state._ssUseYears,
            onChanged: (v) => state.toggle(() => state._ssUseYears = v),
          ),
          for (var i = 0; i < state._years.length; i++)
            _Field(
              keyValue: 'settings-ss-year-$i',
              label: 'Jaar ${i + 1}',
              controller: state._years[i],
            ),
        ],
      ),
      _Section(
        title: 'Importregels',
        children: <Widget>[
          _SmartschoolRulesEditor(state: state),
        ],
      ),
    ]);
  }

  /// Azure AD / Office 365 connector config.
  Widget _azureTab() {
    return _tab('settings-tab-azure-body', <Widget>[
      _Section(
        title: 'Azure AD / Office 365',
        children: <Widget>[
          _Field(
            keyValue: 'settings-az-client-id',
            label: 'Client ID',
            controller: state._azClientId,
          ),
          _Field(
            keyValue: 'settings-az-tenant-id',
            label: 'Tenant ID',
            controller: state._azTenantId,
          ),
          _Field(
            keyValue: 'settings-az-domain',
            label: 'Domein',
            controller: state._azDomain,
          ),
        ],
      ),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s4),
      padding: const EdgeInsets.all(PlinkSpacing.s5),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: text.titleMedium),
          const SizedBox(height: PlinkSpacing.s3),
          ...children,
        ],
      ),
    );
  }
}

/// The running build's version and its update check (#371).
///
/// Deliberately the *only* place the update mechanism can be operated from — the
/// shell's offer bar reacts to a check, but the check itself, the version it
/// compares against and the failure that stopped it are all read here, on
/// demand. That split is what keeps a failed check silent: the news has a place
/// to sit without going looking for the operator.
class _VersionSection extends StatelessWidget {
  const _VersionSection({required this.controller});

  /// This session's check, or `null` on a build with no update mechanism — the
  /// version then reads as unknown and no button is offered, rather than a
  /// button that can never answer.
  final UpdateController? controller;

  @override
  Widget build(BuildContext context) {
    final UpdateController? update = controller;
    final String installed = update?.installedVersion ?? '';
    final AppRelease? offered = update?.availableRelease;
    // The notes of the version now *running* (#395) — a different thing from
    // `offered`, which is the version not running yet.
    final AppRelease? running = update?.releaseNotes;
    final bool busy = update?.busy ?? false;

    return _Section(
      title: 'Versie',
      children: <Widget>[
        _Note(
          keyValue: 'settings-version-current',
          text: installed.isEmpty
              ? 'Geïnstalleerde versie: onbekend.'
              : 'Geïnstalleerde versie: $installed.',
        ),
        _Note(
          keyValue: 'settings-version-status',
          text: switch (update?.phase) {
            null => 'Deze build heeft geen updatecontrole.',
            UpdatePhase.idle => 'Er is nog niet gecontroleerd op updates.',
            UpdatePhase.checking => 'Er wordt gecontroleerd op updates…',
            _ => update!.message,
          },
        ),
        if (offered != null && offered.notes.trim().isNotEmpty)
          _Note(
            keyValue: 'settings-version-notes',
            text: offered.notes.trim(),
          ),
        if (update != null)
          Wrap(
            spacing: PlinkSpacing.s3,
            runSpacing: PlinkSpacing.s2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OutlinedButton.icon(
                key: const ValueKey('settings-version-check'),
                onPressed: busy ? null : update.check,
                icon: const Icon(Icons.refresh),
                label: const Text('Controleren op updates'),
              ),
              // What makes the dismissed dialog recoverable (#395), and the
              // reason it belongs here rather than anywhere else: this section
              // already answers "which version am I running?", and "what
              // changed in it?" is the same question one step further. Present
              // only when there is a body to show, so it can never open empty.
              if (running != null)
                TextButton.icon(
                  key: const ValueKey('settings-version-notes-open'),
                  onPressed: () => ReleaseNotesDialog.show(context, running),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('Wat is er nieuw'),
                ),
              // Present only when there is genuinely something to apply. This is
              // the consent gate: no code path reaches `apply()` except this
              // button and the shell's **Bijwerken**.
              if (offered != null)
                FilledButton.icon(
                  key: const ValueKey('settings-version-apply'),
                  onPressed: busy ? null : update.apply,
                  icon: const Icon(Icons.system_update_alt_outlined),
                  label: Text('Bijwerken naar ${offered.version}'),
                ),
            ],
          ),
        if (update?.phase == UpdatePhase.downloading) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          LinearProgressIndicator(
            key: const ValueKey('settings-version-progress'),
            value: update!.progress > 0 ? update.progress : null,
          ),
        ],
      ],
    );
  }
}

/// One line of explanation above a section's fields — the same muted prose the
/// rule editors put over their lists.
class _Note extends StatelessWidget {
  const _Note({required this.keyValue, required this.text});

  final String keyValue;
  final String text;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s3),
      child: Text(
        text,
        key: ValueKey(keyValue),
        style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.keyValue,
    required this.label,
    required this.controller,
    this.keyboardType,
  });

  final String keyValue;
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s3),
      child: TextField(
        key: ValueKey(keyValue),
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

/// A write-only credential field: obscured, never populated from the provider,
/// with a hint that a blank field keeps the stored value.
class _SecretField extends StatelessWidget {
  const _SecretField({
    required this.keyValue,
    required this.label,
    required this.controller,
  });

  final String keyValue;
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s3),
      child: TextField(
        key: ValueKey(keyValue),
        controller: controller,
        obscureText: true,
        autofillHints: const <String>[],
        decoration: InputDecoration(
          labelText: label,
          hintText: 'Laat leeg om de bestaande waarde te behouden',
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _WorkDateField extends StatelessWidget {
  const _WorkDateField({
    required this.keyValue,
    required this.label,
    required this.isNow,
    required this.date,
    required this.onIsNowChanged,
    required this.onPick,
  });

  final String keyValue;
  final String label;
  final bool isNow;
  final DateTime? date;
  final ValueChanged<bool> onIsNowChanged;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String pinned = date == null
        ? 'geen datum gekozen'
        : '${date!.year}-${date!.month.toString().padLeft(2, '0')}-'
            '${date!.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile(
            key: ValueKey('$keyValue-is-now'),
            contentPadding: EdgeInsets.zero,
            // The field's label sits on the left; the "volg de huidige datum"
            // instruction is pushed to the right so it reads against the switch
            // it controls (currently off ⇒ today's date is *not* followed) —
            // not against the werkdatum field on the left (#141).
            title: Row(
              children: <Widget>[
                Expanded(child: Text(label)),
                const Text(
                  'volg de huidige datum',
                  textAlign: TextAlign.right,
                ),
              ],
            ),
            value: isNow,
            onChanged: onIsNowChanged,
          ),
          if (!isNow)
            Row(
              children: <Widget>[
                Text(pinned, style: text.bodyMedium),
                const SizedBox(width: PlinkSpacing.s3),
                OutlinedButton(
                  key: ValueKey('$keyValue-pick'),
                  onPressed: onPick,
                  child: const Text('Kies datum'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The value(s) a WISA rule matches on, in the field order [_WisaRuleKind]
/// declares — what the edit prompt opens on. The sealed base type carries no
/// shared field, so a switch over the three cases is where they meet.
List<String> _wisaRuleValues(WisaImportRule rule) => switch (rule) {
      DontImportClass(:final className) => <String>[className],
      DontImportUserFromWisa(:final userCode) => <String>[userCode],
      ReplaceInstitute(:final original, :final replacement) => <String>[
          original,
          replacement,
        ],
    };

/// The three WISA import rules, with the Dutch labels and the field prompts the
/// editor authors them through (#273). Calling a kind builds its rule from the
/// values the prompt collected, in [fields] order.
///
/// Every kind is on the **Toevoegen** menu. The two that were not — the
/// school-marking `MarkAsVirtual` and `MarkAsOurs`, which duplicated the
/// WISA-scholen grid above — are gone from the rule hierarchy entirely (#277,
/// #286), so the grid is the only place either flag is set.
enum _WisaRuleKind {
  dontImportClass(
    label: 'Klas niet importeren',
    explanation: 'De klasgroep wordt niet uit WISA ingelezen.',
    fields: <String>['Klasnaam'],
    hints: <String>['Naam zoals ze in WISA staat'],
  ),
  dontImportUser(
    label: 'Personeelslid niet importeren',
    explanation: 'Het personeelslid wordt niet uit WISA ingelezen.',
    fields: <String>['Personeelscode'],
    hints: <String>['De WISA-code van het personeelslid'],
  ),
  replaceInstitute(
    label: 'Vervang instituut',
    explanation: 'Klasgroepen van het eerste instituut worden ingelezen alsof '
        'ze bij het tweede horen.',
    fields: <String>['Oude instituutcode', 'Nieuwe instituutcode'],
    hints: <String>['Code zoals WISA ze levert', 'Code zoals wij ze willen'],
  );

  const _WisaRuleKind({
    required this.label,
    required this.explanation,
    required this.fields,
    required this.hints,
  });

  /// The menu / dialog label.
  final String label;

  /// One line telling the operator what the rule does to the import.
  final String explanation;

  /// The prompt's field labels, in the order [call] consumes them.
  final List<String> fields;

  /// Per-field placeholder text, parallel to [fields].
  final List<String> hints;

  /// The kinds **Toevoegen** offers — all of them, since the two the menu used
  /// to hide were deleted rather than hidden (#277, #286).
  static List<_WisaRuleKind> get addable => _WisaRuleKind.values;

  WisaImportRule call(List<String> values) => switch (this) {
        _WisaRuleKind.dontImportClass => DontImportClass(values[0]),
        _WisaRuleKind.dontImportUser => DontImportUserFromWisa(values[0]),
        _WisaRuleKind.replaceInstitute => ReplaceInstitute(
            original: values[0],
            replacement: values[1],
          ),
      };

  static _WisaRuleKind of(WisaImportRule rule) => switch (rule) {
        DontImportClass() => _WisaRuleKind.dontImportClass,
        DontImportUserFromWisa() => _WisaRuleKind.dontImportUser,
        ReplaceInstitute() => _WisaRuleKind.replaceInstitute,
      };
}

/// Editor for the WISA import rules (#273).
///
/// #263 wired a persisted WISA rule through to the very next pull — the syncer
/// unions the settings document's rules with the session's own holder, and
/// `wisaPullFingerprint` covers them so a save arms the drift gate. Nothing in
/// the app could *author* one, though: this list was titled "Importregels
/// (alleen-lezen)" and `_collect` handed `base.wisaRules` straight back, so the
/// only way to add a rule was editing the Cosmos settings document by hand.
class _WisaRulesEditor extends StatelessWidget {
  const _WisaRulesEditor({required this.state});

  final _SettingsScreenState state;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final rules = state._wisaRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Regels snoeien en herschrijven wat er uit WISA wordt ingelezen. Ze '
          'gelden vanaf de volgende synchronisatie.',
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s3),
        if (rules.isEmpty)
          Text(
            'Nog geen WISA-importregels ingesteld.',
            key: const ValueKey('settings-wisa-rules-empty'),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          )
        else ...<Widget>[
          const _WisaRuleColumnHeader(),
          for (var i = 0; i < rules.length; i++)
            _RuleRow(
              keyPrefix: 'settings-wisa-rule',
              index: i,
              description: describeWisaRule(rules[i]),
              // Who decided this, when, and about whom (#285). The document is
              // shared, so without these a colleague's rule reads as a bare
              // WISA code nobody dares remove.
              subject: describeRuleSubject(
                state._wisaRuleProvenance[wisaRuleKey(rules[i])],
              ),
              addedAt: describeRuleAddedAt(
                state._wisaRuleProvenance[wisaRuleKey(rules[i])],
              ),
              addedBy: describeRuleAddedBy(
                state._wisaRuleProvenance[wisaRuleKey(rules[i])],
              ),
              onEdit: () => state._editWisaRule(i),
              onRemove: () => state._removeWisaRule(i),
            ),
        ],
        const SizedBox(height: PlinkSpacing.s4),
        MenuAnchor(
          menuChildren: <Widget>[
            for (final kind in _WisaRuleKind.addable)
              MenuItemButton(
                key: ValueKey('settings-wisa-rule-add-${kind.name}'),
                onPressed: () => state._addWisaRule(kind),
                child: Text(kind.label),
              ),
          ],
          builder: (_, MenuController menu, __) => OutlinedButton.icon(
            key: const ValueKey('settings-wisa-rule-add'),
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            icon: const Icon(Icons.add),
            label: const Text('Toevoegen'),
          ),
        ),
        const SizedBox(height: PlinkSpacing.s3),
        Text(
          'Virtueel en beheerd markeer je per school hierboven bij '
          '"WISA-scholen", niet met een regel.',
          key: const ValueKey('settings-wisa-rules-school-note'),
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Prompts for the one or two values a WISA rule matches on, popping them
/// trimmed and in field order (or nothing when cancelled). A blank value is
/// refused on every field: a rule that matches nothing would silently do no
/// work, exactly as for the Smartschool prompt.
class _WisaRuleDialog extends StatefulWidget {
  const _WisaRuleDialog({required this.kind, required this.initial});

  final _WisaRuleKind kind;
  final List<String> initial;

  @override
  State<_WisaRuleDialog> createState() => _WisaRuleDialogState();
}

class _WisaRuleDialogState extends State<_WisaRuleDialog> {
  late final List<TextEditingController> _values = <TextEditingController>[
    for (var i = 0; i < widget.kind.fields.length; i++)
      TextEditingController(
        text: i < widget.initial.length ? widget.initial[i] : '',
      ),
  ];

  @override
  void dispose() {
    for (final c in _values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete => _values.every((c) => c.text.trim().isNotEmpty);

  void _submit() {
    if (!_complete) return;
    Navigator.of(context).pop(<String>[for (final c in _values) c.text.trim()]);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final fields = widget.kind.fields;
    return AlertDialog(
      key: const ValueKey('settings-wisa-rule-dialog'),
      title: Text(widget.kind.label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.kind.explanation, style: text.bodyMedium),
          for (var i = 0; i < fields.length; i++) ...<Widget>[
            const SizedBox(height: PlinkSpacing.s3),
            TextField(
              key: ValueKey('settings-wisa-rule-value-$i'),
              controller: _values[i],
              autofocus: i == 0,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: fields[i],
                hintText: widget.kind.hints[i],
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('settings-wisa-rule-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        // Every field feeds the enabled state, so the two-field rule cannot be
        // saved half-filled.
        AnimatedBuilder(
          animation: Listenable.merge(_values),
          builder: (_, __) => FilledButton(
            key: const ValueKey('settings-wisa-rule-confirm'),
            onPressed: _complete ? _submit : null,
            child: const Text('Bewaren'),
          ),
        ),
      ],
    );
  }
}

/// How one Smartschool import rule reads in the settings list.
String _describeSmartschoolRule(SmartschoolImportRule rule) => switch (rule) {
      DiscardSmartschoolGroup(:final groupName) =>
        'Smartschool-groep negeren: $groupName',
      NoSmartschoolSubgroups(:final groupName) => 'Geen subgroepen: $groupName',
    };

/// The Smartschool group name a rule applies to. The sealed base type carries
/// no shared field, so a switch over the two cases is where they meet.
String _smartschoolRuleGroupName(SmartschoolImportRule rule) => switch (rule) {
      DiscardSmartschoolGroup(:final groupName) => groupName,
      NoSmartschoolSubgroups(:final groupName) => groupName,
    };

/// The two Smartschool import rules an operator can author (#202), carrying the
/// Dutch labels the legacy `ImportRuleSelectDialog` offered. Calling a kind
/// builds its rule for a group name — which is all that separates them.
enum _SmartschoolRuleKind {
  discardGroup(
    'Negeer groep',
    'De groep en alles eronder wordt niet ingelezen.',
  ),
  noSubgroups(
    'Negeer subgroepen',
    'De groep wordt ingelezen, maar zonder haar subgroepen.',
  );

  const _SmartschoolRuleKind(this.label, this.explanation);

  /// The menu / dialog label, matching legacy.
  final String label;

  /// One line telling the operator what the rule does to the import.
  final String explanation;

  SmartschoolImportRule call(String groupName) => switch (this) {
        _SmartschoolRuleKind.discardGroup => DiscardSmartschoolGroup(groupName),
        _SmartschoolRuleKind.noSubgroups => NoSmartschoolSubgroups(groupName),
      };

  static _SmartschoolRuleKind of(SmartschoolImportRule rule) => switch (rule) {
        DiscardSmartschoolGroup() => _SmartschoolRuleKind.discardGroup,
        NoSmartschoolSubgroups() => _SmartschoolRuleKind.noSubgroups,
      };
}

/// Editor for the Smartschool import rules (#202).
///
/// The app could already *carry* the two rules, but nothing could *create*
/// them — so in practice there were none, and the whole Smartschool group tree
/// (organisational subtrees included) was imported on every pull. This is the
/// authoring surface: the configured rules, each editable and removable inline,
/// plus a **Toevoegen** menu offering the two rule types. Edits live in the
/// screen's working copy and persist with the rest of the document on
/// **Opslaan**, through the existing `encodeSmartschoolRule` codec.
class _SmartschoolRulesEditor extends StatelessWidget {
  const _SmartschoolRulesEditor({required this.state});

  final _SettingsScreenState state;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final rules = state._ssRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Regels snoeien de Smartschool-groepenboom bij het inlezen. Ze '
          'gelden vanaf de volgende synchronisatie.',
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s3),
        if (rules.isEmpty)
          Text(
            'Nog geen importregels ingesteld.',
            key: const ValueKey('settings-ss-rules-empty'),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          )
        else
          for (var i = 0; i < rules.length; i++)
            _RuleRow(
              keyPrefix: 'settings-ss-rule',
              index: i,
              description: _describeSmartschoolRule(rules[i]),
              onEdit: () => state._editSmartschoolRule(i),
              onRemove: () => state._removeSmartschoolRule(i),
            ),
        const SizedBox(height: PlinkSpacing.s4),
        MenuAnchor(
          menuChildren: <Widget>[
            for (final kind in _SmartschoolRuleKind.values)
              MenuItemButton(
                key: ValueKey('settings-ss-rule-add-${kind.name}'),
                onPressed: () => state._addSmartschoolRule(kind),
                child: Text(kind.label),
              ),
          ],
          builder: (_, MenuController menu, __) => OutlinedButton.icon(
            key: const ValueKey('settings-ss-rule-add'),
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            icon: const Icon(Icons.add),
            label: const Text('Toevoegen'),
          ),
        ),
      ],
    );
  }
}

/// One configured import rule — either connector's: its description plus the
/// edit and remove affordances. Keyed `<keyPrefix>-<index>` so a
/// widget/integration test can drive a specific row on a specific tab.
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.keyPrefix,
    required this.index,
    required this.description,
    required this.onEdit,
    required this.onRemove,
    this.subject,
    this.addedAt,
    this.addedBy,
  });

  final String keyPrefix;
  final int index;
  final String description;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  /// The three provenance cells (#285), already resolved to display strings —
  /// `onbekend` where the document records nothing. All three are null for the
  /// Smartschool list, which carries no provenance and renders as it always did.
  final String? subject;
  final String? addedAt;
  final String? addedBy;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle? meta =
        text.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            flex: _RuleColumns.rule,
            child: Text(
              description,
              key: ValueKey('$keyPrefix-$index'),
              style: text.bodyMedium,
            ),
          ),
          if (subject != null) ...<Widget>[
            const SizedBox(width: PlinkSpacing.s2),
            Expanded(
              flex: _RuleColumns.subject,
              child: Text(
                subject!,
                key: ValueKey('$keyPrefix-$index-subject'),
                style: meta,
              ),
            ),
            const SizedBox(width: PlinkSpacing.s2),
            Expanded(
              flex: _RuleColumns.addedAt,
              child: Text(
                addedAt!,
                key: ValueKey('$keyPrefix-$index-added-at'),
                style: meta,
              ),
            ),
            const SizedBox(width: PlinkSpacing.s2),
            Expanded(
              flex: _RuleColumns.addedBy,
              child: Text(
                addedBy!,
                key: ValueKey('$keyPrefix-$index-added-by'),
                style: meta,
              ),
            ),
          ],
          IconButton(
            key: ValueKey('$keyPrefix-$index-edit'),
            tooltip: 'Bewerken',
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
          ),
          IconButton(
            key: ValueKey('$keyPrefix-$index-remove'),
            tooltip: 'Verwijderen',
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// The flexes the WISA rule list and its header share, so the two stay in one
/// grid rather than drifting apart the first time either is edited.
abstract final class _RuleColumns {
  static const int rule = 5;
  static const int subject = 3;
  static const int addedAt = 3;
  static const int addedBy = 3;

  /// The width of the two trailing icon buttons, which the header has to leave
  /// empty to line its labels up with the cells beneath them.
  static const double actions = 96;
}

/// Names the provenance columns of the WISA rule list (#285).
///
/// The timestamp gets a column of its own rather than a tooltip on purpose:
/// with no free-text reason on the record, *when* is what lets someone
/// reconstruct why ("that was the June retirement round"), so it has to be
/// readable at a glance beside the rule instead of hidden behind a hover.
class _WisaRuleColumnHeader extends StatelessWidget {
  const _WisaRuleColumnHeader();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle? style = text.labelSmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Padding(
      key: const ValueKey('settings-wisa-rules-header'),
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        children: <Widget>[
          Expanded(flex: _RuleColumns.rule, child: Text('Regel', style: style)),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            flex: _RuleColumns.subject,
            child: Text('Voor', style: style),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            flex: _RuleColumns.addedAt,
            child: Text('Toegevoegd op', style: style),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            flex: _RuleColumns.addedBy,
            child: Text('Door', style: style),
          ),
          const SizedBox(width: _RuleColumns.actions),
        ],
      ),
    );
  }
}

/// Prompts for the Smartschool group name a rule applies to, popping the
/// trimmed name (or nothing when cancelled). A blank name is refused: a rule
/// without a group matches nothing and would silently do no work.
class _RuleGroupNameDialog extends StatefulWidget {
  const _RuleGroupNameDialog({required this.kind, required this.initial});

  final _SmartschoolRuleKind kind;
  final String initial;

  @override
  State<_RuleGroupNameDialog> createState() => _RuleGroupNameDialogState();
}

class _RuleGroupNameDialogState extends State<_RuleGroupNameDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _name.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      key: const ValueKey('settings-ss-rule-dialog'),
      title: Text(widget.kind.label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.kind.explanation, style: text.bodyMedium),
          const SizedBox(height: PlinkSpacing.s3),
          TextField(
            key: const ValueKey('settings-ss-rule-name'),
            controller: _name,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Groepsnaam',
              hintText: 'Naam zoals ze in Smartschool staat',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('settings-ss-rule-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleren'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _name,
          builder: (_, TextEditingValue value, __) => FilledButton(
            key: const ValueKey('settings-ss-rule-confirm'),
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('Bewaren'),
          ),
        ),
      ],
    );
  }
}

/// Editor for the complete known-WISA-school list (#171): the full set of group
/// schools (id + name), persisted in the settings document, rendered as a
/// 3-column grid where the operator marks inline which ones we manage (`ours`).
/// The shared credentials see every group school; **Scholen ophalen** is a
/// refresh that fills/updates this list (rarely needed once built). Keyed by
/// school id so a widget/integration test can seed a profile and flip it against
/// the in-memory store.
class _WisaSchoolsEditor extends StatelessWidget {
  const _WisaSchoolsEditor({required this.state});

  /// How many schools sit side by side in the grid.
  static const int _columns = 3;

  final _SettingsScreenState state;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final schools = state._wisaSchools;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The known-school list is the primary surface; the fetch is a refresh
        // (#171): mark which schools we manage inline, and only re-fetch when a
        // genuinely new school appears. The virtual mark (#203) rides along in
        // the same cell — it decides which work date the school is pulled with.
        Text(
          'De bekende WISA-scholen. Markeer welke we beheren. Vink '
          '"virtueel" aan voor scholen die met de virtuele werkdatum '
          'opgehaald moeten worden. Gebruik "Scholen ophalen" om de lijst te '
          'vernieuwen als er een nieuwe school bijkomt.',
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s3),
        if (schools.isEmpty)
          Text(
            'Nog geen scholen bekend. Gebruik "Scholen ophalen" om de lijst op '
            'te halen.',
            key: const ValueKey('settings-wisa-schools-empty'),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          )
        else
          ..._schoolRows(schools),
        const SizedBox(height: PlinkSpacing.s4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            OutlinedButton.icon(
              key: const ValueKey('settings-wisa-fetch-schools'),
              onPressed:
                  state._canFetchSchools ? state._fetchWisaSchools : null,
              icon: const Icon(Icons.refresh),
              label: const Text('Scholen ophalen'),
            ),
            if (state._fetchingSchools) ...<Widget>[
              const SizedBox(width: PlinkSpacing.s3),
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
        if (!state._wisaConfigValid)
          Padding(
            padding: const EdgeInsets.only(top: PlinkSpacing.s2),
            child: Text(
              'Bewaar eerst een geldige WISA-configuratie (server en poort) om '
              'scholen te kunnen ophalen.',
              key: const ValueKey('settings-wisa-fetch-hint'),
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  /// Lays the known schools out as rows of [_columns] cells, padding the final
  /// row with empty slots so the grid columns stay aligned. Each cell toggles
  /// its school's managed (`ours`) and virtual flags inline.
  List<Widget> _schoolRows(List<WisaSchoolProfile> schools) {
    final rows = <Widget>[];
    for (var start = 0; start < schools.length; start += _columns) {
      final cells = <Widget>[];
      for (var col = 0; col < _columns; col++) {
        final i = start + col;
        cells.add(Expanded(
          child: i < schools.length
              ? _SchoolCell(state: state, index: i, profile: schools[i])
              : const SizedBox.shrink(),
        ));
      }
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: cells,
      ));
    }
    return rows;
  }
}

/// A single cell in the known-WISA-school grid (#171): the school's long name
/// with its short WISA code (`ISMAA`, `ISMAB`, …) beneath it, plus an inline
/// checkbox marking whether we manage it and a second, quieter one marking it
/// *virtual* (#203). Both are keyed by school id so a test can flip a specific
/// school's flag.
///
/// The two marks are deliberately unequal in weight. `ours` scopes the linker;
/// `virtual` changes **which work date the school is pulled with**, so a school
/// wrongly marked virtual comes back against the wrong date and can read as a
/// mass leave. It therefore sits on its own indented, small-type line rather
/// than as a second equal-looking checkbox.
///
/// Both checkboxes answer for themselves. Until #277 the virtual one could be
/// rendered ticked-and-locked, reading `virtueel (importregel)`, because a
/// `MarkAsVirtual` rule set the same flag by school code and the pull unioned
/// the two — so an unticked box would have been a lie and unticking it would not
/// have stuck. With the rule retired this grid is the only virtual-school
/// surface and the checkbox simply means what it shows.
///
/// The numeric id is strictly a fallback and never appears twice (#194): the
/// title degrades name → code → `School <id>`, and the subtitle shows whichever
/// of code / `id: <id>` the title has not already used — nothing at all when the
/// title is already the id.
class _SchoolCell extends StatelessWidget {
  const _SchoolCell({
    required this.state,
    required this.index,
    required this.profile,
  });

  final _SettingsScreenState state;
  final int index;
  final WisaSchoolProfile profile;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String code = profile.code;
    final String name = profile.name;
    // The lead label comes from the shared school-label helper the Actions
    // drill-down also names schools with, so the two views can never disagree
    // about which half of the pair is the code (#204). The grid leads with the
    // long name and puts the code beneath, which is what it always rendered —
    // before #208 it got there by leading with a `code` field that in fact held
    // the long name.
    final String title = profile.nameLabel;
    final String? subtitle = code.isNotEmpty && name.isNotEmpty
        ? code
        : (code.isEmpty && name.isEmpty ? null : 'id: ${profile.schoolId}');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CheckboxListTile(
          key: ValueKey('settings-wisa-school-${profile.schoolId}-ours'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle == null
              ? null
              : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          value: profile.ours,
          onChanged: (v) => state._toggleSchoolOurs(index, v ?? false),
        ),
        Padding(
          padding: const EdgeInsets.only(left: PlinkSpacing.s3),
          child: CheckboxListTile(
            key: ValueKey('settings-wisa-school-${profile.schoolId}-virtual'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(
              'virtueel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            value: profile.virtual,
            onChanged: (v) => state._toggleSchoolVirtual(index, v ?? false),
          ),
        ),
      ],
    );
  }
}

/// Full-panel message (loading / not-configured / error), mirroring the
/// passwords and reconcile screens so the views read as one app.
class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.eyebrow,
    required this.title,
    required this.message,
    this.action,
    this.progress = false,
  });

  final String eyebrow;
  final String title;
  final String message;
  final Widget? action;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(PlinkSpacing.s6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Eyebrow(eyebrow, onInk: ink),
              const SizedBox(height: PlinkSpacing.s4),
              Text(title, style: text.headlineSmall),
              const SizedBox(height: PlinkSpacing.s4),
              Text(message, style: text.bodyMedium),
              if (progress) ...<Widget>[
                const SizedBox(height: PlinkSpacing.s5),
                const LinearProgressIndicator(),
              ],
              if (action != null) ...<Widget>[
                const SizedBox(height: PlinkSpacing.s5),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
