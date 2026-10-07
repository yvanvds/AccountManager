import 'dart:convert';

import '../scan_result.dart';
import 'journal_store.dart';
import 'late_arrival_record.dart';
import 'motivation.dart';
import 'record_sink.dart';
import 'school_day.dart';

/// The append-only, per-day log of late-arrival registrations (#402).
///
/// **Why it exists.** Between the scan and a successful Smartschool write, this
/// app holds the only record of who arrived late. The write has to be deferred
/// to a background drain (#404) — a slow or expired Smartschool session must
/// never stall a desk with a queue of students in front of it — and a deferred
/// queue that lives only in memory loses everybody when the app dies. Appending
/// one line costs well under a millisecond, which is what makes the guarantee
/// affordable in the hot path.
///
/// **The durability ordering is the whole point.** [register] completes only
/// once the line is flushed to disk, and the caller prints the ticket only
/// after. A student who walked off with a ticket is therefore always on disk.
/// The reverse — a line on disk whose ticket never printed — is the harmless
/// direction and is what the app is deliberately biased towards.
///
/// **Append-only, folded on read.** A registration is one self-contained line;
/// every later status change is another, smaller line naming the same [id]. The
/// file is never rewritten in place, so a crash can only ever damage the tail,
/// and [open] discards a torn trailing line rather than the day.
///
/// ```dart
/// final journal = await LateArrivalJournal.open(store);
/// for (final record in journal.pending) {
///   // hand to the drain worker (#404), in this order
/// }
///
/// final record = await journal.register(
///   scan: scanResult,           // a ScanRegisterable from ScanResolver (#401)
///   scannedAt: DateTime.now(),
///   reasonLabel: 'Bus te laat',
///   reasonIsValid: true,
/// );
/// // ...only now print the ticket and free the input.
/// ```
///
/// Pure Dart: the file lives behind [JournalStore], which `account_manager/`
/// binds to `%APPDATA%`.
class LateArrivalJournal {
  LateArrivalJournal._(this._store, this._sink, this._recovery, this._records)
      : _sequenceByDay = <SchoolDay, int>{} {
    for (final LateArrivalRecord record in _records) {
      _byId[record.id] = record;
      final int held = _sequenceByDay[record.day] ?? 0;
      if (record.sequence > held) _sequenceByDay[record.day] = record.sequence;
    }
  }

  /// How long a fully drained day is kept before its file is rolled off.
  ///
  /// Long enough that "what happened last week" is still answerable from the
  /// desk, short enough that the directory does not grow without bound. A day
  /// that still holds an undrained record is **never** rolled off, however old
  /// it is: a student who never reached Smartschool is exactly what this file
  /// exists to not lose.
  static const Duration defaultRetention = Duration(days: 30);

  /// Opens the journal, replays every retained day, and rolls off the days that
  /// are past [retention] and fully drained.
  ///
  /// [now] is the clock the retention window is measured against; it defaults to
  /// the real one. Never throws on a damaged file — see [recovery] for what was
  /// discarded.
  ///
  /// [sink] is told about every registration and every status change *after* it
  /// is on disk — the seam the Cosmos mirror (#403) hangs off. It is optional
  /// and it is `void`: with no sink the journal behaves exactly as it did
  /// before one existed, and with one it still does, because a sink can neither
  /// be awaited nor fail back into the hot path.
  static Future<LateArrivalJournal> open(
    JournalStore store, {
    DateTime? now,
    Duration retention = defaultRetention,
    LateArrivalRecordSink? sink,
  }) async {
    final SchoolDay today = SchoolDay.of(now ?? DateTime.now());
    final int retentionDays = retention.inDays;

    final List<SchoolDay> days = await store.days();
    final List<LateArrivalRecord> records = <LateArrivalRecord>[];
    final List<SchoolDay> kept = <SchoolDay>[];
    final List<SchoolDay> rolledOff = <SchoolDay>[];
    int truncatedTails = 0;
    int damagedLines = 0;
    int orphanStatusLines = 0;

    for (final SchoolDay day in days) {
      final _DayReplay replay = _replay(await store.read(day));
      truncatedTails += replay.truncatedTail ? 1 : 0;
      damagedLines += replay.damagedLines;
      orphanStatusLines += replay.orphanStatusLines;

      final bool drained =
          replay.records.every((LateArrivalRecord r) => r.status.isTerminal);
      if (drained && day.daysBefore(today) > retentionDays) {
        await store.delete(day);
        rolledOff.add(day);
        continue;
      }
      kept.add(day);
      records.addAll(replay.records);
    }

    records.sort();
    return LateArrivalJournal._(
      store,
      sink,
      JournalRecovery(
        days: List<SchoolDay>.unmodifiable(kept),
        rolledOff: List<SchoolDay>.unmodifiable(rolledOff),
        recordCount: records.length,
        pendingCount: records
            .where((LateArrivalRecord r) => r.status.needsDraining)
            .length,
        truncatedTails: truncatedTails,
        damagedLines: damagedLines,
        orphanStatusLines: orphanStatusLines,
      ),
      records,
    );
  }

