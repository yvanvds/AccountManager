import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import '../settings/settings_bootstrap.dart';

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
///   operator's own save) can be pulled back without relaunching.
///
/// The **Smartschool** import rules are authored here (#202): add / edit /
/// remove the two rules the legacy app offers (`DiscardSmartschoolGroup`,
/// `NoSmartschoolSubgroups`), persisted through the existing rule codec and
/// applied by the connector on the next Smartschool pull. The **WISA** rules
/// stay read-only (they are accumulated by `DontImportFromWisa` applies during
/// reconcile); editing those is a later slice.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.bootstrap});

  /// Assembles (or returns the already-assembled) settings seams, or `null` when
  /// Azure AD is not configured for this build (no session to mint the Cosmos /
  /// Key Vault tokens the stores need).
  final Future<SettingsServices> Function()? bootstrap;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsServices? _services;
  AppSettings? _loaded;
  Object? _error;
  bool _busy = false;
  int _attempts = 0;

  // Global.
  final _schoolPrefix = TextEditingController();
  bool _debugMode = false;

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
    _load();
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[
      _schoolPrefix,
      _wisaServer,
      _wisaPort,
      _wisaDatabase,
      _wisaUsername,
      _wisaPassword,
      _ssUri,
      _ssTestUser,
      _ssStudentGroup,
      _ssStaffGroup,
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
      if (!mounted) return;
      setState(() {
        _services = services;
        _loaded = settings;
      });
      _populate(settings);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
  /// otherwise resolves the stored secret. Failures surface as a toast. The
  /// merged list is dirty until saved, so the enriched names persist and no
  /// re-fetch is needed.
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
  /// Both halves come straight across: the connector already untangled WISA's
  /// inverted `NAME`/`DESCRIPTION` columns, so `WisaSchool.name` is the long
  /// name and `WisaSchool.code` the short code (#208).
  List<WisaSchoolProfile> _mergeFetchedSchools(List<WisaSchool> fetched) {
    final byId = <int, WisaSchoolProfile>{
      for (final p in _wisaSchools) p.schoolId: p,
    };
    for (final s in fetched) {
      final existing = byId[s.id];
      byId[s.id] = existing == null
          ? WisaSchoolProfile(schoolId: s.id, code: s.code, name: s.name)
          : existing.copyWith(
              code: s.code.isEmpty ? existing.code : s.code,
              name: s.name.isEmpty ? existing.name : s.name,
            );
    }
    final merged = byId.values.toList()
      ..sort((a, b) => a.schoolId.compareTo(b.schoolId));
    return merged;
  }

  /// Assembles an [AppSettings] from the form, preserving the loaded document's
  /// secret refs and its (read-only) WISA import rules.
  AppSettings _collect(AppSettings base) {
    return base.copyWith(
      schoolPrefix: _schoolPrefix.text.trim(),
      debugMode: _debugMode,
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

  @override
  Widget build(BuildContext context) {
    if (widget.bootstrap == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · instellingen',
        title: 'Not configured',
        message: 'Azure AD is not configured for this build, so the settings '
            'store cannot be reached. Provide the AAD --dart-define values and '
            'restart.',
      );
    }
    final error = _error;
    if (error != null && _loaded == null) {
      final retryNote = _attempts > 1 ? '\n\n(Attempt $_attempts failed.)' : '';
      return _MessagePanel(
        eyebrow: 'Arcadia · instellingen',
        title: 'Kon de instellingen niet laden',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('settings-retry'),
          onPressed: _load,
          child: const Text('Opnieuw proberen'),
        ),
      );
    }
    final loaded = _loaded;
    if (loaded == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · instellingen',
        title: 'Laden…',
        message: 'De instellingen worden opgehaald.',
        progress: true,
      );
    }
    return _SettingsForm(
      state: this,
      settings: loaded,
    );
  }
}

/// The scrolling settings form. A thin view over [_SettingsScreenState]'s
/// controllers so all mutation stays in one place.
class _SettingsForm extends StatelessWidget {
  const _SettingsForm({required this.state, required this.settings});

  final _SettingsScreenState state;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: DefaultTabController(
          length: 4,
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
                          onPressed: state._busy ? null : state._save,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Opslaan'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('settings-reload'),
                          onPressed: state._busy ? null : state._reload,
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
              const TabBar(
                key: ValueKey('settings-tabs'),
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: <Widget>[
                  Tab(key: ValueKey('settings-tab-algemeen'), text: 'Algemeen'),
                  Tab(key: ValueKey('settings-tab-wisa'), text: 'Wisa'),
                  Tab(
                    key: ValueKey('settings-tab-smartschool'),
                    text: 'Smartschool',
                  ),
                  Tab(key: ValueKey('settings-tab-azure'), text: 'Azure'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    _algemeenTab(),
                    _wisaTab(),
                    _smartschoolTab(),
                    _azureTab(),
                  ],
                ),
              ),
            ],
          ),
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
    ]);
  }

  /// WISA connector config: connection, credentials, managed-school list, and
  /// the WISA import rules (read-only).
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
        title: 'Importregels (alleen-lezen)',
        children: <Widget>[
          _RulesList(
            emptyKey: const ValueKey('settings-wisa-rules-empty'),
            wisaRules: settings.wisaRules,
          ),
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

class _RulesList extends StatelessWidget {
  const _RulesList({
    required this.emptyKey,
    this.wisaRules = const <WisaImportRule>[],
  });

  /// Key stamped on the "no rules yet" placeholder, so each connector tab's
  /// empty state is addressable on its own.
  final Key emptyKey;
  final List<WisaImportRule> wisaRules;

  static String _describeWisa(WisaImportRule rule) => switch (rule) {
        DontImportClass(:final className) =>
          'Klas niet importeren uit WISA: $className',
        DontImportUserFromWisa(:final userCode) =>
          'Gebruiker niet importeren uit WISA: $userCode',
        ReplaceInstitute(:final original, :final replacement) =>
          'Vervang instituut: $original → $replacement',
        MarkAsVirtual(:final schoolCode) => 'Markeer als virtueel: $schoolCode',
        MarkAsOurs(:final schoolCode) => 'Markeer als beheerd: $schoolCode',
      };

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (wisaRules.isEmpty) {
      return Text(
        'Nog geen importregels verzameld.',
        key: emptyKey,
        style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final r in wisaRules)
          Padding(
            padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
            child: Text('• ${_describeWisa(r)}', style: text.bodyMedium),
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
            _RuleRow(state: state, index: i, rule: rules[i]),
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

/// One configured Smartschool rule: its description plus the edit and remove
/// affordances. Keyed by position so a widget/integration test can drive a
/// specific row.
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.state,
    required this.index,
    required this.rule,
  });

  final _SettingsScreenState state;
  final int index;
  final SmartschoolImportRule rule;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _describeSmartschoolRule(rule),
              key: ValueKey('settings-ss-rule-$index'),
              style: text.bodyMedium,
            ),
          ),
          IconButton(
            key: ValueKey('settings-ss-rule-$index-edit'),
            tooltip: 'Bewerken',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => state._editSmartschoolRule(index),
          ),
          IconButton(
            key: ValueKey('settings-ss-rule-$index-remove'),
            tooltip: 'Verwijderen',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => state._removeSmartschoolRule(index),
          ),
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
