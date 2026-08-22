/// The tile vocabulary the action-bearing screens share — Acties (#154) and,
/// since #227, Klasgroepen.
///
/// Everything here was born inside `actions_screen.dart` and stayed private to
/// it while there was one such screen. The class inventory is the second: it
/// lists every class, and a class that needs work has to be inspected,
/// dry-run and applied *there* rather than sending the operator back to a
/// second list of the same classes. So the pieces both screens render — the
/// pending badge, the read-only announcement and lock, the interactive entry
/// tile with its radios and per-entry apply, the same-situation bulk header,
/// and the confirm/progress machinery every write goes through — live here,
/// public, instead of being duplicated or reached for across a private boundary.
///
/// The screens keep what is theirs: the drill-down tree and account cards stay
/// in Acties, the inventory rows in Klasgroepen.
library;

import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart' show CandidateAction;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';
// The `Werkdatum` SOAP parameter's own formatter, so the freshness line names
// the date exactly as it went on the wire and as the Log panel reports it
// (#247).
import 'package:wisa_api/wisa_api.dart' as wapi show formatWerkdatum;

import '../format/timestamps.dart';
import '../reconcile/reconcile_controller.dart';

// ---------------------------------------------------------------------------
// Rows.
// ---------------------------------------------------------------------------

/// One row of a per-classroom (or per-group) pending list: a same-situation
/// bulk header or a single account entry. Flattening the situation → entries
/// tree into a linear list lets a lazy [SliverList] build only the on-screen
/// rows (#111/#154).
sealed class PendingRow {
  const PendingRow();
}

class SituationHeaderRow extends PendingRow {
  const SituationHeaderRow(this.entries);

  final List<PendingAccountEntry> entries;
}

class EntryRow extends PendingRow {
  const EntryRow(this.entry);

  final PendingAccountEntry entry;
}

