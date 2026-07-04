import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';

/// The Passwords view (#105): the shared distribution queue of passwords minted
/// when an apply creates an account.
///
/// The whole point of the shared queue is the one-generates/one-prints flow —
/// one operator runs the reconcile applies that fill the queue, another opens
/// this view to read the sheets and mark them distributed. So this screen reads
/// and drains the **same** [PasswordQueueStore] the [StateApplier] appends to
/// (both come from the one memoized [ReconcileServices]).
///
/// Deliberately minimal per the Phase C rethink (#75): list pending entries,
/// copy a password, and mark an entry distributed (which drains it by saving the
/// remainder). Ticket-printer output is a later slice.
class PasswordsScreen extends StatefulWidget {
  const PasswordsScreen({super.key, required this.bootstrap});

  /// Assembles (or returns the already-assembled) reconcile stack, or `null`
  /// when Azure AD is not configured for this build. The same memoized closure
  /// the reconcile screen uses, so both share one queue instance.
  final Future<ReconcileServices> Function()? bootstrap;

  @override
  State<PasswordsScreen> createState() => _PasswordsScreenState();
}

class _PasswordsScreenState extends State<PasswordsScreen> {
  ReconcileServices? _services;
  List<PasswordEntry>? _entries;
  Object? _error;
  bool _busy = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Bootstraps the stack (once, memoized) if needed, then (re)reads the queue.
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
      final entries = await services.passwordQueue.load();
      if (!mounted) return;
      setState(() {
        _services = services;
        _entries = entries;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Marks [entry] distributed: drops it from the queue and persists the
  /// remainder (the queue store replaces the whole list on save). Optimistic —
  /// the row disappears immediately; a failed save restores it and surfaces the
  /// error.
  Future<void> _distribute(PasswordEntry entry) async {
    final services = _services;
    final current = _entries;
    if (services == null || current == null) return;

    final remainder = <PasswordEntry>[
      for (final e in current)
        if (e.personId.value != entry.personId.value) e,
    ];
    setState(() => _entries = remainder);
    try {
      await services.passwordQueue.save(remainder);
      if (mounted) _toast('Gemarkeerd als verdeeld — ${entry.displayName}.');
    } on Object catch (e) {
      if (!mounted) return;
      // Restore the row so the operator can retry; the store rejected the drain.
      setState(() => _entries = current);
      _toast('Kon niet opslaan: $e');
    }
  }

  Future<void> _copy(String label, String password) async {
    await Clipboard.setData(ClipboardData(text: password));
    if (mounted) _toast('$label gekopieerd.');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bootstrap == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · wachtwoorden',
        title: 'Not configured',
        message: 'Azure AD is not configured for this build, so the shared '
            'password queue cannot be reached. Provide the AAD --dart-define '
            'values and restart.',
      );
    }
    final error = _error;
    if (error != null && _entries == null) {
      final retryNote = _attempts > 1 ? '\n\n(Attempt $_attempts failed.)' : '';
      return _MessagePanel(
        eyebrow: 'Arcadia · wachtwoorden',
        title: 'Kon de wachtwoordenlijst niet laden',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('passwords-retry'),
          onPressed: _load,
          child: const Text('Opnieuw proberen'),
        ),
      );
    }
    final entries = _entries;
    if (entries == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · wachtwoorden',
        title: 'Laden…',
        message: 'De gedeelde wachtwoordenlijst wordt opgehaald.',
        progress: true,
      );
    }
    return _PasswordsBody(
      entries: entries,
      busy: _busy,
      onRefresh: _load,
      onCopy: _copy,
      onDistribute: _distribute,
    );
  }
}

class _PasswordsBody extends StatelessWidget {
  const _PasswordsBody({
    required this.entries,
    required this.busy,
    required this.onRefresh,
    required this.onCopy,
    required this.onDistribute,
  });

