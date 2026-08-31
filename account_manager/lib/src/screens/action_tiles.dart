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
import 'package:account_state/account_state.dart'
    show CandidateAction, SystemSyncMeta;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';
// The `Werkdatum` SOAP parameter's own formatter, so the freshness line names
// the date exactly as it went on the wire and as the Log panel reports it
// (#247).
import 'package:wisa_api/wisa_api.dart' as wapi show formatWerkdatum;

import '../format/timestamps.dart';
import '../reconcile/reconcile_controller.dart';
// The remembered uitschrijvingsdatum (#394): per-operator, per-machine working
// state, deliberately not the shared settings document.
import '../settings/local_preferences.dart';
// The tab names and the seam that selects one (#301) — the pointer each action
// screen carries at the other has to be able to follow itself. Deliberately the
// small `shell_navigation.dart` and not `app_shell.dart`, which imports the very
// screens that import this library.
import '../shell/shell_navigation.dart';
import 'system_indicator.dart';

// The system vocabulary both action screens speak (#298) — what a coloured
// WISA / Smartschool / Office 365 cell means, and how an action line names the
// system it writes to. Re-exported so a screen that already imports the tile
// library gets it without a second import, exactly as `systemLabel` was reached
// before it moved there.
export 'system_indicator.dart';

// ---------------------------------------------------------------------------
// Ordering.
// ---------------------------------------------------------------------------

/// Orders class names the way an operator reads a class list: by year first and
/// numerically (`2A` before `10A`), then alphabetically, so `2F` sorts beside
/// its sub-groups rather than between `20A` and `21B`.
///
/// Shared since #295: the Klasgroepen inventory is class-ordered, and the flat
/// Acties list orders by class too. Two screens listing the same classes in two
/// different orders is the kind of difference an operator reads as a bug.
int compareClassNames(String a, String b) {
  final ya = _leadingYear(a);
  final yb = _leadingYear(b);
  if (ya != yb) {
    // A non-numeric class (`OKAN`) sorts after every numbered year.
    if (ya == null) return 1;
    if (yb == null) return -1;
    return ya - yb;
  }
  return a.toLowerCase().compareTo(b.toLowerCase());
}

int? _leadingYear(String name) {
  final match = RegExp(r'^\s*(\d+)').firstMatch(name);
  return match == null ? null : int.tryParse(match.group(1)!);
}