/// Flattens same-situation [situations] into the linear [PendingRow] list a
/// lazy sliver builds from: a bulk header only where more than one account
/// shares the situation, then that subset's entries.
List<PendingRow> pendingRows(List<List<PendingAccountEntry>> situations) {
  final rows = <PendingRow>[];
  for (final subset in situations) {
    if (subset.length > 1) rows.add(SituationHeaderRow(subset));
    for (final entry in subset) {
      rows.add(EntryRow(entry));
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Wording.
// ---------------------------------------------------------------------------

/// The one-line freshness stamp above a view of the shared state: which
/// generation it is, when it was materialized, by whom — and, since #247, the
/// werkdatum the WISA roster underneath it was pulled with. `null` before the
/// first sync of all.
///
/// That last part is not a restatement of the timestamp. WISA answers *as of* a
/// date, so "gisteren 09:14 door jan" says when the pass ran, never which school
/// year it describes; a pass run on the wrong side of the rollover reads on
/// screen exactly like a class that went missing (#239). It comes off the shared
/// per-system stamp rather than the operator's own Instellingen, so it names the
/// date this *stored view* was pulled with even when the setting has since moved
/// on (#238) — and a passive session that never ran the pass reads the same
/// line.
String? sharedViewFreshness(ReconcileController controller) {
  final state = controller.syncState;
  if (state.generation == 0) return null;
  final at = state.updatedAt;
  // Same dated stamp as the Reconcile last-sync box (#192): time-only made a
  // generation from last week look like one from this morning.
  final when = at == null ? '' : ' · ${formatFreshnessStamp(at)}';
  final who = state.updatedBy == null || state.updatedBy!.isEmpty
      ? ''
      : ' door ${state.updatedBy}';
  // Rendered with the connector's own formatter, so it reads exactly as the
  // `Werkdatum` SOAP parameter went out and as the Log panel's pull line names
  // it. Absent on a view synced before #247 recorded it.
  final workDate = state.systems[core.Origin.wisa]?.workDate;
  final asOf =
      workDate == null ? '' : ' · werkdatum ${wapi.formatWerkdatum(workDate)}';
  return 'Generatie ${state.generation}$when$who$asOf';
}

/// The Dutch name the operator knows a system by — the same names the action
/// summaries and the rest of the screen use (#234). Azure AD is "Office 365"
/// throughout this app, so the dialog says that and not the tenant's technical
/// name.
String systemLabel(core.Origin system) => switch (system) {
      core.Origin.azure => 'Office 365',
      core.Origin.smartschool => 'Smartschool',
      core.Origin.wisa => 'WISA',
      core.Origin.all => 'alle systemen',
      core.Origin.other => 'een ander systeem',
    };

/// Joins system names the way Dutch reads them: "a", "a en b", "a, b en c".
String _joinSystems(Iterable<core.Origin> systems) {
  final names = <String>[
    // Pinned order (WISA → Smartschool → Office 365) so the same selection
    // always reads the same way, whatever order the actions were dispatched in.
    for (final s in systems.toSet().toList()..sort((a, b) => a.index - b.index))
      systemLabel(s),
  ];
  if (names.length <= 1) return names.join();
  return '${names.take(names.length - 1).join(', ')} en ${names.last}';
}

String _changeCount(int n) => n == 1 ? '1 wijziging' : '$n wijzigingen';

String _ruleCount(int n) => n == 1 ? '1 importregel' : '$n importregels';

String _followUpCount(int n) => n == 1 ? '1 vervolgactie' : '$n vervolgacties';

/// The body of the apply-confirmation dialog: what this particular pass will
/// write, and where (#234).
///
/// It used to be one hard-coded sentence claiming "Smartschool and Azure AD"
/// for every action, so a single Graph `PATCH` on one display name announced a
/// write to a system it never touched. Everything needed to say it correctly is
/// on the actions themselves; [ApplyScope] carries it here.
///
/// Three things it is careful about:
/// - **WISA is never written.** The `DontImportFromWisa` family's `ChangeSet`
///   carries `Origin.wisa`, but what it produces is a local import rule — the
///   connector is read-only. So those are counted as import rules and the
///   sentence says outright that nothing is written to WISA.
/// - **Chained follow-ups are named, not counted.** A new student's Office 365
///   create writes Smartschool too (#230/#240). Whether the follow-up runs is
///   decided by its own `evaluate` after the first write, so it gets its own
///   "kan ook" sentence rather than being folded into the count.
/// - **A chain that stays inside a system it already named adds nothing** — a
///   class group's create and its roster write are both Office 365 (#245), so
///   there is no second system to announce.
String applyConfirmationMessage(ApplyScope scope) {
  final writes = scope.systems.where((s) => s != core.Origin.wisa).toList();
  final rules = scope.systems.length - writes.length;
  final clauses = <String>[
    if (writes.isNotEmpty)
      'schrijft ${_changeCount(writes.length)} naar ${_joinSystems(writes)}',
    if (rules > 0)
      'legt ${_ruleCount(rules)} vast (er wordt niets naar WISA geschreven)',
  ];
  final what =
      clauses.isEmpty ? 'Dit schrijft niets.' : 'Dit ${clauses.join(' en ')}.';
  final follow = scope.chained.isEmpty
      ? ''
      : ' Een vervolgactie kan ook naar ${_joinSystems(scope.chained)} '
          'schrijven.';
  return '$what$follow Doe eerst een dry-run om de exacte wijzigingen te '
      'bekijken.';
}

/// One read-only candidate line of a passive-session tile — the account card and
/// the class row share it — worded exactly as the interactive
/// [PendingEntryTile]'s: an either/or reads as one "(keuze)" on its
/// pre-selected half (#251), an informational notice keeps its "(manueel)"
/// marker (#225), and an ordinary action is its bare summary.
///
/// The account card used to render a bare bullet for every candidate (#255), so
/// a student's informational candidate — since #245 the student family has one —
/// read like due work next to a badge that counted it zero.
String readOnlyCandidateLine(actions.Alternatives<CandidateAction> choice) {
  final summary = choice.selected.summary;
  if (choice.isChoice) return '• $summary (keuze)';
  return choice.selected.canApply ? '• $summary' : '• $summary (manueel)';
}

// ---------------------------------------------------------------------------
// Confirm + progress.
// ---------------------------------------------------------------------------

/// Shows the apply-confirmation dialog and, on confirm, runs [apply] behind the
/// modal progress dialog (#110/#243). Shared by the global, per-situation, and
/// per-entry apply affordances so a write is always one deliberate confirmation
/// followed by one visible pass.
///
/// [scope] is what that particular confirmation covers (#234) — the systems the
/// pass will really reach, not a fixed pair.
Future<void> confirmAndApply(
  BuildContext context, {
  required ReconcileController controller,
  required String title,
  required ApplyScope scope,
  required Future<void> Function() apply,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(applyConfirmationMessage(scope)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuleer'),
        ),
        FilledButton(
          key: const ValueKey('actions-apply-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Toepassen'),
        ),
      ],
    ),
  );
  if (!(confirmed ?? false)) return;
  if (!context.mounted) return;
  await runWithProgress(
    context,
    controller: controller,
    dry: false,
    run: apply,
  );
}

/// Runs one dry-run/apply pass behind a **modal** progress dialog (#243).
///
/// An "Apply to all" over the September "zonder klas" bucket is sequential, one
/// connector round-trip per action, and runs for minutes. Its only feedback used
/// to be greyed-out buttons and an indeterminate bar in a page header the
/// operator had usually scrolled past — so the app looked hung, and nothing
/// stopped them scrolling, switching family tab, or navigating away mid-write.
///
/// Every affordance goes through here — global, per-situation, per-entry, and
/// dry-run as well as apply — so the pass behaves the same wherever it is
/// started. A dry-run over hundreds of accounts is exactly as slow and was
/// exactly as silent.
///
/// The dialog's lifetime is bound to [run]'s future rather than to any observed
/// controller state: it is dismissed in a `finally`, so a pass that fails — or
/// one that returns immediately because another is already running — can never
/// strand the operator behind a modal barrier.
Future<void> runWithProgress(
  BuildContext context, {
  required ReconcileController controller,
  required bool dry,
  required Future<void> Function() run,
}) async {
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _ApplyProgressDialog(controller: controller, dry: dry),
  ));
  try {
    await run();
  } finally {
    if (navigator.mounted) navigator.pop();
  }
}

