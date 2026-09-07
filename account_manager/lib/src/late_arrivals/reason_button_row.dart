/// The flat row of reason buttons the operator confirms a late arrival with
/// (#407, over the shared list #405 keeps).
///
/// **One flat row, no grouping and no second click.** The epic settled this:
/// "zonder geldige reden" is a different Presence call underneath, but to the
/// person at the desk it is just another button. Asking for an extra tap to
/// classify the reason would slow down precisely the moment that has to be fast
/// — a queue of students waiting at reception — so the flag rides on the reason
/// and the row stays flat.
///
/// **Order is the shared list's order.** `normalizeLateArrivalReasons` preserves
/// it deliberately so the reasons an operator reaches for most can be put first
/// in Instellingen; this renders it verbatim and never re-sorts, never regroups
/// the invalid entries to the end.
///
/// **The invalid entries are still legible as such.** They are pressed in the
/// same sweep as the others, but pressing one records an unexcused absence, and
/// an operator must be able to see which is which without reading a manual. They
/// wear the same [PlinkBadge] with [BadgeVariant.spark] that badges them in the
/// Instellingen list, so the two surfaces mark the same fact the same way, and
/// they are outlined rather than filled so the row separates at a glance from
/// across the desk.
library;

import 'package:flutter/material.dart';
import 'package:late_arrivals/late_arrivals.dart';
import 'package:plink_design_system/plink_design_system.dart';

/// How wide and how tall a reason button is, at minimum.
///
/// Deliberately large. This is a mouse (or a finger on a touch monitor) moving
/// between a scanner and a screen while somebody is standing at the desk: a
/// mis-hit costs a wrong motivation on a student's record, and a target that has
/// to be aimed at costs seconds on every single arrival.
const Size lateArrivalReasonButtonSize = Size(196, 68);

/// The reason buttons, in the shared list's order.
class LateArrivalReasonButtons extends StatelessWidget {
  const LateArrivalReasonButtons({
    super.key,
    required this.reasons,
    required this.onPick,
    this.enabled = true,
  });

  /// The shared list, exactly as `AppSettings.lateArrivalReasons` holds it.
  final List<LateArrivalReason> reasons;

  /// Called with the reason the operator pressed.
  final void Function(LateArrivalReason reason) onPick;

  /// Whether a reason can be pressed at all.
  ///
  /// `false` with no student on screen, and while a confirmation is being
  /// written: a disabled row says "there is nothing to confirm" without the
  /// buttons disappearing and the layout jumping under the operator's hand
  /// between one student and the next.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: PlinkSpacing.s3,
      runSpacing: PlinkSpacing.s3,
      children: <Widget>[
        for (int i = 0; i < reasons.length; i++)
          _ReasonButton(
            key: ValueKey<String>('late-reason-$i'),
            reason: reasons[i],
            onPick: enabled ? () => onPick(reasons[i]) : null,
          ),
      ],
    );
  }
}

class _ReasonButton extends StatelessWidget {
  const _ReasonButton({super.key, required this.reason, required this.onPick});

  final LateArrivalReason reason;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Widget label = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          reason.label,
          textAlign: TextAlign.center,
          style: text.titleMedium,
        ),
        if (!reason.isValid) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          const PlinkBadge(
            'zonder geldige reden',
            variant: BadgeVariant.spark,
          ),
        ],
      ],
    );

    const ButtonStyle style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(lateArrivalReasonButtonSize),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(
          horizontal: PlinkSpacing.s4,
          vertical: PlinkSpacing.s3,
        ),
      ),
    );

    return reason.isValid
        ? FilledButton(onPressed: onPick, style: style, child: label)
        : OutlinedButton(onPressed: onPick, style: style, child: label);
  }
}