// The `PendingRow` / `pendingRows` flattening that interleaved a classroom's
// bulk headers with its entry tiles is gone with the drill-down it served
// (#295). Klasgroepen collects its [SituationHeader]s above the inventory
// directly, and the flat Acties list has no cohort headers at all until #296
// gives school-wide bulk apply its own cohort-first affordance.

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
///   carries `Origin.wisa`, but what it produces is an import rule — the
///   connector is read-only. So those are counted as import rules and the
///   sentence says outright that nothing is written to WISA. Since #276 the
///   rule lands on the *shared* settings document rather than dying with the
///   session, so the sentence says that too: this is a standing decision every
///   operator inherits, not a one-run one, and the operator must know that
///   before pressing the button (undoing it means finding the rule in
///   Instellingen → Wisa).
/// - **Chained follow-ups are named, not counted.** A new student's Office 365
///   create writes Smartschool too (#230/#240). Whether the follow-up runs is
///   decided by its own `evaluate` after the first write, so it gets its own
///   "kan ook" sentence rather than being folded into the count.
/// - **A chain that stays inside a system it already named adds nothing** — a
///   class group's create and its roster write are both Office 365 (#245), so
///   there is no second system to announce.
/// - **The uitschrijvingsdatum is quoted back** (#394). The operator answered it
///   a moment ago in its own dialog, but a remembered date can be weeks old and
///   this is the last screen before the write — so the confirmation is where a
///   stale one is meant to be caught.
String applyConfirmationMessage(ApplyScope scope, {DateTime? deletionDate}) {
  final writes = scope.systems.where((s) => s != core.Origin.wisa).toList();
  final rules = scope.systems.length - writes.length;
  final clauses = <String>[
    if (writes.isNotEmpty)
      'schrijft ${_changeCount(writes.length)} naar ${_joinSystems(writes)}',
    if (rules > 0)
      'bewaart ${_ruleCount(rules)} blijvend voor iedereen (er wordt niets '
          'naar WISA geschreven)',
  ];
  final what =
      clauses.isEmpty ? 'Dit schrijft niets.' : 'Dit ${clauses.join(' en ')}.';
  final follow = scope.chained.isEmpty
      ? ''
      : ' Een vervolgactie kan ook naar ${_joinSystems(scope.chained)} '
          'schrijven.';
  final dated = deletionDate == null
      ? ''
      : ' De uitschrijvingsdatum is ${formatOfficialDate(deletionDate)}.';
  return '$what$follow$dated Doe eerst een dry-run om de exacte wijzigingen te '
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
///
/// The system the action lands in is **not** in the string: [ActionLine] puts
/// it in front as a tag of its own (#298), so the summary stays the one
/// addressable string the dialogs and outcome rows also quote. That tag also
/// took over from the leading bullet these lines used to carry — two leaders on
/// one line read as a typo, and the interactive tile's lines never had one, so
/// dropping it is what finally makes the two identical.
String readOnlyCandidateLine(actions.Alternatives<CandidateAction> choice) {
  final summary = choice.selected.summary;
  if (choice.isChoice) return '$summary (keuze)';
  return choice.selected.canApply ? summary : '$summary (manueel)';
}

// ---------------------------------------------------------------------------
// Confirm + progress.
// ---------------------------------------------------------------------------

/// Shows the apply-confirmation dialog and, on confirm, runs [apply] behind the
/// modal progress dialog (#110/#243). Shared by the per-situation and
/// per-entry apply affordances so a write is always one deliberate confirmation
/// followed by one visible pass.
///
/// [scope] is what that particular confirmation covers (#234) — the systems the
/// pass will really reach, not a fixed pair.
///
/// Answers whether the pass actually ran, so a caller can tell "the operator
/// said no" from "the writes are done" (#296): a cancelled confirmation must
/// leave the screen exactly as the operator left it, while a finished pass has
/// invalidated everything the affordance was built from.
///
/// Since #394 a pass whose actions carry an official date
/// ([ApplyScope.needsDeletionDate]) asks for that date **before** the
/// confirmation, and the confirmation then quotes it. [apply] receives the
/// answer — `null` for every other pass, which is every pass that behaved this
/// way before.
///
/// The order matters: asking first is what lets the confirmation be the last
/// place a stale remembered date can be caught. Cancelling *either* dialog
/// applies nothing.
Future<bool> confirmAndApply(
  BuildContext context, {
  required ReconcileController controller,
  required String title,
  required ApplyScope scope,
  required Future<void> Function(DateTime? deletionDate) apply,
}) async {
  final LocalPreferences? preferences = LocalPreferencesScope.maybeOf(context);
  DateTime? deletionDate;
  if (scope.needsDeletionDate) {
    deletionDate = await askDeletionDate(
      context,
      // What the operator answered last, whenever that was — the same batch
      // spans coffee breaks and app updates, which is why this is persisted and
      // not merely held for the session. Today on a fresh install.
      initial: preferences?.lastDeletionDate,
    );
    // Cancelled at the date: nothing is written and no confirmation is offered.
    if (deletionDate == null) return false;
    if (!context.mounted) return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content:
          Text(applyConfirmationMessage(scope, deletionDate: deletionDate)),
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
  if (!(confirmed ?? false)) return false;
  if (!context.mounted) return false;
  // Remembered only once the operator has actually confirmed with it, so a date
  // typed and then thought better of at the confirmation does not become the
  // default for the next student.
  if (deletionDate != null) {
    await preferences?.setLastDeletionDate(deletionDate);
    if (!context.mounted) return false;
  }
  await runWithProgress(
    context,
    controller: controller,
    dry: false,
    run: () => apply(deletionDate),
  );
  return true;
}

/// A date rendered the way this app writes dates everywhere the exact day
/// matters — the werkdatum field's own `yyyy-MM-dd`, which sorts, never depends
/// on whether the reader parses `03/04` as March or April, and matches what the
/// Log panel prints when the write goes out.
String formatOfficialDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// How far ahead of today a date stops looking like a decision and starts
/// looking like a typo. A departure can legitimately be planned — the last day
/// of the school year is announced months in advance — so this is generous.
const Duration kDeletionDateFutureWarning = Duration(days: 400);

/// The same in the other direction. Backdating is the normal case (the operator
/// is recording a departure that already happened), so only a date old enough
/// to be from the wrong *school career* is remarked on.
const Duration kDeletionDatePastWarning = Duration(days: 730);

/// What is odd about [date], or `null` when nothing is (#394).
///
/// Deliberately advisory. Both readings are legitimate — a planned end-of-year
/// departure is in the future, and a correction filed in October for a student
/// who left in March is in the past — so the app says what it noticed and lets
/// the operator decide. Blocking would make the app wrong about the one thing
/// it cannot know, which is what actually happened.
String? deletionDateWarning(DateTime date, {DateTime? now}) {
  final DateTime today = now ?? DateTime.now();
  final DateTime midnight = DateTime(today.year, today.month, today.day);
  final Duration delta =
      DateTime(date.year, date.month, date.day).difference(midnight);
  if (delta > kDeletionDateFutureWarning) {
    return 'Deze datum ligt meer dan een jaar in de toekomst. Klopt dat?';
  }
  if (-delta > kDeletionDatePastWarning) {
    return 'Deze datum ligt meer dan twee jaar in het verleden. Klopt dat?';
  }
  return null;
}

/// Asks for the **uitschrijvingsdatum** a pass will write (#394), returning it
/// or `null` when the operator cancelled.
///
/// Its own step rather than a field on the confirmation dialog because it is a
/// different kind of question: the confirmation asks "shall I", this asks "as
/// of when", and the answer to the second is quoted back inside the first.
///
/// [initial] is what the operator last applied with, or `null` on a fresh
/// install — the field then offers today. Today is the honest default; it is
/// also the value the app used to supply silently, and the whole difference is
/// that it is now on screen where a wrong one can be seen.
Future<DateTime?> askDeletionDate(
  BuildContext context, {
  DateTime? initial,
  DateTime? now,
}) {
  final DateTime today = now ?? DateTime.now();
  return showDialog<DateTime>(
    context: context,
    builder: (context) => _DeletionDateDialog(
      initial: initial ?? DateTime(today.year, today.month, today.day),
      today: today,
    ),
  );
}

class _DeletionDateDialog extends StatefulWidget {
  const _DeletionDateDialog({required this.initial, required this.today});

  final DateTime initial;
  final DateTime today;

  @override
  State<_DeletionDateDialog> createState() => _DeletionDateDialogState();
}

class _DeletionDateDialogState extends State<_DeletionDateDialog> {
  late DateTime _date = widget.initial;

  Future<void> _pick() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      // The same range the werkdatum picker offers, so the two date fields in
      // this app do not disagree about what a plausible date is.
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? warning = deletionDateWarning(_date, now: widget.today);
    return AlertDialog(
      key: const ValueKey('deletion-date-dialog'),
      title: const Text('Uitschrijvingsdatum'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Smartschool legt deze datum vast als de dag waarop de leerling '
            'de school verlaten heeft. Kies de echte datum, niet vandaag.',
          ),
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            children: <Widget>[
              Text(
                formatOfficialDate(_date),
                key: const ValueKey('deletion-date-value'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(width: PlinkSpacing.s3),
              OutlinedButton(
                key: const ValueKey('deletion-date-pick'),
                onPressed: _pick,
                child: const Text('Kies datum'),
              ),
            ],
          ),
          if (warning != null) ...<Widget>[
            const SizedBox(height: PlinkSpacing.s3),
            Text(
              warning,
              key: const ValueKey('deletion-date-warning'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('deletion-date-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuleer'),
        ),
        FilledButton(
          key: const ValueKey('deletion-date-confirm'),
          onPressed: () => Navigator.of(context).pop(_date),
          child: const Text('Doorgaan'),
        ),
      ],
    );
  }
}

/// Runs one dry-run/apply pass behind a **modal** progress dialog (#243).
///
/// An "Apply to all" over the September "zonder klas" bucket is sequential, one
/// connector round-trip per action, and runs for minutes. Its only feedback used
/// to be greyed-out buttons and an indeterminate bar in a page header the
/// operator had usually scrolled past — so the app looked hung, and nothing
/// stopped them scrolling, switching family tab, or navigating away mid-write.
///
/// Every affordance goes through here — per-situation and per-entry, dry-run as
/// well as apply — so the pass behaves the same wherever it is started. A
/// dry-run over hundreds of accounts is exactly as slow and was exactly as
/// silent.
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
/// Three ways to get here, and the operator is told which: a session whose
/// sync/drift pass **failed** before it could link, one that was **refused** the
/// shared cold seed and says why ([ReconcileController.seedRefusedReason],
/// #287), or one that has simply not opened yet. A failed pass never discards an
/// existing linked view — `_fail` records the error and returns to `ready`,
/// leaving `linked` untouched — so the failure wording only ever appears when
/// this session had nothing linked to begin with.
///
/// Since #287 the ordinary passive session is *not* one of them: a session
/// holding a usable cold seed adopts the shared state and renders
/// [SharedStateNotice] instead, because the view it is offering is real.
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
    // Why the shared state could not be adopted (#287) — the one blocking
    // notice a refused session owes the operator. A pass that just failed is
    // the more recent news, so it still speaks first.
    final String? refused = controller.seedRefusedReason;
    final String reason = failed
        ? 'De laatste sync is mislukt, dus deze sessie heeft geen actuele '
            'acties om toe te passen.'
        : refused ??
            'Deze sessie heeft nog niet gesynchroniseerd, dus deze acties '
                'kunnen niet worden toegepast.';

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
                      '$reason Hieronder staat het gedeelde overzicht van de '
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

/// The announcement above a list this session is acting on but did **not** pull
/// for itself (#287): the linked view was built from the cold seed a colleague's
/// sync left in the shared store.
///
/// The counterpart of [ReadOnlyNotice], and deliberately not a warning. The
/// tiles below it are the real interactive ones — choices, dry-run, apply — so
/// this says only where the view came from and when, and leaves both passes
/// within reach for an operator who decides they want something fresher. That is
/// the whole product point of #287: the people who edit WISA are the people who
/// use this app, so the tool shows how fresh the shared state is instead of
/// demanding proof of freshness on every launch.
///
/// [keyValue] names it per screen, exactly as [ReadOnlyNotice] is named.
class SharedStateNotice extends StatelessWidget {
  const SharedStateNotice({
    super.key,
    required this.controller,
    this.keyValue = 'actions-shared-state',
  });

  final ReconcileController controller;
  final String keyValue;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final SystemSyncMeta? from = controller.adoptedFrom;
    final bool lockedByOther = controller.syncLockedByOther;

    // Dated as soon as it leaves today (#192), the same stamp the Synchronisatie
    // screen's last-sync box renders — a pull from three days ago must not read
    // like this morning's.
    final String when =
        from == null ? '' : ' van ${formatFreshnessStamp(from.at)}';
    final String by =
        from == null || from.syncedBy.isEmpty ? '' : ', door ${from.syncedBy}';
    // The werkdatum the roster is *as of* (#247): it is what decides which
    // school year the list below describes, and this session did not run the
    // pull that chose it.
    final DateTime? workDate = from?.workDate;
    final String asOf = workDate == null
        ? ''
        : ' De klaslijsten zijn die van werkdatum '
            '${wapi.formatWerkdatum(workDate)}.';

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
              Icon(Icons.groups_outlined, size: 18, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Gedeelde synchronisatie', style: text.titleSmall),
                    const SizedBox(height: PlinkSpacing.s1),
                    Text(
                      'Deze weergave komt van de gedeelde synchronisatie'
                      '$when$by. Je kan er meteen mee werken.$asOf',
                      style: text.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s3),
          Wrap(
            spacing: PlinkSpacing.s3,
            runSpacing: PlinkSpacing.s2,
            children: <Widget>[
              FilledButton.icon(
                key: ValueKey('$keyValue-sync'),
                onPressed:
                    controller.busy || lockedByOther ? null : controller.sync,
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Synchroniseer'),
              ),
              OutlinedButton.icon(
                key: ValueKey('$keyValue-drift'),
                onPressed:
                    controller.canCheckDrift ? controller.checkDrift : null,
                icon: const Icon(Icons.difference_outlined, size: 18),
                label: const Text('Controleer op drift'),
              ),
            ],
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

/// The pointer one action screen carries at the other (#301).
///
/// Acties covers people and Klasgroepen covers classes, and since #227 the split
/// is right — but it means "is everything as expected?" is only answerable by
/// visiting both, and nothing on either screen said so. The gap has teeth at a
/// rollover, where the two halves of one operation live on opposite sides of it:
/// the Smartschool class change is per student in Acties, while the Office 365
/// roster write is one `SyncAzureClassGroupMembers` per class in Klasgroepen. An
/// operator can work Acties to a clean list and leave 150 stale rosters behind.
///
/// So each header states what the other screen is holding, and following the
/// line lands there.
///
/// Three things it is careful about:
///
/// - **One derivation per count.** Both numbers come from the controller
///   ([ReconcileController.classesNeedingAttention] /
///   [ReconcileController.accountsNeedingAttention]) rather than from the screen
///   that renders the line, so the pointer and the header it points at cannot
///   drift apart. A pointer quoting a number the destination then contradicts
///   is worse than no pointer at all.
/// - **Silence when there is nothing.** A line reading "0 klas(sen)" is noise in
///   the one case where the operator is actually done, so a zero count renders
///   nothing whatsoever.
/// - **It still reads outside the shell.** [ShellNavigation] is absent in a
///   widget test and in any embedding that is not the rail, and the sentence is
///   true either way — so it degrades to plain prose rather than vanishing.
class OtherTabAttentionLine extends StatelessWidget {
  /// The line **Acties** carries: how many classes Klasgroepen is holding.
  const OtherTabAttentionLine.classes({required this.count})
      : _noun = 'klas(sen)',
        _screen = 'Klasgroepen',
        _tab = ShellTab.klasgroepen,
        super(key: const ValueKey('actions-class-attention'));

  /// The line **Klasgroepen** carries: how many accounts Acties is holding.
  const OtherTabAttentionLine.accounts({required this.count})
      : _noun = 'account(s)',
        _screen = 'Acties',
        _tab = ShellTab.acties,
        super(key: const ValueKey('class-groups-account-attention'));

  /// How many rows the *other* screen has that ask something of the operator.
  final int count;

  final String _noun;
  final String _screen;
  final ShellTab _tab;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final ShellNavigation? shell = ShellNavigation.maybeOf(context);
    // "vragen" stays invariant beside the "(s)" plural, exactly as the
    // Klasgroepen header's own "waarvan N aandacht vragen" does.
    final String sentence = '$count $_noun vragen ook aandacht op $_screen.';

    if (shell == null) return Text(sentence, style: text.bodySmall);
    return InkWell(
      onTap: () => shell.go(_tab),
      child: Text(
        sentence,
        style: text.bodySmall?.copyWith(
          color: colors.primary,
          decoration: TextDecoration.underline,
          decorationColor: colors.primary,
        ),
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

/// The bulk header of one [SituationCohort] (#110/#292): the "apply this one
/// decision to every account that needs it" affordance, honouring each
/// account's own chosen alternative. Rendered as its own row in the lazy list,
/// only when more than one account raises the decision.
///
/// Every affordance here acts on [cohort]'s decisions — the exact members this
/// header was built over and counts (#252). That list is already scoped by
/// whatever list rendered it: the open classroom's pending entries, or the class
/// inventory's, narrowed further by the search box. The bulk pass used to
/// re-resolve the situation key against the *whole* linked view instead, so a
/// header reading "Alles toepassen (1)" inside one class wrote every account
/// group-wide in the same situation. The label, the confirmation scope and the
/// write are one list, so they cannot drift apart again.
///
/// Since #292 that list is one decision deep as well as scoped. The header names
/// a single decision, so the pass behind it writes a single decision: pressing
/// "Wijzig Klas in Smartschool" on fourteen students no longer also writes the
/// email fix one of them happens to need. That is what makes the claim on the
/// button verifiable at all — the operator can read one action's description and
/// know what the button does to everyone in the cohort.
///
/// And since #326 the pair is offered only over resolutions #293 sanctions for
/// a bulk pass ([SituationCohort.bulkApplyable]) — never merely over the ones
/// that write *something*. The two questions came apart the moment an operator
/// flipped two rows of one situation to a destructive alternative: the header
/// counted them, armed, and took both Office 365 groups off one press, on an
/// action whose own class says no bulk affordance may offer it. When nothing in
/// the cohort survives that narrowing the buttons are gone rather than dead,
/// because a disabled "Alles toepassen (0)" invites the operator to go and make
/// it enabled — which is precisely the move this guards against. The line
/// naming the cohort stays: "2 klassen in dezelfde situatie" is worth reading
/// even when there is nothing to press.
class SituationHeader extends StatelessWidget {
  const SituationHeader({
    super.key,
    required this.controller,
    required this.cohort,
    this.noun = 'accounts',
  });

  final ReconcileController controller;
  final SituationCohort cohort;

  /// What this cohort is a cohort *of*, in Dutch — "accounts" in a classroom,
  /// "klassen" in the class inventory (#227).
  final String noun;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String key = cohort.key;
    // The members a bulk pass may write — [PendingDecision.canApply] *and* the
    // #293 sanction (#326). The pair below is built from this list, quotes its
    // length, confirms its scope and hands it to the pass, so the four cannot
    // drift apart; when it is empty there is no pair at all.
    final List<PendingDecision> writable = cohort.bulkApplyable;

    return Padding(
      padding: const EdgeInsets.only(
        top: PlinkSpacing.s2,
        bottom: PlinkSpacing.s2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${cohort.label} — ${cohort.length} '
              '$noun in dezelfde situatie',
              style: text.titleSmall,
            ),
          ),
          if (writable.isNotEmpty) ...<Widget>[
            const SizedBox(width: PlinkSpacing.s2),
            OutlinedButton(
              key: ValueKey('situation-dry-run-$key'),
              onPressed: controller.busy
                  ? null
                  : () => runWithProgress(
                        context,
                        controller: controller,
                        dry: true,
                        run: () => controller.dryRunDecisions(writable),
                      ),
              child: const Text('Dry-run alles'),
            ),
            const SizedBox(width: PlinkSpacing.s2),
            FilledButton(
              key: ValueKey('situation-apply-$key'),
              onPressed: controller.busy
                  ? null
                  : () => confirmAndApply(
                        context,
                        controller: controller,
                        title: 'Toepassen op ${writable.length} $noun?',
                        // The dialog is scoped to the very decisions the pass
                        // below runs — the ones this header counted
                        // (#234/#252), and only those (#292/#326).
                        scope: controller.applyScopeForDecisions(writable),
                        apply: (DateTime? deletionDate) =>
                            controller.applyDecisions(
                          writable,
                          deletionDate: deletionDate,
                        ),
                      ),
              child: Text('Alles toepassen (${writable.length})'),
            ),
          ],
        ],
      ),
    );
  }
}

/// The collapsed line one [PendingChoice] reads as: an either/or is marked
/// "(keuze)" on its pre-selected half, an informational action "(manueel)", and
/// an ordinary one is its bare summary.
///
/// Rendered through [ActionLine], which leads it with the system it writes to
/// (#298); the system is deliberately not spliced into the string here.
String pendingChoiceLine(PendingChoice c) {
  final summary = c.selected.changes.summary;
  if (c.isChoice) return '$summary (keuze)';
  return c.selected.canApply ? summary : '$summary (manueel)';
}

/// The collapsed line one of a decision's [PendingChoice.notices] reads as
/// (#329) — the instruction, marked "(manueel)" exactly as a standalone
/// informational action is.
///
/// A notice is context rather than a decision, so it is *not* one of
/// [pendingChoiceLine]'s cases: a preview lists both, the notice first and the
/// decision it explains under it. That order is the point of showing it here at
/// all — from an inventory row, "Negeer deze klas bij het importeren uit WISA"
/// on its own does not say why the class is in that state.
String pendingNoticeLine(PendingActionOption notice) =>
    '${notice.changes.summary} (manueel)';

/// The expandable card the Klasgroepen inventory builds a class with pending
/// work on. (Acties built one too until #295 moved its decisions into a details
/// pane of their own; the rule below is what made that move possible.)
///
/// It exists for one rule neither screen can hold on its own (#300). A
/// collapsed card previews its decisions as summary lines; since #281 the
/// expanded body *leads every decision with the very same sentence*, because
/// that heading is what tells the operator which diff belongs to which
/// decision. So on a card carrying one action the operator read it twice, one
/// line directly above the other:
///
/// > Werk het ledenbestand van SSM-1A bij (21 toevoegen, 17 verwijderen)
/// > **Werk het ledenbestand van SSM-1A bij (21 toevoegen, 17 verwijderen)**
///
/// The heading is the one that has to stay: it groups the block under it, it is
/// uniform across every decision (#281), and it is what the Acties details pane
/// — which has no collapsed row at all — reads [entryDetail] for since #295. So
/// the *preview* gives way instead. [subtitle] is therefore built with whether the
/// card is open, which is the one thing an [ExpansionTile] does not hand its
/// own subtitle.
class PendingCardTile extends StatefulWidget {
  const PendingCardTile({
    super.key,
    required this.tileKey,
    this.leading,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  /// Names the tile itself (`entry-group-<klas>`). Deliberately not this
  /// widget's own [key]: the screen's tests address the [ExpansionTile], and two
  /// widgets answering to one key would make `find.byKey` ambiguous.
  final Key tileKey;

  final Widget? leading;
  final Widget title;

  /// The collapsed body, told whether the card is open so it can drop what the
  /// expanded body now says. `null` renders no subtitle at all.
  final Widget? Function(BuildContext context, bool expanded) subtitle;

  final List<Widget> children;

  @override
  State<PendingCardTile> createState() => _PendingCardTileState();
}

class _PendingCardTileState extends State<PendingCardTile> {
  bool _expanded = false;

  @override
  void didUpdateWidget(PendingCardTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new [tileKey] builds a fresh [ExpansionTile], which starts collapsed.
    // Without this the two would drift apart — an open card recycled onto
    // another record would hide its preview while showing nothing instead.
    if (oldWidget.tileKey != widget.tileKey) _expanded = false;
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
        key: widget.tileKey,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: widget.leading,
        title: widget.title,
        subtitle: widget.subtitle(context, _expanded),
        onExpansionChanged: (bool expanded) =>
            setState(() => _expanded = expanded),
        childrenPadding: const EdgeInsets.fromLTRB(
          PlinkSpacing.s5,
          0,
          PlinkSpacing.s5,
          PlinkSpacing.s4,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: widget.children,
      );
}

// `PendingEntryTile` — the expandable Acties card that previewed its decisions
// collapsed and rendered [entryDetail] open — retired with the drill-down that
// listed it (#295). An Acties row is now a selectable line in a flat list and
// its decisions live in the details pane beside it, which is exactly the
// standing-on-its-own [entryDetail] #300 prepared. Klasgroepen still builds its
// own card from [PendingCardTile] + [entryDetail], because there a row *is* the
// class inventory and there is no second pane to put the detail in.

/// The expanded body of one pending entry: one block per decision, each with
/// its own verdict (#281/#283), then the verdicts of the last pass that no
/// decision on the card can claim (#272/#283), then the per-entry dry-run /
/// apply pair.
///
/// Split out of [PendingEntryTile] so the class inventory can put the very same
/// controls under a row that carries its own presence columns (#227), rather
/// than nesting one expandable tile inside another.
///
/// The blocks are keyed by position rather than by
/// [PendingChoice.situationId]: an entry groups every action on one target, and
/// two targets that share a display label share an entry, so a kind is not
/// guaranteed unique within one card — and a duplicate key among a [Column]'s
/// children is a build-time crash, not a cosmetic clash.
///
/// [onApplyToAll] is the school-wide apply-all seam (#296). Passed in rather
/// than reached for, because only Acties can honour it: pressing it filters
/// *that* screen's flat list down to the cohort so the operator can read it
/// before confirming, and a screen with no such list has no honest way to show
/// what the button would write. Klasgroepen therefore leaves it `null` and its
/// blocks carry no apply-all — its own per-cohort headers already sit above the
/// rows they cover.
List<Widget> entryDetail(
  BuildContext context, {
  required ReconcileController controller,
  required PendingAccountEntry entry,
  void Function(PendingDecision decision)? onApplyToAll,
}) =>
    <Widget>[
      for (final (index, choice) in entry.choices.indexed)
        EntryChoiceBlock(
          key:
              ValueKey('entry-choice-${entry.family}-${entry.targetId}-$index'),
          controller: controller,
          entry: entry,
          choice: choice,
          index: index,
          onApplyToAll: onApplyToAll,
        ),
      EntryOutcomes(
        keyValue: 'entry-outcomes-${entry.family}-${entry.targetId}',
        outcomes: controller.unroutedApplyOutcomesFor(entry),
        settled: true,
      ),
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
                      apply: (DateTime? deletionDate) => controller.applyEntry(
                        entry,
                        deletionDate: deletionDate,
                      ),
                    ),
            child: const Text('Toepassen'),
          ),
        ],
      ),
    ];

/// The heading one [PendingChoice] leads its block with (#281): the question an
/// either/or asks the operator, or — for a lone action — what that action does.
///
/// Deliberately the bare summary rather than the collapsed [pendingChoiceLine]:
/// the "(manueel)" marker exists to make an informational action scannable in a
/// list of many, while inside the block [OptionDetail] already spells the same
/// thing out in a full sentence.
///
/// **"Kies één oplossing:" is asked only about alternatives that both write**
/// (#329). It follows from [PendingChoice.isChoice] rather than being re-checked
/// here, because the collapse keeps an informational action out of the option
/// list altogether — it becomes [PendingChoice.notices] and is stated above this
/// heading instead. Before that, a card could ask the operator to choose between
/// "this class already exists in Smartschool, go make it official" and "never
/// import this class": one of those is not a solution, so the heading was
/// putting a question to them that had one real answer.
String choiceHeading(PendingChoice choice) =>
    choice.isChoice ? 'Kies één oplossing:' : choice.selected.changes.summary;

/// One decision of a card, as a block of its own (#281): whatever notices are
/// context for it (#329), the heading that names it, then the radios (for an
/// either/or) and the field diff of the resolution that would actually run —
/// and, since #283, what the last pass did about *this* decision.
///
/// The reading this exists for: a class that is new to Smartschool **and** has
/// no Office 365 group raises two independent decisions on one card. The body
/// used to render every choice's control and diff one after another with nothing
/// between them, under a subtitle that pooled both summaries at the top — so the
/// operator read the Office 365 field diff, then "Kies één oplossing:" with its
/// radios, then the Smartschool diff, and had no way to tell which diff belonged
/// to which decision, or that "pick one of these two" covered only half of what
/// was on the card. Under its own heading each diff belongs to something, and a
/// card with two decisions reads as two.
///
/// That heading is also why an open card drops its collapsed preview (#300):
/// the two say the same sentence, and on a card carrying one decision the
/// operator read it twice in a row. The heading is the half that stays — it
/// groups the block under it, and [entryDetail] has to stand on its own in the
/// Acties details pane (#295), where there is no collapsed row to have
/// previewed anything.
///
/// The verdict lines pooled the same way and for the same reason (#283): one
/// apply on that card produces two of them, and below both decisions they said
/// what happened without saying to which question. So the block carries the part
/// of the entry's verdict that answers its own decision, and the card keeps the
/// entry-level block for the rest — chiefly the decisions that *succeeded*, and
/// are therefore no longer on the card to be answered.
class EntryChoiceBlock extends StatelessWidget {
  const EntryChoiceBlock({
    super.key,
    required this.controller,
    required this.entry,
    required this.choice,
    required this.index,
    this.onApplyToAll,
  });

  final ReconcileController controller;
  final PendingAccountEntry entry;
  final PendingChoice choice;

  /// This decision's position on the card. The first needs no rule above it —
  /// the tile's own header already closes the body at the top — and it names
  /// the block's verdict, which is keyed by position for the reason
  /// [entryDetail] keys the blocks themselves that way.
  final int index;

  /// What the block's "Toepassen op alle (N)" hands back (#296), or `null` on a
  /// screen that offers no school-wide apply. See [entryDetail].
  final void Function(PendingDecision decision)? onApplyToAll;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (index > 0) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          const SizedBox(height: PlinkSpacing.s3),
        ],
        // Context before proposal (#329). A notice states what is *already* the
        // case — "this class exists in Smartschool but is not an official
        // class", "this WISA class has no students yet" — and the heading under
        // it says what this app proposes about that. Read the other way round
        // the proposal is a non sequitur, which is exactly how the radio pair
        // these used to be half of read.
        for (final notice in choice.notices)
          ChoiceNotice(
            key: ValueKey(
                'notice-${entry.family}-${entry.targetId}-$index-${notice.kind}'),
            notice: notice,
          ),
        // Led by the system it writes to, exactly as the collapsed preview is
        // (#298). Since #300 that preview gives way while the card is open, so
        // this heading is the only thing left saying where the write lands —
        // and a summary that names a group ("Werk het ledenbestand van GBS-1A
        // bij") does not say it.
        ActionLine(
          system: choice.selected.changes.system,
          line: choiceHeading(choice),
          style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: PlinkSpacing.s1),
        if (choice.isChoice)
          ChoiceControl(controller: controller, entry: entry, choice: choice)
        else
          OptionDetail(option: choice.selected),
        ..._applyToAll(context),
        EntryOutcomes(
          keyValue: 'entry-outcomes-${entry.family}-${entry.targetId}-$index',
          outcomes: controller.applyOutcomesForChoice(entry, choice),
        ),
      ],
    );
  }

  /// The block's school-wide affordance (#296), or nothing.
  ///
  /// Nothing in three cases, and they are different statements. The screen may
  /// offer no apply-all at all ([onApplyToAll] is `null`); the action may not be
  /// sanctioned for one (`canApplyToAll`, #293), which is the majority and
  /// includes every destructive action; or this account may be the only one in
  /// the school that needs the decision, where "op alle (1)" says nothing the
  /// **Toepassen** button below does not already say.
  List<Widget> _applyToAll(BuildContext context) {
    final onApplyToAll = this.onApplyToAll;
    if (onApplyToAll == null) return const <Widget>[];
    final decision = PendingDecision(entry: entry, choice: choice);
    final cohort = controller.applyToAllCohort(decision);
    if (cohort == null || cohort.length < 2) return const <Widget>[];

    return <Widget>[
      const SizedBox(height: PlinkSpacing.s2),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: ValueKey(
              'decision-apply-all-${entry.family}-${entry.targetId}-$index'),
          // Never disabled on the count — a cohort this short does not render
          // — but a pass already running owns the connectors.
          onPressed: controller.busy ? null : () => onApplyToAll(decision),
          icon: const Icon(Icons.done_all, size: 16),
          label: Text('Toepassen op alle (${cohort.length})'),
        ),
      ),
    ];
  }
}