  final JournalStore _store;

  /// Told about every durable change, after the fact and without being awaited.
  /// `null` on a machine with no shared store configured.
  final LateArrivalRecordSink? _sink;

  final JournalRecovery _recovery;

  /// Every retained record, kept in drain order — by day, then by position
  /// within the day.
  final List<LateArrivalRecord> _records;
  final Map<String, LateArrivalRecord> _byId = <String, LateArrivalRecord>{};
  final Map<SchoolDay, int> _sequenceByDay;

  /// What [open] found and what it had to discard.
  JournalRecovery get recovery => _recovery;

  /// Every retained registration, in drain order.
  List<LateArrivalRecord> get records => List<LateArrivalRecord>.unmodifiable(
        _records,
      );

  /// The registrations the drain worker still owes an attempt, in drain order.
  ///
  /// Ordering is the contract, not a convenience: a presence save *updates* the
  /// half-day cell rather than appending a row, so a student scanned twice must
  /// have the later scan applied last or the desk's correction is silently
  /// undone (#399).
  List<LateArrivalRecord> get pending => List<LateArrivalRecord>.unmodifiable(
        _records.where((LateArrivalRecord r) => r.status.needsDraining),
      );

  /// Everything registered for one student, oldest scan first.
  List<LateArrivalRecord> recordsOf(String smartschoolUid) =>
      List<LateArrivalRecord>.unmodifiable(
        _records.where(
          (LateArrivalRecord r) => r.smartschoolUid == smartschoolUid,
        ),
      );

  LateArrivalRecord? byId(String id) => _byId[id];

  /// The given-up registrations the operator still has to deal with, in drain
  /// order: every [LateArrivalStatus.failed] record that is not
  /// [supersededBy] a later scan (#460).
  ///
  /// This is the desk's *mislukt* list, and exactly what **Opnieuw proberen**
  /// requeues ([requeueFailures]). A superseded failure is left out of both:
  /// a presence save overwrites the half-day cell, so a later scan of the same
  /// student for the same half-day decides what Smartschool holds, whatever
  /// became of the earlier one — and sending the earlier one again could only
  /// undo it.
  List<LateArrivalRecord> get failures => List<LateArrivalRecord>.unmodifiable(
        _records.where(
          (LateArrivalRecord r) =>
              r.status == LateArrivalStatus.failed && supersededBy(r) == null,
        ),
      );

  /// The later registration of the same student, for the same day and
  /// half-day, that makes [record] moot — or `null` when there is none.
  ///
  /// "Later" is drain order, which is scan order, whatever the later record's
  /// status: confirmed, it already stands in Smartschool; still queued, it
  /// will be written after anything requeued now; failed or handled by hand,
  /// it is the one the operator deals with. In every case the earlier scan is
  /// not worth sending (#399, #460).
  LateArrivalRecord? supersededBy(LateArrivalRecord record) {
    for (final LateArrivalRecord other in _records.reversed) {
      if (other.compareTo(record) <= 0) return null;
      if (other.smartschoolUid == record.smartschoolUid &&
          other.day == record.day &&
          other.halfDay == record.halfDay) {
        return other;
      }
    }
    return null;
  }

