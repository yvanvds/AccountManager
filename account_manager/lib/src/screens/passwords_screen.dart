import 'dart:async';

import 'package:account_core/account_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../passwords/password_controller.dart';
import '../reconcile/reconcile_bootstrap.dart';

/// The reworked Passwords view (#180): on-demand password generation, split
/// into a **Leerlingen** and a **Personeel** tab, matching the legacy WPF app.
///
/// The old screen was a distribution-only queue built on the wrong assumption
/// that a password exists the moment an account is created. Accounts are
/// prepared months in advance with no remembered password; a password only
/// becomes real here, when the operator explicitly generates or resets one.
///
/// - **Leerlingen**: a tree of the Smartschool "Leerlingen" group; selecting a
///   class loads its accounts into a grid of per-target checkboxes (Smartschool,
///   Office 365, CoAccount 1–6). A guarded "Genereer wachtwoorden" pushes a
///   fresh password live for each checked target and queues the result for the
///   printable student sheet (a real PDF, #195) and the co-account CSV.
/// - **Personeel**: the staff the *linker* holds (#372), searchable by any part
///   of the full name (#215 — one box, no field picker); a per-member reset
///   mints a fresh Smartschool and/or Office 365 password, pushes it live, and
///   exports a per-staff PDF sheet.
///
/// Both tabs resolve the Office 365 account through the linked snapshot rather
/// than by handing Graph the Smartschool mail as a UPN (#372), so a student
/// whose two addresses have drifted apart still gets their password — and where
/// the linker holds no Azure account at all, the row says so instead of quietly
/// producing nothing.
///
/// Shares the one memoized [ReconcileServices] with the Reconcile and Actions
/// screens, so the class/staff tree comes from the same synced Smartschool
/// snapshot and the generated sheets land in the same shared password queue.
class PasswordsScreen extends StatefulWidget {
  const PasswordsScreen({super.key, required this.bootstrap});

  /// Assembles (or returns the already-assembled) reconcile stack, or `null`
  /// when Azure AD is not configured for this build.
  final Future<ReconcileServices> Function()? bootstrap;

  @override
  State<PasswordsScreen> createState() => _PasswordsScreenState();
}

class _PasswordsScreenState extends State<PasswordsScreen> {
  PasswordController? _controller;

