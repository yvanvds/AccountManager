/// The shared **system vocabulary** the two action screens speak (#298): what a
/// WISA / Smartschool / Office 365 cell means, and how one action line names the
/// system it writes to.
///
/// ## What a coloured cell means
///
/// A cell used to answer *does this record exist in system X* and nothing else,
/// so class `1A` — present in all three systems and carrying a pending Office
/// 365 roster write — read as three ticks. The ticks were not wrong; they
/// answered a different question than the one the operator asks when they look
/// at the row. Since #298 a cell shows the **worst** of two axes for that one
/// system:
///
/// - [SystemIndicatorState.missing] (red) — the record is not there at all;
/// - [SystemIndicatorState.needsWork] (orange) — it is there, and this screen
///   has work pending against that system;
/// - [SystemIndicatorState.inOrder] (green) — it is there and nothing is due.
///
/// Missing wins over pending work: a record that does not exist is the bigger
/// fact, and the work is usually the creation of it.
///
/// ## The reconciling principle: colour by work that can be done *on this
/// screen*
///
/// The two screens look like they disagree, and they do not. Klasgroepen keys
/// its row **highlight** on `MaterializedGroup.needsAttention`, informational
/// notices included (#327/#328), because there the manual notice *is* the work
/// the operator does on that screen — a leftover class or group this app cannot
/// address a delete to is answered right there. In Acties an informational
/// candidate is a diagnosis of work that happens somewhere else, so it colours
/// nothing.
///
/// A notice attached to a decision (#329) does not enter into this at all: it
/// is context, and the decision beside it is what the cell answers for. A
/// namesake or empty class therefore colours its **WISA** cell, because "negeer
/// deze klas" is a live decision about the WISA side of that class — the same
/// consequence #327/#328 had on the other two systems when their no-op halves
/// went.
///
/// Both are the same rule: **a coloured cell means work you can do here.** The
/// next reader will otherwise see two rules and assume one is a bug.
///
/// The concrete case is `AzureClassGroupMembership`, the student family's only
/// informational member. Office 365 class membership is a property of the
/// *group*, so the write is `SyncAzureClassGroupMembers` on Klasgroepen — one
/// per class rather than one per student. If it coloured a student's Office 365
/// cell, the September rollover would paint ~3000 accounts orange for work the
/// Acties screen structurally cannot do. It stays visible in the details pane
/// as context, marked "(manueel)".
///
/// (#290 proposed the opposite — making that action applyable per student. It
/// was closed on 2026-08-22 and the action still declares `canApply => false`,
/// so this file's reading is the one in force.)
///
/// The predicate is not new. `hasPending`, `pendingDecisionCount` and the tile
/// badge have counted informational candidates as zero since #245/#255; the
/// indicators simply apply that same predicate.
library;

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart'
    show CandidateAction, candidateChoices;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_controller.dart';

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

/// What one system cell says about one record, worst first (#298).
enum SystemIndicatorState {
  /// The record does not exist in that system — red.
  missing,

  /// It exists there, and this screen has applyable work pending against it —
  /// orange.
  needsWork,

  /// It exists there and nothing is due — green.
  inOrder,
}

/// Derives a cell's reading from the two axes (#298): presence, and whether the
/// pending work of this record lands in that system.
///
/// [hasWork] must already have been narrowed to **applyable** work — see
/// [workSystemsOfEntry] and [workSystemsOfCandidates], which are the only two
/// ways this app computes it. An informational candidate is not work this
/// screen can do, so it never reaches here.
SystemIndicatorState systemIndicatorState({
  required bool present,
  required bool hasWork,
}) {
  if (!present) return SystemIndicatorState.missing;
  return hasWork
      ? SystemIndicatorState.needsWork
      : SystemIndicatorState.inOrder;
}

/// The systems the applyable pending work of one **live** entry writes to.
///
/// One per decision, read off the alternative the operator has actually
/// selected — the same resolution an apply pass would run, so the cell cannot
/// promise a write the button would not make. A decision whose selected half is
/// informational contributes nothing.
///
/// `Origin.wisa` can appear: the `DontImportFromWisa` family's `ChangeSet`
/// carries it although the connector is read-only and the apply lands as a
/// shared import rule (#276). That is deliberate — a WISA cell says *there is a
/// decision about the WISA side of this record*, not *the app will write to
/// WISA*, and the confirmation dialog is where the difference is spelled out.
Set<core.Origin> workSystemsOfEntry(PendingAccountEntry entry) => <core.Origin>{
      for (final choice in entry.choices)
        if (choice.selected.canApply) choice.selected.changes.system,
    };

/// The same reading off the **stored** candidates, which is all a passive
/// session has (#214/#255). Collapsed through [candidateChoices] first, so an
/// either/or is judged on its pre-selected half exactly as the live path is.
Set<core.Origin> workSystemsOfCandidates(
  Iterable<CandidateAction> candidates,
) =>
    <core.Origin>{
      for (final choice in candidateChoices(candidates))
        if (choice.selected.canApply) choice.selected.system,
    };

/// The icon a state reads as. Deliberately distinct shapes as well as colours,
/// so the three states survive a monochrome screenshot and a colour-blind
/// operator.
IconData systemIndicatorIcon(SystemIndicatorState state) => switch (state) {
      SystemIndicatorState.inOrder => Icons.check_circle_outline,
      SystemIndicatorState.needsWork => Icons.pending_outlined,
      SystemIndicatorState.missing => Icons.remove_circle_outline,
    };