  /// Appends one registration and completes **only once it is on disk**.
  ///
  /// Print the ticket and free the scanner input after this future resolves,
  /// never before — that ordering is the durability guarantee.
  ///
  /// [scan] is a [ScanRegisterable] rather than a loose pair of ids so a student
  /// the app cannot address can never be journalled by construction (#401).
  /// [scannedAt] is the moment of the scan, not of the write. [motivation]
  /// defaults to the pinned `HH:mm – reden` composition; pass one only to
  /// override that format deliberately.
  ///
  /// A second scan of the same student is legitimate and gets its own record
  /// with a later sequence — it is the real one, and it must win.
  Future<LateArrivalRecord> register({
    required ScanRegisterable scan,
    required DateTime scannedAt,
    required String reasonLabel,
    required bool reasonIsValid,
    String? motivation,
    String? personId,
  }) async {
    final SchoolDay day = SchoolDay.of(scannedAt);
    final int sequence = (_sequenceByDay[day] ?? 0) + 1;
    final LateArrivalRecord record = LateArrivalRecord(
      id: '${day.id}-${sequence.toString().padLeft(4, '0')}',
      day: day,
      sequence: sequence,
      scannedAt: scannedAt,
      smartschoolUid: scan.student.smartschoolUid,
      wisaId: scan.student.wisaId,
      personId: personId ?? scan.student.personId?.value,
      displayName: scan.student.displayName,
      className: scan.student.className,
      internalUserId: scan.internalUserId,
      classGroupId: scan.classGroupId,
      reasonLabel: reasonLabel,
      reasonIsValid: reasonIsValid,
      motivation: motivation ?? composeMotivation(scannedAt, reasonLabel),
      status: LateArrivalStatus.pending,
    );

    // Disk first, memory second — in that order, always. A record this journal
    // claims to hold is a record a reload will find.
    await _store.append(
        day,
        _encode(<String, Object?>{
          'kind': _registrationKind,
          ...record.toJson(),
        }));

    _sequenceByDay[day] = sequence;
    _byId[record.id] = record;
    _insert(record);
    // Last, and never awaited: the record is durable and the ticket may print.
    _sink?.onRecord(record);
    return record;
  }

  /// Records that [id] has been handed to Smartschool.
  Future<LateArrivalRecord> markSent(String id) =>
      _transition(id, LateArrivalStatus.sent);

  /// Records that Smartschool acknowledged [id]. Terminal.
  Future<LateArrivalRecord> markConfirmed(String id) =>
      _transition(id, LateArrivalStatus.confirmed);

  /// Puts [id] back in the queue after a *transient* failure — the send did not
  /// land, but the registration is not given up on.
  Future<LateArrivalRecord> markPending(String id) =>
      _transition(id, LateArrivalStatus.pending);

  /// Gives up on [id], recording [error]. Terminal.
  Future<LateArrivalRecord> markFailed(String id, String error) =>
      _transition(id, LateArrivalStatus.failed, error: error);

  /// Puts the given-up registration [id] back in the queue — the operator's
  /// **Opnieuw proberen** (#460). The drain then sends it again, in its own
  /// place in drain order.
  ///
  /// An operator transition, written as an ordinary status line so a reload
  /// replays it: [LateArrivalStatus.canTransitionTo] stays strict, because
  /// giving up remains the drain's decision and only the operator may undo it.
  /// The record is marked [LateArrivalRecord.requeuedByOperator], which keeps
  /// its write from overwriting anything but nothing, a presence or a late
  /// arrival.
  ///
  /// Throws [StateError] unless [id] is [LateArrivalStatus.failed], and for a
  /// failure [supersededBy] a later scan: sending that one again would
  /// overwrite the later scan's half-day.
  Future<LateArrivalRecord> requeueFailed(String id) async {
    final LateArrivalRecord held = _require(id);
    if (held.status != LateArrivalStatus.failed) {
      throw StateError(
        'Registratie "$id" staat op ${held.status.wireName}; alleen een '
        'mislukte registratie kan opnieuw in de wachtrij.',
      );
    }
    final LateArrivalRecord? newer = supersededBy(held);
    if (newer != null) {
      throw StateError(
        'Registratie "$id" is vervangen door de latere scan "${newer.id}" en '
        'wordt niet opnieuw verstuurd.',
      );
    }
    return _append(
      held,
      LateArrivalStatus.pending,
      requeuedByOperator: true,
    );
  }