/// The modal dialog a pass runs behind (#243): how far along it is, and the
/// account and action in flight right now.
///
/// Rebuilt from [ReconcileController.applyStep], which the pass publishes before
/// each action off the very list the confirmation dialog was built from, so the
/// count here and the change count the operator just agreed to are the same
/// resolution of the work.
class _ApplyProgressDialog extends StatelessWidget {
  const _ApplyProgressDialog({required this.controller, required this.dry});

  final ReconcileController controller;

  /// Whether this pass writes nothing, which is the one thing the operator most
  /// wants confirmed while staring at a progress dialog for two minutes.
  final bool dry;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    // Non-dismissible: the pass is a sequence of live writes, so there is
    // nothing useful to do behind it and plenty of harm in navigating away.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const ValueKey('actions-progress-dialog'),
        title: Text(dry ? 'Dry-run bezig…' : 'Acties toepassen…'),
        content: SizedBox(
          // A [LinearProgressIndicator] demands all the width it is offered, so
          // without a bound the dialog stretches across a desktop window. Fixed
          // at a readable measure, clamped so a narrow window cannot overflow.
          width: (MediaQuery.sizeOf(context).width - 112).clamp(240.0, 400.0),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final ApplyStep? step = controller.applyStep;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Always determinate — an indeterminate sweep is what #176
                  // replaced on Reconcile, and is what this dialog exists to
                  // stop showing.
                  LinearProgressIndicator(
                    key: const ValueKey('actions-progress-bar'),
                    value: step == null ? 0.0 : (step.index - 1) / step.total,
                  ),
                  const SizedBox(height: PlinkSpacing.s4),
                  Text(
                    key: const ValueKey('actions-progress-count'),
                    step == null
                        ? 'Bezig…'
                        : 'Actie ${step.index} van ${step.total}',
                    style: text.titleSmall,
                  ),
                  if (step != null) ...<Widget>[
                    const SizedBox(height: PlinkSpacing.s1),
                    Text(
                      key: const ValueKey('actions-progress-step'),
                      '${step.target} — ${step.summary}',
                      style: text.bodyMedium,
                    ),
                  ],
                  if (step != null && step.followUps > 0) ...<Widget>[
                    const SizedBox(height: PlinkSpacing.s2),
                    Text(
                      key: const ValueKey('actions-progress-followups'),
                      // Named, never folded into the count: a follow-up is not
                      // in the pending list, so it cannot be part of the total
                      // the operator was shown (#230/#240/#245).
                      '+ ${_followUpCount(step.followUps)} gestart door een '
                      'eerdere actie.',
                      style: text.bodySmall,
                    ),
                  ],
                  const SizedBox(height: PlinkSpacing.s3),
                  Text(
                    dry
                        ? 'Er wordt niets geschreven.'
                        : 'Sluit het venster niet tot de reeks klaar is.',
                    style: text.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small shared widgets.
// ---------------------------------------------------------------------------

/// The "N pending here" badge, or a muted tick when there is nothing to do.
class PendingBadge extends StatelessWidget {
  const PendingBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return Icon(Icons.check,
          size: 16, color: Theme.of(context).disabledColor);
    }
    return PlinkBadge('$count');
  }
}

/// The muted lock a read-only card carries where an interactive tile carries
/// its expand affordance (#214) — the per-row half of the read-only state,
/// explained once by [ReadOnlyNotice] at the top of the list.
class ReadOnlyLock extends StatelessWidget {
  const ReadOnlyLock({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Alleen-lezen — synchroniseer om acties toe te passen',
        child: Icon(
          Icons.lock_outline,
          size: 16,
          color: Theme.of(context).disabledColor,
        ),
      );
}

class EmptyLine extends StatelessWidget {
  const EmptyLine(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) =>
      Text(message, style: Theme.of(context).textTheme.bodyMedium);
}

/// The read-only announcement above a list whose session has no linked view
/// (#214).
///
/// `ReconcileController.linked` is what the interactive [PendingEntryTile] path
/// is built from: the choices, the per-entry dry-run and apply. Without it the
/// list can only render the stored account / group documents as static cards —
/// correct, but silently so, which reads as an interactive list that stopped
/// responding. This says which of the two the operator is looking at, why, and
/// offers the sync that turns one into the other.
///
/// Two ways to get here, and the operator is told which: a **passive** session
/// that only read the shared overview (`loadOverview()`, never synced), or one
/// whose sync/drift pass **failed** before it could link. A failed pass never
/// discards an existing linked view — `_fail` records the error and returns to
/// `ready`, leaving `linked` untouched — so the failure wording only ever
/// appears when this session had nothing linked to begin with.
///
/// [keyValue] names the notice per screen, so a shell that has built both tabs
/// still has one identifiable notice per view.
class ReadOnlyNotice extends StatelessWidget {
  const ReadOnlyNotice({
    super.key,
    required this.controller,
    this.keyValue = 'actions-read-only',
  });