  /// The reconcile stack this screen bootstrapped, kept so the listener below
  /// can be detached again.
  ReconcileServices? _services;
  Object? _error;
  bool _busy = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _services?.controller.removeListener(_adoptSnapshot);
    _controller?.dispose();
    super.dispose();
  }

  /// Re-reads the live Smartschool and linked snapshots after a pass on another
  /// tab (#287, #372).
  ///
  /// The tree and the roster this screen draws are the ones the *session* holds,
  /// and the session can acquire newer ones at any time — a sync, a drift check,
  /// an apply that patched an account, or the opening adoption of the shared
  /// state. The reconcile controller notifies on all of them;
  /// [PasswordController.refresh] is identity-guarded on both snapshots, so a
  /// notification that changed nothing here costs nothing.
  void _adoptSnapshot() => _controller?.refresh();

  /// Bootstraps the shared stack (once), then builds the [PasswordController]
  /// over the current Smartschool snapshot, the shared password queue, and the
  /// live write seam. Reads the queue so the export buttons reflect any pending
  /// sheets straight away.
  Future<void> _bootstrap() async {
    final make = widget.bootstrap;
    if (make == null) return;
    setState(() {
      _attempts++;
      _busy = true;
      _error = null;
    });
    try {
      final services = await make();
      if (!mounted) return;
      final controller = PasswordController(
        // Read live rather than captured (#287): a session that opened this tab
        // before its first sync — or before adopting the shared state — used to
        // stay on whatever tree it held at that instant, for the rest of its
        // life.
        snapshot: () => services.app.smartschool.snapshot,
        // The linker's view of the same people (#372): where the Office 365
        // account comes from, and — for Personeel — where the roster comes from,
        // so an account that sits in no Smartschool group is still reachable.
        linked: () => services.controller.linked?.snapshot,
        queue: services.passwordQueue,
        backends: services.passwordBackends,
        writer: services.passwordFileWriter,
        opener: services.passwordFileOpener,
        log: services.log,
      );
      await controller.loadQueue();
      if (!mounted) {
        controller.dispose();
        return;
      }
      _services?.controller.removeListener(_adoptSnapshot);
      _services = services;
      services.controller.addListener(_adoptSnapshot);
      setState(() => _controller = controller);
      // The session's opening read, exactly as the other three screens do it
      // (#287): the shared overview, then the linked view built from the same
      // shared state when the cold seed allows it. Without it this screen was
      // the one view that never asked for a linked snapshot, so an operator who
      // opened Wachtwoorden first had no roster but the group tree (#372).
      // Fire-and-forget; the controller notifies, and [_adoptSnapshot] adopts.
      unawaited(services.controller.openSession());
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bootstrap == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · wachtwoorden',
        title: 'Niet geconfigureerd',
        message: 'Azure AD is niet geconfigureerd voor deze build, dus de '
            'connectoren en de gedeelde wachtwoordwachtrij zijn onbereikbaar. '
            'Geef de AAD --dart-define-waarden mee en start opnieuw op.',
      );
    }
    final error = _error;
    if (error != null && _controller == null) {
      final retryNote = _attempts > 1 ? '\n\n(Poging $_attempts mislukt.)' : '';
      return _MessagePanel(
        eyebrow: 'Arcadia · wachtwoorden',
        title: 'Kon het wachtwoordscherm niet laden',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('passwords-retry'),
          onPressed: _bootstrap,
          child: const Text('Opnieuw proberen'),
        ),
      );
    }
    final controller = _controller;
    if (_busy || controller == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · wachtwoorden',
        title: 'Laden…',
        message: 'De klassen en het personeel worden voorbereid.',
        progress: true,
      );
    }
    return _PasswordsBody(controller: controller);
  }
}

class _PasswordsBody extends StatefulWidget {
  const _PasswordsBody({required this.controller});

  final PasswordController controller;

  @override
  State<_PasswordsBody> createState() => _PasswordsBodyState();
}