/// The colour a state reads as, per theme.
///
/// Named here rather than taken from the [ColorScheme] because the Plink
/// palette has no health colours to borrow: `primary` is the magenta **spark**,
/// reserved for the one primary action on a page, and a wall of magenta ticks
/// would both drown the spark and say "look here" about the rows that need
/// nothing. Green / orange / red is the vocabulary #291 and #295 settled on.
Color systemIndicatorColor(BuildContext context, SystemIndicatorState state) {
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  return switch (state) {
    SystemIndicatorState.inOrder =>
      dark ? const Color(0xFF5FB89A) : const Color(0xFF1F7A5A),
    SystemIndicatorState.needsWork =>
      dark ? const Color(0xFFE0A458) : const Color(0xFF9A5B00),
    SystemIndicatorState.missing =>
      dark ? const Color(0xFFE57373) : Theme.of(context).colorScheme.error,
  };
}

/// The one-line Dutch reading of a cell, for its tooltip and its semantics.
String systemIndicatorTooltip(core.Origin system, SystemIndicatorState state) =>
    switch (state) {
      SystemIndicatorState.inOrder => '${systemLabel(system)} staat in orde',
      SystemIndicatorState.needsWork =>
        '${systemLabel(system)} heeft werk openstaan',
      SystemIndicatorState.missing => 'Bestaat niet in ${systemLabel(system)}',
    };

/// One system cell of a row: the icon in its state's colour, the system's Dutch
/// name, and optionally the thing that is (or is not) there.
///
/// Shared so Klasgroepen's inventory rows and the flat Acties list (#295) mean
/// the same thing by a coloured cell — the point of #298. Callers give it a
/// [key] — `class-cell-<klas>-<systeem>`, `account-cell-<id>-<systeem>` — so a
/// test can address one cell of one row.
class SystemIndicatorCell extends StatelessWidget {
  const SystemIndicatorCell({
    super.key,
    required this.system,
    required this.state,
    this.detail,
    this.note,
  });

  /// Which system this cell answers for.
  final core.Origin system;

  /// What it answers.
  final SystemIndicatorState state;

  /// The name of the thing that is (or is not) there — the Office 365 group.
  final String? detail;

  /// A second line that explains the row's relationship to [detail].
  final String? note;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color muted = Theme.of(context).disabledColor;

    return Padding(
      padding: const EdgeInsets.only(right: PlinkSpacing.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The `container: true` is load-bearing, not decoration (#350).
          //
          // A `Tooltip` is an `OverlayPortal`, and the overlay half is joined to
          // its anchor by a traversal-parent identifier rather than by position
          // in the tree. That identifier is dropped when the anchor's
          // `SemanticsConfiguration` is absorbed into a neighbour's — the
          // upstream defect flutter/flutter#182444, diagnosed in
          // flutter/flutter#190344, still open as of Flutter 3.44.0. The orphan
          // node is then serialized as a child nobody can reach, and on Windows
          // `ui::AXTree::Unserialize` rejects the entire update:
          // `N will not be in the tree and is not the new root`. The
          // accessibility tree freezes for the life of the window, and the
          // process has been seen to die outright with no Dart exception.
          //
          // Three of these cells sit side by side in a row of a `ListView`,
          // whose viewport describes itself with two-pane semantics — precisely
          // the recipe upstream reproduces. Asking for a container gives the
          // anchor a semantics node of its own, so there is nothing left to
          // absorb it and the identifier survives. `excludeFromSemantics` does
          // not help: it only suppresses the anchor's tooltip string, while the
          // grafting that breaks is the portal's.
          //
          // system_indicator_semantics_test.dart holds this down by replaying
          // the real update traffic through the engine's reachability rule.
          // Drop the container and it records ~90 rejected updates.
          Semantics(
            container: true,
            child: Tooltip(
              message: systemIndicatorTooltip(system, state),
              child: Icon(
                systemIndicatorIcon(state),
                size: 16,
                color: systemIndicatorColor(context, state),
              ),
            ),
          ),
          const SizedBox(width: PlinkSpacing.s1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  systemLabel(system),
                  style: text.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (detail != null)
                  Text(
                    detail!,
                    style: text.bodySmall?.copyWith(color: muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (note != null)
                  Text(
                    note!,
                    style: text.bodySmall?.copyWith(color: muted),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One collapsed action line, led by the system it writes to (#298).
///
/// One card can raise work in two systems — a class new to Smartschool that also
/// lacks its Office 365 group — and the summaries do not always say where they
/// land ("Werk het ledenbestand van GBS-1A bij" names a group, not a system).
/// With the system in front, a row's lines and its cells tell the same story.
///
/// The tag is a [Text] of its own rather than a prefix spliced into [line], so
/// the summary stays one addressable string: the whole app — the confirmation
/// dialog, the outcome rows, the details pane — quotes an action by its
/// summary, and a decorated copy on one screen would no longer match it.
class ActionLine extends StatelessWidget {
  const ActionLine({
    super.key,
    required this.system,
    required this.line,
    this.style,
  });

  /// The system the action writes to — `ChangeSet.system` / `CandidateAction
  /// .system`.
  final core.Origin system;

  /// The line as the screens word it (`pendingChoiceLine` /
  /// `readOnlyCandidateLine`), untouched.
  final String line;

  /// The body style; defaults to `bodySmall`. A passive session passes the
  /// disabled colour so an inert card still reads as inert (#214).
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final TextStyle? base = style ?? Theme.of(context).textTheme.bodySmall;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${systemLabel(system)} ·',
          style: base?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: PlinkSpacing.s1),
        Expanded(child: Text(line, style: base)),
      ],
    );
  }
}