  final ReconcileController controller;
  final String keyValue;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool failed = controller.error != null;
    final bool lockedByOther = controller.syncLockedByOther;

    return Container(
      key: ValueKey(keyValue),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: colors.primary),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.visibility_outlined, size: 18, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Alleen-lezen overzicht', style: text.titleSmall),
                    const SizedBox(height: PlinkSpacing.s1),
                    Text(
                      failed
                          ? 'De laatste sync is mislukt, dus deze sessie heeft '
                              'geen actuele acties om toe te passen. Hieronder '
                              'staat het gedeelde overzicht van de vorige sync.'
                          : 'Deze sessie heeft nog niet gesynchroniseerd, dus '
                              'deze acties kunnen niet worden toegepast. '
                              'Hieronder staat het gedeelde overzicht van de '
                              'laatste sync.',
                      style: text.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s3),
          FilledButton.icon(
            key: const ValueKey('actions-read-only-sync'),
            onPressed:
                controller.busy || lockedByOther ? null : controller.sync,
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Synchroniseer'),
          ),
          // A dead Synchronise needs its reason on screen too — the same
          // named-holder line the Reconcile screen shows (#108).
          if (lockedByOther) ...<Widget>[
            const SizedBox(height: PlinkSpacing.s2),
            Text(
              '${controller.syncLockOwner} is aan het synchroniseren…',
              style: text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// Full-panel message (loading / not-configured / error), mirroring the other
/// screens' panels so the views read as one app.
class MessagePanel extends StatelessWidget {
  const MessagePanel({
    super.key,
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

// ---------------------------------------------------------------------------
// Interactive tiles.
// ---------------------------------------------------------------------------

/// The bulk header of one "same situation" subset (#110): the "apply this
/// resolution to all" affordance that honours each entry's own chosen
/// alternative. Rendered as its own row in the lazy list, only when more than
/// one account shares the situation.
///
/// Every affordance here acts on [entries] — the exact subset this header was
/// built over and counts (#252). That list is already scoped by whatever list
/// rendered it: the open classroom's pending entries, or the class inventory's,
/// narrowed further by the search box. The bulk pass used to re-resolve the
/// situation key against the *whole* linked view instead, so a header reading
/// "Alles toepassen (1)" inside one class wrote every account group-wide in the
/// same situation. The label, the confirmation scope and the write are now one
/// list, so they cannot drift apart again.
class SituationHeader extends StatelessWidget {
  const SituationHeader({
    super.key,
    required this.controller,
    required this.entries,
    this.noun = 'accounts',
  });

  final ReconcileController controller;
  final List<PendingAccountEntry> entries;

  /// What this subset is a subset *of*, in Dutch — "accounts" in a classroom,
  /// "klassen" in the class inventory (#227).
  final String noun;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final key = entries.first.situationKey;
    final applyable = entries.where((e) => e.canApply).length;

    return Padding(
      padding: const EdgeInsets.only(
        top: PlinkSpacing.s2,
        bottom: PlinkSpacing.s2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${entries.first.situationLabel} — ${entries.length} '
              '$noun in dezelfde situatie',
              style: text.titleSmall,
            ),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          OutlinedButton(
            key: ValueKey('situation-dry-run-$key'),
            onPressed: controller.busy || applyable == 0
                ? null
                : () => runWithProgress(
                      context,
                      controller: controller,
                      dry: true,
                      run: () => controller.dryRunEntries(entries),
                    ),
            child: const Text('Dry-run alles'),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          FilledButton(
            key: ValueKey('situation-apply-$key'),
            onPressed: controller.busy || applyable == 0
                ? null
                : () => confirmAndApply(
                      context,
                      controller: controller,
                      title: 'Toepassen op ${entries.length} $noun?',
                      // The dialog is scoped to the very entries the pass below
                      // runs over — the ones this header counted (#234/#252).
                      scope: controller.applyScope(entries),
                      apply: () => controller.applyEntries(entries),
                    ),
            child: Text('Alles toepassen ($applyable)'),
          ),
        ],
      ),
    );
  }
}

/// The collapsed line one [PendingChoice] reads as: an either/or is marked
/// "(keuze)" on its pre-selected half, an informational action "(manueel)", and
/// an ordinary one is its bare summary.
String pendingChoiceLine(PendingChoice c) {
  final summary = c.selected.changes.summary;
  if (c.isChoice) return '$summary (keuze)';
  return c.selected.canApply ? summary : '$summary (manueel)';
}

/// One account's pending resolution (#110): a single expandable row showing the
/// selected summary, the mutually-exclusive choice (as radios) when there is
/// one, the per-field diff, and per-entry dry-run / apply.
class PendingEntryTile extends StatelessWidget {
  const PendingEntryTile({
    super.key,
    required this.controller,
    required this.entry,
  });

  final ReconcileController controller;
  final PendingAccountEntry entry;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;

    return Container(
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: ExpansionTile(
        key: ValueKey('entry-${entry.family}-${entry.targetId}'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: PlinkBadge(entry.family),
        title: Text(entry.target, style: text.bodyLarge),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final c in entry.choices)
              Text(pendingChoiceLine(c), style: text.bodySmall),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          PlinkSpacing.s5,
          0,
          PlinkSpacing.s5,
          PlinkSpacing.s4,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: entryDetail(context, controller: controller, entry: entry),
      ),
    );
  }
}

/// The expanded body of one pending entry: the radios (or the lone option's
/// diff), the verdict of the last pass that touched this entry (#272), and the
/// per-entry dry-run / apply pair.
///
/// Split out of [PendingEntryTile] so the class inventory can put the very same
/// controls under a row that carries its own presence columns (#227), rather
/// than nesting one expandable tile inside another.
List<Widget> entryDetail(
  BuildContext context, {
  required ReconcileController controller,
  required PendingAccountEntry entry,
}) =>
    <Widget>[
      for (final choice in entry.choices)
        if (choice.isChoice)
          ChoiceControl(controller: controller, entry: entry, choice: choice)
        else
          OptionDetail(option: choice.selected),
      EntryOutcomes(controller: controller, entry: entry),
      const SizedBox(height: PlinkSpacing.s3),
      Row(
        children: <Widget>[
          OutlinedButton(
            key: ValueKey('entry-dry-run-${entry.targetId}'),
            onPressed: controller.busy || !entry.canApply
                ? null
                : () => runWithProgress(
                      context,
                      controller: controller,
                      dry: true,
                      run: () => controller.dryRunEntry(entry),
                    ),
            child: const Text('Dry-run'),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          FilledButton(
            key: ValueKey('entry-apply-${entry.targetId}'),
            onPressed: controller.busy || !entry.canApply
                ? null
                : () => confirmAndApply(
                      context,
                      controller: controller,
                      title: 'Toepassen voor ${entry.target}?',
                      scope:
                          controller.applyScope(<PendingAccountEntry>[entry]),
                      apply: () => controller.applyEntry(entry),
                    ),
            child: const Text('Toepassen'),
          ),
        ],
      ),
    ];

/// What the last pass did for **this** entry (#272), rendered on the entry's own
/// card and nowhere else.
///
/// The bug this exists for: applying a WISA-only class runs two writes — create
/// the class in Smartschool, create its `<PREFIX>-<KLAS>` Office 365 group — and
/// when Graph refused the second one, the operator had no way to learn it from
/// the card they pressed **Toepassen** on. The failure *was* recorded, twice:
/// as a log line on the Reconcile screen, and as a row in a page-level results
/// section appended below the entire Klasgroepen inventory. Neither is on screen
/// when one class halfway down a few hundred rows is applied, so a refused write
/// and a write that never ran read exactly the same — and the report was that
/// the Office 365 group "never lands".
///
/// Deliberately part of [entryDetail] rather than of either screen: both Acties
/// and Klasgroepen apply entries, and a verdict that only one of them shows is
/// the same gap again. The page-level sections stay — they report the *pass*,
/// which is what a bulk apply over hundreds of accounts needs.
///
/// Renders nothing when this entry took no part in the last pass, which is the
/// state after every sync.
class EntryOutcomes extends StatelessWidget {
  const EntryOutcomes({
    super.key,
    required this.controller,
    required this.entry,
  });

  final ReconcileController controller;
  final PendingAccountEntry entry;

  @override
  Widget build(BuildContext context) {
    final List<ActionOutcomeEntry> outcomes =
        controller.applyOutcomesFor(entry);
    if (outcomes.isEmpty) return const SizedBox.shrink();

    final TextTheme text = Theme.of(context).textTheme;
    // A dry-run pass and an apply pass are never mixed: `_run` clears the other
    // list before it starts, so the whole block is one or the other.
    final bool dry =
        outcomes.every((o) => o.outcome == actions.ActionOutcome.dryRun);

    return Padding(
      key: ValueKey('entry-outcomes-${entry.family}-${entry.targetId}'),
      padding: const EdgeInsets.only(top: PlinkSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            // Deliberately not the page-level section's wording ("Resultaat van
            // het toepassen"): that one reports the pass, this one reports this
            // record, and an operator who sees both must be able to tell which
            // is which. "Vorige poging" also says the thing the operator needs
            // next — a failed write can simply be run again.
            dry
                ? 'Resultaat van de vorige dry-run'
                : 'Resultaat van de vorige poging',
            style: text.titleSmall,
          ),
          const SizedBox(height: PlinkSpacing.s1),
          for (final outcome in outcomes) EntryOutcomeLine(outcome: outcome),
        ],
      ),
    );
  }
}

/// One line of an [EntryOutcomes] block: what the write did, and — when it
/// failed — why, in the words the system that refused it used.
///
/// The reason is the point. "Mislukt" alone sends the operator back to the log
/// panel on another screen, which is exactly the trip #272 is about; the Graph
/// `403 Authorization_RequestDenied` or the duplicate-nickname message decides
/// what they do next.
class EntryOutcomeLine extends StatelessWidget {
  const EntryOutcomeLine({super.key, required this.outcome});

  final ActionOutcomeEntry outcome;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool failed = outcome.outcome == actions.ActionOutcome.failed;

    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            failed ? Icons.close : Icons.check,
            size: 16,
            color: failed ? colors.error : colors.primary,
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            child: Text(
              failed
                  ? 'Mislukt — ${outcome.changes.summary}: ${outcome.error}'
                  : outcome.changes.summary,
              style: text.bodySmall?.copyWith(
                color: failed ? colors.error : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The subtitle of a page-level **apply** results section (#272).
///
/// A pass that wrote nothing but failures used to be announced as "Weggeschreven
/// naar de doelsystemen." — the one line an operator scanning past the results
/// reads, and it said the opposite of what happened. The log already words the
/// tally this way ("N gelukt, M mislukt"), so the screen now says the same thing
/// the log does.
String applyResultsSubtitle(List<ActionOutcomeEntry> results) {
  final int failed =
      results.where((r) => r.outcome == actions.ActionOutcome.failed).length;
  if (failed == 0) return 'Weggeschreven naar de doelsystemen.';
  return '${results.length - failed} gelukt, $failed mislukt. '
      'Een mislukte actie schreef niets en blijft openstaan.';
}

/// The radio group for a mutually-exclusive choice (#110): the operator picks
/// exactly one resolution; the selected one is what an apply runs.
class ChoiceControl extends StatelessWidget {
  const ChoiceControl({
    super.key,
    required this.controller,
    required this.entry,
    required this.choice,
  });

  final ReconcileController controller;
  final PendingAccountEntry entry;
  final PendingChoice choice;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Kies één oplossing:',
          style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        for (final option in choice.alternatives)
          InkWell(
            key: ValueKey('alt-${entry.targetId}-${option.kind}'),
            onTap: controller.busy
                ? null
                : () => controller.chooseAlternative(
                      entry: entry,
                      group: option.group!,
                      kind: option.kind,
                    ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: PlinkSpacing.s1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    option.kind == choice.selected.kind
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: option.kind == choice.selected.kind
                        ? colors.primary
                        : Theme.of(context).disabledColor,
                  ),
                  const SizedBox(width: PlinkSpacing.s2),
                  Expanded(
                    child: Text(option.changes.summary, style: text.bodySmall),
                  ),
                ],
              ),
            ),
          ),
        // What the picked resolution will actually write. Collapsing two
        // actions into one choice (#244) must not cost the operator the diff
        // they used to read off the second row — a class create names the class,
        // its description and its Smartschool parent, and that is exactly what
        // decides whether the create or the opt-out is right.
        const SizedBox(height: PlinkSpacing.s2),
        OptionDetail(option: choice.selected),
      ],
    );
  }
}

/// The per-field diff (or a lifecycle note) for a single option — the one that
/// stands alone, or the one selected inside a [ChoiceControl].
class OptionDetail extends StatelessWidget {
  const OptionDetail({super.key, required this.option});

  final PendingActionOption option;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final fields = option.changes.fields;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: fields.isEmpty
          ? <Widget>[
              Text(
                option.canApply
                    ? 'Levenscyclusactie — geen wijzigingen per veld.'
                    : '${option.changes.summary} '
                        '(manueel — wordt niet automatisch toegepast)',
                style: text.bodySmall,
              ),
            ]
          : <Widget>[
              for (final f in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
                  child: Text(
                    '${f.field}: ${f.before ?? '∅'} → ${f.after ?? '∅'}',
                    style: text.bodySmall,
                  ),
                ),
            ],
    );
  }
}