  final List<PasswordEntry> entries;
  final bool busy;
  final VoidCallback onRefresh;
  final Future<void> Function(String label, String password) onCopy;
  final Future<void> Function(PasswordEntry entry) onDistribute;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: CustomScrollView(
          slivers: <Widget>[
            const SliverToBoxAdapter(child: SizedBox(height: PlinkSpacing.s6)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: PlinkSpacing.s6),
              sliver: SliverToBoxAdapter(
                child: _Header(
                    count: entries.length, busy: busy, onRefresh: onRefresh),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: PlinkSpacing.s5)),
            if (entries.isEmpty)
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: PlinkSpacing.s6),
                sliver: const SliverToBoxAdapter(child: _EmptyState()),
              )
            else
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: PlinkSpacing.s6),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _PasswordCard(
                    entry: entries[index],
                    onCopy: onCopy,
                    onDistribute: onDistribute,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: PlinkSpacing.s6)),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.count,
    required this.busy,
    required this.onRefresh,
  });

  final int count;
  final bool busy;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final String subtitle = count == 0
        ? 'Geen wachtwoorden in de wachtrij.'
        : count == 1
            ? '1 wachtwoord wacht op verdeling.'
            : '$count wachtwoorden wachten op verdeling.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · wachtwoorden', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        Text('Wachtwoorden', style: text.headlineMedium),
        const SizedBox(height: PlinkSpacing.s4),
        Wrap(
          spacing: PlinkSpacing.s3,
          runSpacing: PlinkSpacing.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            OutlinedButton.icon(
              key: const ValueKey('passwords-refresh'),
              onPressed: busy ? null : onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Vernieuwen'),
            ),
            Text(subtitle, style: text.bodySmall),
          ],
        ),
        if (busy) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s4),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('passwords-empty'),
      padding: const EdgeInsets.all(PlinkSpacing.s5),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline, color: colors.primary),
          const SizedBox(width: PlinkSpacing.s3),
          Flexible(
            child: Text(
              'Alle wachtwoorden zijn verdeeld. Nieuwe accounts die je aanmaakt '
              'bij het reconcilen verschijnen hier.',
              style: text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _PasswordCard extends StatelessWidget {
  const _PasswordCard({
    required this.entry,
    required this.onCopy,
    required this.onDistribute,
  });

  final PasswordEntry entry;
  final Future<void> Function(String label, String password) onCopy;
  final Future<void> Function(PasswordEntry entry) onDistribute;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final subtitleParts = <String>[
      entry.accountName,
      if (entry.classGroup != null && entry.classGroup!.isNotEmpty)
        entry.classGroup!,
      if (entry.mail != null && entry.mail!.isNotEmpty) entry.mail!,
    ];

    return Container(
      key: ValueKey('password-entry-${entry.personId.value}'),
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s3),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.displayName.isEmpty
                          ? entry.accountName
                          : entry.displayName,
                      style: text.titleMedium,
                    ),
                    if (subtitleParts.isNotEmpty) ...<Widget>[
                      const SizedBox(height: PlinkSpacing.s1),
                      Text(
                        subtitleParts.join(' · '),
                        style: text.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              TextButton.icon(
                key: ValueKey('password-distribute-${entry.personId.value}'),
                onPressed: () => onDistribute(entry),
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Verdeeld'),
              ),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s3),
          Wrap(
            spacing: PlinkSpacing.s3,
            runSpacing: PlinkSpacing.s2,
            children: <Widget>[
              if (entry.smartschoolPassword != null &&
                  entry.smartschoolPassword!.isNotEmpty)
                _PasswordChip(
                  keyValue: 'password-copy-ss-${entry.personId.value}',
                  label: 'Smartschool',
                  password: entry.smartschoolPassword!,
                  onCopy: () => onCopy(
                    'Smartschool-wachtwoord',
                    entry.smartschoolPassword!,
                  ),
                ),
              if (entry.azurePassword != null &&
                  entry.azurePassword!.isNotEmpty)
                _PasswordChip(
                  keyValue: 'password-copy-azure-${entry.personId.value}',
                  label: 'Office 365',
                  password: entry.azurePassword!,
                  onCopy: () => onCopy(
                    'Office 365-wachtwoord',
                    entry.azurePassword!,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PasswordChip extends StatelessWidget {
  const _PasswordChip({
    required this.keyValue,
    required this.label,
    required this.password,
    required this.onCopy,
  });

  final String keyValue;
  final String label;
  final String password;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        PlinkSpacing.s3,
        PlinkSpacing.s2,
        PlinkSpacing.s2,
        PlinkSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$label:', style: text.labelMedium),
          const SizedBox(width: PlinkSpacing.s2),
          SelectableText(
            password,
            style: text.bodyMedium?.copyWith(fontFeatures: const <FontFeature>[
              FontFeature.tabularFigures(),
            ]),
          ),
          const SizedBox(width: PlinkSpacing.s1),
          IconButton(
            key: ValueKey(keyValue),
            visualDensity: VisualDensity.compact,
            tooltip: 'Kopieer $label-wachtwoord',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

/// Full-panel message (loading / not-configured / error), mirroring the
/// reconcile screen's panel so the two views read as one app.
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
