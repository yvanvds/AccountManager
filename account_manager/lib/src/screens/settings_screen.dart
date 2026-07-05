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
/// Import rules are shown read-only for now (accumulated by `DontImportFromWisa`
/// applies during reconcile); editing them is a later slice.
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

  // Azure profile.
  final _azClientId = TextEditingController();
  final _azTenantId = TextEditingController();
  final _azDomain = TextEditingController();

  // Per-WISA-school ownership (#113). Held as a mutable working copy edited in
  // place; committed to the settings document on save.
  List<WisaSchoolProfile> _wisaSchools = const <WisaSchoolProfile>[];
  final _wisaSchoolToAdd = TextEditingController();

  // The schools last fetched from the WISA API (#142). Null until the operator
  // fetches; then the id+name list the operator ticks to build the selection.
  List<WisaSchool>? _fetchedSchools;
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
      _wisaSchoolToAdd,
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

    _azClientId.text = s.azure.clientId;
    _azTenantId.text = s.azure.tenantId;
    _azDomain.text = s.azure.domain;

    _wisaSchools = List<WisaSchoolProfile>.of(s.wisaSchools);
    _wisaSchoolToAdd.clear();
  }

  /// Flips the `ours` flag on the profile at [index] (the toggle the operator
  /// uses to mark a managed school).
  void _toggleSchoolOurs(int index, bool ours) {
    toggle(
        () => _wisaSchools[index] = _wisaSchools[index].copyWith(ours: ours));
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

  /// Whether the school with [id] is in the current (working) selection.
  bool _isSchoolSelected(int id) => _wisaSchools.any((p) => p.schoolId == id);

  /// Fetches the available WISA schools (id + name) from the API so the operator
  /// can pick which to use instead of typing ids (#142). Prefers a freshly typed
  /// password; otherwise resolves the stored secret. Failures surface as a toast.
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
      setState(() => _fetchedSchools = schools);
      _toast('${schools.length} scholen opgehaald.');
    } on Object catch (e) {
      if (mounted) _toast('Kon scholen niet ophalen: $e');
    } finally {
      if (mounted) setState(() => _fetchingSchools = false);
    }
  }

  /// Ticks or unticks a fetched school in the selection (#142): a tick appends a
  /// managed [WisaSchoolProfile] for its id, an untick drops it. This replaces
  /// the by-hand id entry as the normal way to build the school selection.
  void _toggleFetchedSchool(int schoolId, bool selected) {
    toggle(() {
      if (selected) {
        if (_wisaSchools.any((p) => p.schoolId == schoolId)) return;
        _wisaSchools = <WisaSchoolProfile>[
          ..._wisaSchools,
          WisaSchoolProfile(schoolId: schoolId, ours: true),
        ];
      } else {
        _wisaSchools = <WisaSchoolProfile>[
          for (final p in _wisaSchools)
            if (p.schoolId != schoolId) p,
        ];
      }
    });
  }

  /// Appends a managed-school entry for the id typed in the add field, ignoring
  /// blanks, non-numbers, and ids already present.
  void _addWisaSchool() {
    final id = int.tryParse(_wisaSchoolToAdd.text.trim());
    if (id == null) return;
    if (_wisaSchools.any((p) => p.schoolId == id)) {
      _wisaSchoolToAdd.clear();
      return;
    }
    toggle(() {
      _wisaSchools = <WisaSchoolProfile>[
        ..._wisaSchools,
        WisaSchoolProfile(schoolId: id, ours: true),
      ];
      _wisaSchoolToAdd.clear();
    });
  }

  /// Drops the managed-school entry at [index].
  void _removeWisaSchool(int index) {
    toggle(() {
      _wisaSchools = <WisaSchoolProfile>[..._wisaSchools]..removeAt(index);
    });
  }

  /// Assembles an [AppSettings] from the form, preserving the loaded document's
  /// secret refs and (read-only) import rules.
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
  /// vocabulary, and the Smartschool import rules (read-only).
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
        title: 'Importregels (alleen-lezen)',
        children: <Widget>[
          _RulesList(
            emptyKey: const ValueKey('settings-ss-rules-empty'),
            smartschoolRules: settings.smartschoolRules,
          ),
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
    this.smartschoolRules = const <SmartschoolImportRule>[],
  });

  /// Key stamped on the "no rules yet" placeholder, so each connector tab's
  /// empty state is addressable on its own.
  final Key emptyKey;
  final List<WisaImportRule> wisaRules;
  final List<SmartschoolImportRule> smartschoolRules;

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

  static String _describeSmartschool(SmartschoolImportRule rule) =>
      switch (rule) {
        DiscardSmartschoolGroup(:final groupName) =>
          'Smartschool-groep negeren: $groupName',
        NoSmartschoolSubgroups(:final groupName) =>
          'Geen subgroepen: $groupName',
      };

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (wisaRules.isEmpty && smartschoolRules.isEmpty) {
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
        for (final r in smartschoolRules)
          Padding(
            padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
            child: Text('• ${_describeSmartschool(r)}', style: text.bodyMedium),
          ),
      ],
    );
  }
}