class _PasswordsBodyState extends State<_PasswordsBody>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  PasswordController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final TextTheme text = Theme.of(context).textTheme;
        final bool ink = Theme.of(context).brightness == Brightness.dark;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PlinkSpacing.s6,
                PlinkSpacing.s6,
                PlinkSpacing.s6,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Eyebrow('Arcadia · wachtwoorden', onInk: ink),
                  const SizedBox(height: PlinkSpacing.s4),
                  Text('Wachtwoorden', style: text.headlineMedium),
                  const SizedBox(height: PlinkSpacing.s2),
                  Text(
                    'Genereer wachtwoorden op aanvraag — voor klassen '
                    '(Leerlingen) of per personeelslid (Personeel).',
                    style: text.bodyMedium,
                  ),
                  if (controller.message != null) ...<Widget>[
                    const SizedBox(height: PlinkSpacing.s2),
                    Text(
                      controller.message!,
                      key: const ValueKey('passwords-message'),
                      style: text.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                  if (controller.busy) ...<Widget>[
                    const SizedBox(height: PlinkSpacing.s3),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: PlinkSpacing.s3),
                  TabBar(
                    controller: _tabs,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: const <Widget>[
                      Tab(
                        key: ValueKey('passwords-tab-leerlingen'),
                        text: 'Leerlingen',
                      ),
                      Tab(
                        key: ValueKey('passwords-tab-personeel'),
                        text: 'Personeel',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: <Widget>[
                  _LeerlingenTab(controller: controller),
                  _PersoneelTab(controller: controller),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Leerlingen tab
// ---------------------------------------------------------------------------

class _LeerlingenTab extends StatelessWidget {
  const _LeerlingenTab({required this.controller});

  final PasswordController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final root = controller.studentRoot;
    final Color hairline = Theme.of(context).dividerColor;
    return Column(
      children: <Widget>[
        Expanded(
          child: root == null
              ? Padding(
                  padding: const EdgeInsets.all(PlinkSpacing.s6),
                  child: Text(
                    'Geen "Leerlingen"-groep gevonden. Synchroniseer eerst op '
                    'het tabblad Synchronisatie zodat de klasboom geladen is.',
                    key: const ValueKey('passwords-no-leerlingen'),
                    style: text.bodyMedium,
                  ),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      width: 280,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                            vertical: PlinkSpacing.s3),
                        children: <Widget>[
                          for (final child in controller.childrenOf(root))
                            _ClassTreeNode(
                                controller: controller, group: child),
                        ],
                      ),
                    ),
                    VerticalDivider(width: 1, thickness: 1, color: hairline),
                    Expanded(child: _StudentGrid(controller: controller)),
                  ],
                ),
        ),
        const Divider(height: 1),
        // The generate + export actions act on the selected class and the
        // accumulated queue respectively, so they stay visible below both
        // panels rather than being gated behind a class selection (the queue
        // can hold sheets even when no "Leerlingen" tree is present).
        _LeerlingenActionBar(controller: controller),
      ],
    );
  }
}

/// One node of the class tree: a leaf class is a selectable tile; a group with
/// children is an [ExpansionTile] holding its subtree.
class _ClassTreeNode extends StatelessWidget {
  const _ClassTreeNode({required this.controller, required this.group});

  final PasswordController controller;
  final core.Group group;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final children = controller.childrenOf(group);
    if (children.isNotEmpty) {
      return ExpansionTile(
        key: ValueKey('password-branch-${group.id.value}'),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(group.name, style: text.bodyMedium),
        childrenPadding: const EdgeInsets.only(left: PlinkSpacing.s4),
        children: <Widget>[
          for (final child in children)
            _ClassTreeNode(controller: controller, group: child),
        ],
      );
    }
    final selected = controller.selectedClass?.id.value == group.id.value;
    return ListTile(
      key: ValueKey('password-class-${group.id.value}'),
      dense: true,
      selected: selected,
      title: Text(group.name, style: text.bodyMedium),
      onTap: () => controller.selectClass(group),
    );
  }
}

/// The per-target selection grid for the selected class, plus the guarded
/// generate action and the two export outputs.
class _StudentGrid extends StatelessWidget {
  const _StudentGrid({required this.controller});

  final PasswordController controller;

  static const double _cellWidth = 46;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final selectedClass = controller.selectedClass;
    if (selectedClass == null) {
      return Padding(
        padding: const EdgeInsets.all(PlinkSpacing.s6),
        child: Text(
          'Kies een klas links om de leerlingen te tonen.',
          key: const ValueKey('passwords-no-class'),
          style: text.bodyMedium,
        ),
      );
    }
    final rows = controller.rows;
    return ListView(
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      children: <Widget>[
        Text(selectedClass.name, style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s3),
        if (rows.isEmpty)
          Text(
            'Geen leerlingen in deze klas.',
            key: const ValueKey('passwords-empty-class'),
            style: text.bodyMedium,
          )
        else ...<Widget>[
          _headerRow(context),
          const Divider(),
          for (final row in rows) _studentRow(context, row),
        ],
      ],
    );
  }

  Widget _headerRow(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Expanded(child: Text('Leerling', style: text.labelLarge)),
        for (final target in PasswordTarget.values)
          SizedBox(
            width: _cellWidth,
            child: Column(
              children: <Widget>[
                Text(target.label, style: text.labelSmall),
                Checkbox(
                  key: ValueKey('passwords-bulk-${target.name}'),
                  value: controller.bulkSelected(target),
                  onChanged: controller.busy
                      ? null
                      : (v) => controller.toggleBulk(target, v ?? false),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _studentRow(BuildContext context, StudentRow row) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    // What this row could not do, on the row (#372). A generate that skipped
    // Office 365 for a handful of an intake used to leave nothing on screen at
    // all — only a line in the Log panel — so it read exactly like a run that
    // succeeded for everyone.
    final String? note = row.problem ??
        (row.hasNoAzureAccount ? PasswordController.noAzureAccountNote : null);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(row.name, style: text.bodyMedium),
                Text(row.username,
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    )),
                if (note != null)
                  Text(
                    note,
                    key: ValueKey('passwords-note-${row.username}'),
                    style: text.bodySmall?.copyWith(color: colors.error),
                  ),
              ],
            ),
          ),
          for (final target in PasswordTarget.values)
            SizedBox(
              width: _cellWidth,
              child: Checkbox(
                key: ValueKey('passwords-cell-${row.username}-${target.name}'),
                value: row.selected.contains(target),
                onChanged: controller.busy
                    ? null
                    : (v) => controller.toggleRow(row, target, v ?? false),
              ),
            ),
        ],
      ),
    );
  }
}

