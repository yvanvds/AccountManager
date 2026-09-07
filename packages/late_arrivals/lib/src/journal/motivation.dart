/// The separator between the arrival time and the reason: an en dash with a
/// space either side, exactly as the epic pins the format (#399).
const String motivationSeparator = ' – ';

/// Composes the motivation text a presence write carries: `HH:mm – reden`.
///
/// Smartschool's Presence module only knows am/pm half-days, so the exact
/// arrival time can only travel as free text. The format is fixed — including
/// for "zonder geldige reden", where it would be tempting to write only the
/// reason — so the field stays parseable if late arrivals are ever reported on
/// (#399).
///
/// [scannedAt] is read in its own zone: the operator's wall clock is what the
/// student is told, and converting to UTC first would put the wrong hour on the
/// ticket.
String composeMotivation(DateTime scannedAt, String reasonLabel) {
  final String hour = scannedAt.hour.toString().padLeft(2, '0');
  final String minute = scannedAt.minute.toString().padLeft(2, '0');
  final String reason = reasonLabel.trim();
  return reason.isEmpty
      ? '$hour:$minute'
      : '$hour:$minute$motivationSeparator$reason';
}