  /// Requeues every one of [failures] — what **Opnieuw proberen** does — and
  /// returns them, requeued, in drain order.
  ///
  /// One at a time, each durably on disk before the next: a write that fails
  /// throws, and leaves the records before it requeued and the rest failed,
  /// which is exactly what the journal then says. A record that stopped being
  /// one of [failures] while the earlier ones were written — a scan of the
  /// same student came in, the operator settled it by hand — is skipped.
  Future<List<LateArrivalRecord>> requeueFailures() async {
    final List<LateArrivalRecord> requeued = <LateArrivalRecord>[];
    for (final LateArrivalRecord listed in failures) {
      final LateArrivalRecord? now = _byId[listed.id];
      if (now == null ||
          now.status != LateArrivalStatus.failed ||
          supersededBy(now) != null) {
        continue;
      }
      requeued.add(await requeueFailed(now.id));
    }
    return requeued;
  }

  /// Records that the operator entered the failed registration [id] in
  /// Smartschool by hand (#460): it leaves the desk's *mislukt* list and is
  /// never sent. Terminal.
  ///
  /// Like [requeueFailed], an operator transition the drain cannot make. The
  /// record stays in the journal, with the error it failed on, so "what
  /// happened to this scan" stays answerable.
  ///
  /// Throws [StateError] unless [id] is [LateArrivalStatus.failed]: a record
  /// that is still queued, sent or confirmed is not the operator's to settle.
  Future<LateArrivalRecord> markHandledManually(String id) async {
    final LateArrivalRecord held = _require(id);
    if (held.status != LateArrivalStatus.failed) {
      throw StateError(
        'Registratie "$id" staat op ${held.status.wireName}; alleen een '
        'mislukte registratie kan als manueel ingevoerd aangeduid worden.',
      );
    }
    return _append(held, LateArrivalStatus.handledManually);
  }

  /// Appends a status line, durably, then updates the in-memory view.
  ///
  /// Throws [StateError] for an unknown id or a transition out of a terminal
  /// state: both are programming errors in the drain worker, and swallowing
  /// them would leave the operator with a journal that quietly disagrees with
  /// what Smartschool holds.
  Future<LateArrivalRecord> _transition(
    String id,
    LateArrivalStatus next, {
    String? error,
  }) async {
    final LateArrivalRecord held = _require(id);
    if (held.status == next && next != LateArrivalStatus.failed) return held;
    if (!held.status.canTransitionTo(next)) {
      throw StateError(
        'Registratie "$id" staat op ${held.status.wireName} en kan niet naar '
        '${next.wireName}.',
      );
    }
    return _append(held, next, error: error);
  }

  LateArrivalRecord _require(String id) {
    final LateArrivalRecord? held = _byId[id];
    if (held == null) {
      throw StateError('Geen registratie met id "$id" in het journaal.');
    }
    return held;
  }

  /// Writes the status line for [held] → [next] — disk first, memory second,
  /// the sink last — whoever decided on it.
  Future<LateArrivalRecord> _append(
    LateArrivalRecord held,
    LateArrivalStatus next, {
    String? error,
    bool requeuedByOperator = false,
  }) async {
    await _store.append(
        held.day,
        _encode(<String, Object?>{
          'kind': _statusKind,
          'id': held.id,
          'status': next.wireName,
          if (error != null) 'error': error,
          if (requeuedByOperator) 'requeuedByOperator': true,
        }));

    final LateArrivalRecord updated = held.withStatus(
      next,
      error: error,
      requeuedByOperator: requeuedByOperator ? true : null,
    );
    _byId[held.id] = updated;
    final int index =
        _records.indexWhere((LateArrivalRecord r) => r.id == held.id);
    if (index >= 0) _records[index] = updated;
    _sink?.onRecord(updated);
    return updated;
  }

  /// Keeps [_records] in drain order without a full sort: a new record almost
  /// always belongs at the end, and a backdated one walks back a few places.
  void _insert(LateArrivalRecord record) {
    int at = _records.length;
    while (at > 0 && _records[at - 1].compareTo(record) > 0) {
      at--;
    }
    _records.insert(at, record);
  }

  static const String _registrationKind = 'registration';
  static const String _statusKind = 'status';

  static String _encode(Map<String, Object?> line) => '${jsonEncode(line)}\n';