/// Editor for the per-WISA-school ownership list (#113): one switch per known
/// school toggling its `ours`/managed flag, plus an add-by-id affordance. The
/// shared credentials pull every group school; this is where the operator marks
/// which ones we manage. Keyed by school id so a widget/integration test can
/// seed a profile and flip it against the in-memory store.
class _WisaSchoolsEditor extends StatelessWidget {
  const _WisaSchoolsEditor({required this.state});

  final _SettingsScreenState state;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final schools = state._wisaSchools;
    final fetched = state._fetchedSchools;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Fetch-from-WISA affordance (#142): pull the available schools (id +
        // name) and tick which to use, instead of typing ids by hand.
        Text(
          'Haal de beschikbare scholen op uit WISA en kies welke je gebruikt.',
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            FilledButton.icon(
              key: const ValueKey('settings-wisa-fetch-schools'),
              onPressed:
                  state._canFetchSchools ? state._fetchWisaSchools : null,
              icon: const Icon(Icons.cloud_download_outlined),
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
        if (fetched != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          if (fetched.isEmpty)
            Text(
              'Geen scholen gevonden.',
              key: const ValueKey('settings-wisa-fetched-empty'),
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            )
          else
            for (final s in fetched)
              CheckboxListTile(
                key: ValueKey('settings-wisa-fetched-school-${s.id}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(s.name.isEmpty ? 'School ${s.id}' : s.name),
                subtitle: Text('id: ${s.id}'),
                value: state._isSchoolSelected(s.id),
                onChanged: (v) => state._toggleFetchedSchool(s.id, v ?? false),
              ),
        ],
        const Divider(height: PlinkSpacing.s6),
        Text(
          'Geselecteerde scholen — markeer welke we beheren.',
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s2),
        if (schools.isEmpty)
          Text(
            'Nog geen scholen toegevoegd.',
            key: const ValueKey('settings-wisa-schools-empty'),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        for (var i = 0; i < schools.length; i++)
          Row(
            key: ValueKey('settings-wisa-school-${schools[i].schoolId}'),
            children: <Widget>[
              Expanded(
                child: SwitchListTile(
                  key: ValueKey(
                    'settings-wisa-school-${schools[i].schoolId}-ours',
                  ),
                  contentPadding: EdgeInsets.zero,
                  title: Text('School ${schools[i].schoolId}'),
                  subtitle: const Text('Beheerd'),
                  value: schools[i].ours,
                  onChanged: (v) => state._toggleSchoolOurs(i, v),
                ),
              ),
              IconButton(
                key: ValueKey(
                  'settings-wisa-school-${schools[i].schoolId}-remove',
                ),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Verwijderen',
                onPressed: () => state._removeWisaSchool(i),
              ),
            ],
          ),
        const SizedBox(height: PlinkSpacing.s3),
        Text(
          'Optioneel: voeg een school handmatig toe via id.',
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey('settings-wisa-school-add'),
                controller: state._wisaSchoolToAdd,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'School-id toevoegen',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => state._addWisaSchool(),
              ),
            ),
            const SizedBox(width: PlinkSpacing.s3),
            OutlinedButton.icon(
              key: const ValueKey('settings-wisa-school-add-btn'),
              onPressed: state._addWisaSchool,
              icon: const Icon(Icons.add),
              label: const Text('Toevoegen'),
            ),
          ],
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
