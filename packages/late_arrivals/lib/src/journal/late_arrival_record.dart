import 'school_day.dart';

/// How far one late-arrival registration has got towards Smartschool (#402).
///
/// The journal records every transition durably, so a restart knows the
/// difference between "never sent" and "sent, answer unknown" — which are two
/// very different things to do next.
enum LateArrivalStatus {
  /// Written to disk, not yet handed to Smartschool. What every registration
  /// starts as, and what the drain worker (#404) picks up.
  pending('pending'),

  /// Handed to Smartschool; no confirmation seen yet. A record found in this
  /// state after a crash is the ambiguous one: the write may or may not have
  /// landed. It is re-drained, which is safe — a presence save *updates* the
  /// half-day cell rather than appending a row (#399).
  sent('sent'),

  /// Smartschool acknowledged the presence write. Terminal.
  confirmed('confirmed'),

  /// The registration was given up on, with a reason. Terminal — a *transient*
  /// failure does not come here, it goes back to [pending] for another attempt.
  failed('failed');

  const LateArrivalStatus(this.wireName);

  /// The token stored in the journal. Pinned apart from the Dart name so
  /// renaming the enum cannot silently orphan yesterday's file.
  final String wireName;

  static LateArrivalStatus? tryParse(String? raw) {
    for (final LateArrivalStatus status in values) {
      if (status.wireName == raw) return status;
    }
    return null;
  }

  /// Whether nothing more will happen to a record in this state.
  bool get isTerminal =>
      this == LateArrivalStatus.confirmed || this == LateArrivalStatus.failed;

  /// Whether the drain worker still owes this record an attempt.
  bool get needsDraining => !isTerminal;

  /// Whether [next] is a transition the drain worker is allowed to record.
  ///
  /// Out of a terminal state, nothing is: a confirmed presence cannot un-happen
  /// and a given-up registration is a decision, not a state to walk out of. The
  /// requeue [sent] → [pending] *is* allowed, because that is what a transient
  /// send failure looks like.
  bool canTransitionTo(LateArrivalStatus next) {
    if (isTerminal) return false;
    return next != this;
  }
}

/// One late arrival, exactly as it was appended to the journal (#402).
///
/// Self-contained by design: everything a drain (#404), a Cosmos mirror (#403)
/// or a support question needs is on the record, so replaying the journal never
/// has to re-resolve a scan against a snapshot that has since moved on.
final class LateArrivalRecord implements Comparable<LateArrivalRecord> {
  const LateArrivalRecord({
    required this.id,
    required this.day,
    required this.sequence,
    required this.scannedAt,
    required this.smartschoolUid,
    required this.wisaId,
    required this.displayName,
    required this.className,
    required this.internalUserId,
    required this.classGroupId,
    required this.reasonLabel,
    required this.reasonIsValid,
    required this.motivation,
    required this.status,
    this.personId,
    this.error,
  });

  /// Unique within the journal: `<day>-<sequence>`, e.g. `2026-09-07-0003`.
  ///
  /// Derived rather than random so a record keeps the same identity when the
  /// file is replayed, and so the Cosmos mirror (#403) has a stable key. Reusing
  /// a sequence after a crash is safe *because* of the durability ordering: a
  /// registration whose line never reached disk never printed a ticket either,
  /// so there is no ghost for the reused number to collide with.
  final String id;

  /// The school day this registration is filed under — [scannedAt]'s local day.
  final SchoolDay day;

  /// Position within [day], starting at 1. The per-student ordering key, and
  /// the reason ordering survives a reload: a later scan of the same student
  /// carries a higher sequence and must therefore drain later, because a
  /// presence save is last-write-wins on the half-day cell (#399).
  final int sequence;

  /// The moment the card was scanned — **not** the moment the line was written.
  /// The two differ by the write, and it is the scan the ticket and the
  /// motivation quote.
  final DateTime scannedAt;

  /// The student's Smartschool username: the always-present student key, and
  /// what ordering is grouped by.
  final String smartschoolUid;

  /// The WISA id the card encodes, verbatim.
  final String wisaId;

  /// The linker's person id when the session had one; `null` otherwise (#401).
  final String? personId;

  /// Name and class as the operator saw them at the desk, frozen at scan time.
  final String displayName;
  final String className;

  /// The two identifiers the Presence write is addressed with (#138, #400).
  final int internalUserId;
  final int classGroupId;