/// The persistent Leerlingen action bar: generate for the selected class plus
/// the two queue-wide export outputs. Always visible below the tree/grid so the
/// print/CSV exports are reachable regardless of which class (if any) is open.
class _LeerlingenActionBar extends StatelessWidget {
  const _LeerlingenActionBar({required this.controller});

  final PasswordController controller;

  @override
  Widget build(BuildContext context) {
    final count = controller.selectedCount;
    return Padding(
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      child: Wrap(
        spacing: PlinkSpacing.s3,
        runSpacing: PlinkSpacing.s2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          FilledButton.icon(
            key: const ValueKey('passwords-generate'),
            onPressed: controller.busy || count == 0
                ? null
                : () => _confirmAndGenerate(context, count),
            icon: const Icon(Icons.password, size: 18),
            label: Text(count == 0
                ? 'Genereer wachtwoorden'
                : 'Genereer wachtwoorden ($count)'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('passwords-export-students'),
            onPressed: controller.busy || controller.studentSheets.isEmpty
                ? null
                : () => controller.exportStudentSheets(),
            icon: const Icon(Icons.print_outlined, size: 18),
            label: Text(
                'Print leerling-wachtwoorden (${controller.studentSheets.length})'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('passwords-export-coaccounts'),
            onPressed: controller.busy || controller.coAccountSheets.isEmpty
                ? null
                : () => controller.exportCoAccounts(),
            icon: const Icon(Icons.table_view_outlined, size: 18),
            label: Text(
                'Bewaar co-accounts (CSV) (${controller.coAccountSheets.length})'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndGenerate(BuildContext context, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wachtwoorden genereren?'),
        content: Text(
          'Dit genereert en verstuurt $count nieuw(e) wachtwoord(en) live naar '
          'Smartschool en Office 365. Bestaande wachtwoorden worden overschreven.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuleren'),
          ),
          FilledButton(
            key: const ValueKey('passwords-generate-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Genereren'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await controller.generate();
  }
}

// ---------------------------------------------------------------------------
// Personeel tab
// ---------------------------------------------------------------------------

class _PersoneelTab extends StatelessWidget {
  const _PersoneelTab({required this.controller});

  final PasswordController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
    if (controller.staff.isEmpty && controller.filterText.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(PlinkSpacing.s6),
        child: Text(
          'Geen personeel gevonden. Synchroniseer eerst op het tabblad '
          'Synchronisatie zodat het personeel geladen is.',
          key: const ValueKey('passwords-no-personeel'),
          style: text.bodyMedium,
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 320,
          child: Column(
            children: <Widget>[
              // One search box over the whole name (#215): the operator types a
              // fragment and gets the person, rather than first picking which
              // field to match on and getting an unexplained empty list when
              // they pick the wrong one.
              Padding(
                padding: const EdgeInsets.all(PlinkSpacing.s3),
                child: TextField(
                  key: const ValueKey('passwords-staff-filter'),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Zoek op naam…',
                  ),
                  onChanged: controller.setStaffFilterText,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    for (final row in controller.staff)
                      _StaffTile(controller: controller, row: row),
                  ],
                ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: hairline),
        Expanded(child: _StaffDetail(controller: controller)),
      ],
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({required this.controller, required this.row});

  final PasswordController controller;
  final StaffRow row;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final selected = controller.selectedStaff?.key == row.key;
    return ListTile(
      key: ValueKey('passwords-staff-${row.key}'),
      dense: true,
      selected: selected,
      title: Text(row.name, style: text.bodyMedium),
      // A row off the linked roster need not hold a Smartschool account at all
      // (#372); say which one it is rather than showing a blank line.
      subtitle: Text(
        row.hasSmartschoolAccount
            ? row.uid
            : (row.mail.isNotEmpty
                ? row.mail
                : PasswordController.noSmartschoolAccountNote),
        style: text.bodySmall,
      ),
      onTap: () => controller.selectStaff(row),
    );
  }
}

class _StaffDetail extends StatelessWidget {
  const _StaffDetail({required this.controller});

  final PasswordController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final row = controller.selectedStaff;
    if (row == null) {
      return Padding(
        padding: const EdgeInsets.all(PlinkSpacing.s6),
        child: Text(
          'Kies een personeelslid links om een wachtwoord te resetten.',
          key: const ValueKey('passwords-no-staff'),
          style: text.bodyMedium,
        ),
      );
    }
    // What cannot be reset for this person, stated before the operator presses
    // anything (#372) — and which of the two buttons that disables.
    final bool noSmartschool = !row.hasSmartschoolAccount;
    final bool noAzure = row.hasNoAzureAccount;
    final String? note = row.problem ??
        (noSmartschool
            ? PasswordController.noSmartschoolAccountNote
            : noAzure
                ? PasswordController.noAzureAccountNote
                : null);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(PlinkSpacing.s6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(row.name, style: text.titleMedium),
          const SizedBox(height: PlinkSpacing.s1),
          if (row.hasSmartschoolAccount) Text(row.uid, style: text.bodySmall),
          if (row.mail.isNotEmpty) Text(row.mail, style: text.bodySmall),
          if (note != null) ...<Widget>[
            const SizedBox(height: PlinkSpacing.s2),
            Text(
              note,
              key: const ValueKey('passwords-staff-note'),
              style: text.bodySmall?.copyWith(color: colors.error),
            ),
          ],
          const SizedBox(height: PlinkSpacing.s4),
          Text(
              'Reset een wachtwoord — het nieuwe wordt live verstuurd en in '
              'een afdrukbaar blad bewaard.',
              style: text.bodyMedium),
          const SizedBox(height: PlinkSpacing.s3),
          Wrap(
            spacing: PlinkSpacing.s3,
            runSpacing: PlinkSpacing.s2,
            children: <Widget>[
              OutlinedButton(
                key: const ValueKey('passwords-staff-reset-ss'),
                onPressed: controller.busy || noSmartschool
                    ? null
                    : () => _confirmAndReset(
                          context,
                          label: 'Smartschool',
                          smartschool: true,
                          office365: false,
                        ),
                child: const Text('Nieuw Smartschool-wachtwoord'),
              ),
              OutlinedButton(
                key: const ValueKey('passwords-staff-reset-o365'),
                onPressed: controller.busy || noAzure
                    ? null
                    : () => _confirmAndReset(
                          context,
                          label: 'Office 365',
                          smartschool: false,
                          office365: true,
                        ),
                child: const Text('Nieuw Office 365-wachtwoord'),
              ),
              FilledButton(
                key: const ValueKey('passwords-staff-reset-both'),
                onPressed: controller.busy || noSmartschool || noAzure
                    ? null
                    : () => _confirmAndReset(
                          context,
                          label: 'beide',
                          smartschool: true,
                          office365: true,
                        ),
                child: const Text('Beide'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndReset(
    BuildContext context, {
    required String label,
    required bool smartschool,
    required bool office365,
  }) async {
    final row = controller.selectedStaff;
    if (row == null) return;
    final who = row.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wachtwoord resetten?'),
        content: Text(
          'Dit genereert een nieuw $label-wachtwoord voor $who en verstuurt '
          'het live.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuleren'),
          ),
          FilledButton(
            key: const ValueKey('passwords-staff-reset-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Resetten'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await controller.resetStaff(
        smartschool: smartschool,
        office365: office365,
      );
    }
  }
}

/// Full-panel message (loading / not-configured / error), mirroring the other
/// screens' panels so the views read as one app.
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