/// What the last pass did, rendered on the card that raised the work and
/// nowhere else (#272) — since #283, one such block per decision, plus one at
/// card level for the verdicts no decision can claim.
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
/// [settled] marks the card-level block: those rows answer decisions that are
/// no longer on the card, which is the ordinary fate of a write that **landed**
/// — it settles its decision, so the next relink does not raise it again. They
/// are not leftovers and must not be dropped: the reported run has the
/// Smartschool half landing and the Office 365 half refused, and the operator
/// has to read both.
///
/// Renders nothing when there is nothing to report, which is the state of every
/// card after a sync.
class EntryOutcomes extends StatelessWidget {
  const EntryOutcomes({
    super.key,
    required this.keyValue,
    required this.outcomes,
    this.settled = false,
  });

  /// Names this block on screen — the card-level one keeps the
  /// `entry-outcomes-<family>-<targetId>` of #272, a decision's own appends its
  /// position.
  final String keyValue;

  /// The verdict rows this block reports, already routed by the controller.
  final List<ActionOutcomeEntry> outcomes;

  /// Whether these rows answer decisions the card no longer raises (#283),
  /// which changes both the heading and the sentence under it.
  final bool settled;

  @override
  Widget build(BuildContext context) {
    if (outcomes.isEmpty) return const SizedBox.shrink();

    final TextTheme text = Theme.of(context).textTheme;
    // A dry-run pass and an apply pass are never mixed: `_run` clears the other
    // list before it starts, so the whole block is one or the other.
    final bool dry =
        outcomes.every((o) => o.outcome == actions.ActionOutcome.dryRun);
    final String what = dry ? 'vorige dry-run' : 'vorige poging';

    return Padding(
      key: ValueKey(keyValue),
      padding: const EdgeInsets.only(top: PlinkSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Set off from the decisions above by the same rule that separates
          // them from each other, so the card reads as one section per block.
          if (settled) ...<Widget>[
            Divider(height: 1, color: Theme.of(context).dividerColor),
            const SizedBox(height: PlinkSpacing.s3),
          ],
          Text(
            // Deliberately not the page-level section's wording ("Resultaat van
            // het toepassen"): that one reports the pass, this one reports this
            // record, and an operator who sees both must be able to tell which
            // is which. "Vorige poging" also says the thing the operator needs
            // next — a failed write can simply be run again.
            settled
                ? 'Overige resultaten van de $what'
                : 'Resultaat van de $what',
            style: settled
                ? text.titleSmall
                : text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          // Why a verdict appears here with no decision above it to answer:
          // the write landed, so there is nothing left to pick.
          if (settled) ...<Widget>[
            const SizedBox(height: PlinkSpacing.s1),
            Text(
              'Deze acties staan niet meer open op deze kaart.',
              style: text.bodySmall,
            ),
          ],
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
///
/// An action that finished can still owe the operator that reason (#343). A
/// best-effort step may not fail the action around it — the Smartschool create
/// whose class placement blew up is applied, correctly — but a bare "gelukt"
/// for a write that half happened is the same trip to the log panel. So a row
/// with [ActionOutcomeEntry.warnings] is marked, and says what did not land
/// under what did.
class EntryOutcomeLine extends StatelessWidget {
  const EntryOutcomeLine({super.key, required this.outcome});

  final ActionOutcomeEntry outcome;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool failed = outcome.outcome == actions.ActionOutcome.failed;
    final List<String> warnings = outcome.warnings;
    final bool warned = !failed && warnings.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            switch ((failed, warned)) {
              (true, _) => Icons.close,
              (false, true) => Icons.warning_amber_outlined,
              (false, false) => Icons.check,
            },
            size: 16,
            color: failed || warned ? colors.error : colors.primary,
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  failed
                      ? 'Mislukt — ${outcome.changes.summary}: ${outcome.error}'
                      : outcome.changes.summary,
                  style: text.bodySmall?.copyWith(
                    color: failed ? colors.error : null,
                  ),
                ),
                // The write landed; this is the part of it that did not.
                for (final warning in warnings)
                  Text(
                    warning,
                    style: text.bodySmall?.copyWith(color: colors.error),
                  ),
              ],
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
///
/// The "Kies één oplossing:" heading above it belongs to the enclosing
/// [EntryChoiceBlock] since #281, so that every decision on a card — either/or
/// or lone action — is introduced by one and the same rule.
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

/// How one [actions.FieldChange] reads on a card.
///
/// Three shapes, because a `ChangeSet` describes three kinds of thing (#300,
/// #305). A **transition** is a value moving, and reads as one:
/// `mail: ∅ → 1a@…`. A **count** is a quantity the action acts on, and reads as
/// the number it is: `leden toevoegen: 21`. A **statement** is a fact about the
/// record an informational notice is describing, and reads as that fact:
/// `mail: GBS-9Z@…`.
///
/// Put through the transition template, the two of them that are not
/// transitions each claimed something untrue: a count, that the field used to
/// be empty and is becoming 21; a statement, that the value it names is being
/// cleared — on a notice whose whole point is that nothing is written.
String fieldChangeLine(actions.FieldChange f) => switch (f.shape) {
      actions.FieldChangeShape.count => '${f.field}: ${f.after}',
      actions.FieldChangeShape.statement => '${f.field}: ${f.before}',
      actions.FieldChangeShape.transition =>
        '${f.field}: ${f.before ?? '∅'} → ${f.after ?? '∅'}',
    };

/// One informational action a decision carries as **context** (#329): the
/// instruction, marked "(manueel)", with the facts it states about the record
/// under it — and no radio, no apply, nothing to choose.
///
/// The rule it enforces: *a notice is context, not an alternative.* Two
/// decisions used to pair one of these with the single write the app has for
/// the situation and offer them as radios — "make this group official in
/// Smartschool" beside "never import this class", "delete this empty WISA class
/// by hand" beside the same. Only one of each pair is something an apply can
/// run; the other is an instruction to go elsewhere, and an operator cannot
/// "apply" it. So the card states it and proposes the write, rather than asking
/// a question whose two answers are not comparable.
///
/// Deliberately not [OptionDetail] with the radio suppressed. That widget
/// renders *the resolution that would run*: its lifecycle fallback says
/// "Levenscyclusactie — geen wijzigingen per veld", and its "(manueel)"
/// sentence appears only when an informational option has no fields at all — so
/// a notice with fields (the namesake one names the group's code and its
/// official flag) would have rendered as a bare field list with nothing marking
/// it as write-free. Here the marker is on the sentence, always.
class ChoiceNotice extends StatelessWidget {
  const ChoiceNotice({super.key, required this.notice});

  /// The informational option this states — [PendingChoice.notices]' member.
  final PendingActionOption notice;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Led by the system the operator has to go and act in — the same tag
          // every other line on the card carries (#298), and here it is the
          // more useful half: the instruction is "do this over there".
          ActionLine(
            system: notice.changes.system,
            line: pendingNoticeLine(notice),
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          // How the operator finds the thing the instruction is about. Stated,
          // never diffed — these are the notice's own `FieldChange`s and
          // [fieldChangeLine] already keeps a statement from reading as a
          // value being cleared (#305).
          for (final f in notice.changes.fields)
            Padding(
              padding: const EdgeInsets.only(top: PlinkSpacing.s1),
              child: Text(
                fieldChangeLine(f),
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
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
                  child: Text(fieldChangeLine(f), style: text.bodySmall),
                ),
            ],
    );
  }
}