  /// The reason the operator picked, as its label.
  ///
  /// Stored as a label plus [reasonIsValid] rather than as a reference into the
  /// shared reason list (#405): the list is editable, and a registration must
  /// still say what was chosen after somebody renames or removes the entry.
  final String reasonLabel;

  /// Whether the chosen reason counts as a valid ("geldige") one. The invalid
  /// case is a different call under the hood, so the drain needs the flag, and
  /// the operator experience is one flat row of buttons either way (#399).
  final bool reasonIsValid;

  /// The free-text field the presence write carries: `HH:mm – reden`. Smartschool
  /// only knows am/pm half-days, so this is the only place the exact arrival
  /// time can live (#399).
  final String motivation;

  final LateArrivalStatus status;

  /// Why the registration was given up on. Only ever set alongside
  /// [LateArrivalStatus.failed].
  final String? error;

  /// The same record in [next], for the in-memory view after a status line is
  /// appended.
  LateArrivalRecord withStatus(LateArrivalStatus next, {String? error}) =>
      LateArrivalRecord(
        id: id,
        day: day,
        sequence: sequence,
        scannedAt: scannedAt,
        smartschoolUid: smartschoolUid,
        wisaId: wisaId,
        personId: personId,
        displayName: displayName,
        className: className,
        internalUserId: internalUserId,
        classGroupId: classGroupId,
        reasonLabel: reasonLabel,
        reasonIsValid: reasonIsValid,
        motivation: motivation,
        status: next,
        error: next == LateArrivalStatus.failed ? error : null,
      );

  /// Drain order: by day, then by position within the day. Grouped per student
  /// this is exactly the order the scans happened in.
  @override
  int compareTo(LateArrivalRecord other) {
    final int byDay = day.compareTo(other.day);
    return byDay != 0 ? byDay : sequence.compareTo(other.sequence);
  }

  /// The registration line's payload, without the `kind` discriminator the
  /// journal adds.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'day': day.id,
        'seq': sequence,
        'scannedAt': scannedAt.toIso8601String(),
        'uid': smartschoolUid,
        'wisaId': wisaId,
        if (personId != null) 'personId': personId,
        'name': displayName,
        'className': className,
        'userId': internalUserId,
        'groupId': classGroupId,
        'reason': reasonLabel,
        'reasonValid': reasonIsValid,
        'motivation': motivation,
        'status': status.wireName,
        if (error != null) 'error': error,
      };

  /// Reads a registration line back. `null` — never an exception — when a field
  /// is missing or of the wrong type, so one damaged line costs one record and
  /// not the file.
  static LateArrivalRecord? tryFromJson(Map<String, Object?> json) {
    final Object? id = json['id'];
    final Object? day = json['day'];
    final Object? sequence = json['seq'];
    final Object? scannedAt = json['scannedAt'];
    final Object? uid = json['uid'];
    final Object? userId = json['userId'];
    final Object? groupId = json['groupId'];
    if (id is! String || id.isEmpty) return null;
    if (day is! String || sequence is! int) return null;
    if (scannedAt is! String || uid is! String || uid.isEmpty) return null;
    if (userId is! int || groupId is! int) return null;

    final SchoolDay? parsedDay = SchoolDay.tryParse(day);
    final DateTime? parsedScan = DateTime.tryParse(scannedAt);
    final LateArrivalStatus? parsedStatus =
        LateArrivalStatus.tryParse(json['status'] as String?);
    if (parsedDay == null || parsedScan == null || parsedStatus == null) {
      return null;
    }

    return LateArrivalRecord(
      id: id,
      day: parsedDay,
      sequence: sequence,
      scannedAt: parsedScan,
      smartschoolUid: uid,
      wisaId: json['wisaId'] is String ? json['wisaId']! as String : '',
      personId: json['personId'] is String ? json['personId']! as String : null,
      displayName: json['name'] is String ? json['name']! as String : uid,
      className:
          json['className'] is String ? json['className']! as String : '',
      internalUserId: userId,
      classGroupId: groupId,
      reasonLabel: json['reason'] is String ? json['reason']! as String : '',
      reasonIsValid: json['reasonValid'] == true,
      motivation:
          json['motivation'] is String ? json['motivation']! as String : '',
      status: parsedStatus,
      error: json['error'] is String ? json['error']! as String : null,
    );
  }

  @override
  String toString() => 'LateArrivalRecord($id, $displayName, $className, '
      '${status.wireName})';
}