  /// Folds one day file into its records.
  ///
  /// Every complete line ends in a newline, so anything after the last one is a
  /// write that a crash cut in half. That tail is dropped — just the tail, never
  /// the file — which is precisely why the format is one line per event and is
  /// never rewritten in place.
  static _DayReplay _replay(String raw) {
    if (raw.isEmpty) {
      return const _DayReplay(<LateArrivalRecord>[], false, 0, 0);
    }

    final List<String> lines = raw.split('\n');
    // `split` leaves a trailing '' for a well-terminated file; anything else is
    // a torn write.
    final String tail = lines.removeLast();
    final bool truncatedTail = tail.isNotEmpty;

    final Map<String, LateArrivalRecord> byId = <String, LateArrivalRecord>{};
    final List<String> order = <String>[];
    int damagedLines = 0;
    int orphanStatusLines = 0;

    for (final String line in lines) {
      if (line.trim().isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        damagedLines++;
        continue;
      }
      if (decoded is! Map<String, dynamic>) {
        damagedLines++;
        continue;
      }
      final Map<String, Object?> json = Map<String, Object?>.from(decoded);

      switch (json['kind']) {
        case _registrationKind:
          final LateArrivalRecord? record = LateArrivalRecord.tryFromJson(json);
          if (record == null) {
            damagedLines++;
            continue;
          }
          if (!byId.containsKey(record.id)) order.add(record.id);
          byId[record.id] = record;
        case _statusKind:
          final Object? id = json['id'];
          final LateArrivalStatus? status =
              LateArrivalStatus.tryParse(json['status'] as String?);
          if (id is! String || status == null) {
            damagedLines++;
            continue;
          }
          final LateArrivalRecord? held = byId[id];
          if (held == null) {
            // The registration line it names is gone — damaged, or from a day
            // that was rolled off. Nothing to apply it to.
            orphanStatusLines++;
            continue;
          }
          byId[id] = held.withStatus(
            status,
            error: json['error'] is String ? json['error']! as String : null,
            // Sticky: the operator's requeue line sets it, and the drain's
            // later lines for the same record leave it alone.
            requeuedByOperator:
                json['requeuedByOperator'] == true ? true : null,
          );
        default:
          damagedLines++;
      }
    }

    return _DayReplay(
      <LateArrivalRecord>[for (final String id in order) byId[id]!],
      truncatedTail,
      damagedLines,
      orphanStatusLines,
    );
  }
}

/// What replaying the journal at startup found (#402).
///
/// Reported rather than logged-and-forgotten: a truncated tail or a damaged
/// line means a student may be missing from the queue, and that is a thing the
/// operator has to be told about, not a thing to discover in a log file in
/// March.
final class JournalRecovery {
  const JournalRecovery({
    required this.days,
    required this.rolledOff,
    required this.recordCount,
    required this.pendingCount,
    required this.truncatedTails,
    required this.damagedLines,
    required this.orphanStatusLines,
  });

  /// The day files that were read and kept, ascending.
  final List<SchoolDay> days;

  /// The day files deleted for being past retention and fully drained.
  final List<SchoolDay> rolledOff;

  /// How many registrations were replayed, and how many of those still need
  /// draining.
  final int recordCount;
  final int pendingCount;

  /// How many day files ended in a half-written line — at most one per file,
  /// and normally zero. A non-zero count is the fingerprint of a crash.
  final int truncatedTails;

  /// Complete lines that could not be used: unreadable JSON, an unknown kind, or
  /// a registration missing a required field.
  final int damagedLines;

  /// Status lines naming a registration that is not in the file.
  final int orphanStatusLines;

  /// Whether anything at all had to be discarded.
  bool get isClean =>
      truncatedTails == 0 && damagedLines == 0 && orphanStatusLines == 0;

  @override
  String toString() => 'JournalRecovery(${days.length} dagen, $recordCount '
      'registraties, $pendingCount te verwerken, $truncatedTails afgekapt, '
      '$damagedLines beschadigd, $orphanStatusLines wees)';
}

class _DayReplay {
  const _DayReplay(
    this.records,
    this.truncatedTail,
    this.damagedLines,
    this.orphanStatusLines,
  );

  final List<LateArrivalRecord> records;
  final bool truncatedTail;
  final int damagedLines;
  final int orphanStatusLines;
}
