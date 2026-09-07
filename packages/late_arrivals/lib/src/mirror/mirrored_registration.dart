import '../journal/late_arrival_record.dart';
import '../journal/school_day.dart';

/// One journal record as the shared store holds it (#403).
///
/// The journal's own [LateArrivalRecord.id] is `<day>-<sequence>`, which is
/// unique **on the machine that wrote it** and nowhere else: a stand-in operator
/// whose journal is empty starts her own day at sequence 1 and would mint
/// exactly the ids the dead laptop already used. Since surviving the loss of
/// that laptop is the entire reason this mirror exists, the shared identity has
/// to carry the desk as well — hence [deskId] and [documentId].
///
/// Two desks registering the same student is therefore two documents, not one
/// overwriting the other, and that is deliberate: ownership and claims are out
/// of scope (#403), a presence save updates the half-day cell rather than
/// appending a row, and presences are reviewed afterwards.
final class MirroredRegistration {
  MirroredRegistration({
    required String deskId,
    required this.record,
    required this.mirroredAt,
  }) : deskId = normalizeDeskId(deskId);

  /// Which desk registered this student, already normalised.
  final String deskId;

  /// The journal record verbatim — the same [LateArrivalRecord.toJson] shape the
  /// day file carries, so one wire format serves both and a mirrored record
  /// replays into the local model with no translation.
  final LateArrivalRecord record;

  /// When this version of the record was handed to the store. Refreshed on
  /// every status change, so "how long has this been sitting there" is
  /// answerable from the document.
  final DateTime mirroredAt;

  /// The day the registration is filed under — the logical partition.
  SchoolDay get day => record.day;

  /// The partition-key value the document carries in `pk`.
  ///
  /// The school day, so listing a day's registrations across every desk is a
  /// single-partition query. Following the `/pk` convention epic #112 uses for
  /// every non-singleton container (`linkedAccounts` by school, `rollups` by
  /// school, `decisions` by account id) rather than inventing a new scheme.
  String get partitionKey => day.id;

  /// The globally unique document id: `<day>|<desk>|<sequence>`.
  String get documentId =>
      '${day.id}|$deskId|${record.sequence.toString().padLeft(4, '0')}';

  /// The Cosmos document. `id` and `pk` are the two fields the container is
  /// addressed by; everything else above `record` is there so a support question
  /// can be answered by looking at the document rather than by decoding the
  /// nested payload.
  Map<String, Object?> toDocument() => <String, Object?>{
        'id': documentId,
        'pk': partitionKey,
        'day': day.id,
        'desk': deskId,
        'seq': record.sequence,
        'localId': record.id,
        'status': record.status.wireName,
        'mirroredAt': mirroredAt.toIso8601String(),
        'record': record.toJson(),
      };

  /// Reads a mirrored registration back. `null` — never an exception — when the
  /// document is not one, or is damaged: the same discipline the journal's
  /// replay follows, so one unreadable document costs one registration and not
  /// the day's recovery.
  static MirroredRegistration? tryFromDocument(Map<String, Object?> document) {
    final Object? desk = document['desk'];
    final Object? mirroredAt = document['mirroredAt'];
    final Object? raw = document['record'];
    if (desk is! String || desk.isEmpty) return null;
    if (raw is! Map) return null;

    final LateArrivalRecord? record = LateArrivalRecord.tryFromJson(
      <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          if (e.key is String) e.key! as String: e.value,
      },
    );
    if (record == null) return null;

    return MirroredRegistration(
      deskId: desk,
      record: record,
      // A document written before the field existed, or with a damaged stamp,
      // is still a registration worth surfacing — the scan time is on the
      // record itself.
      mirroredAt:
          (mirroredAt is String ? DateTime.tryParse(mirroredAt) : null) ??
              record.scannedAt,
    );
  }

  @override
  String toString() => 'MirroredRegistration($documentId, '
      '${record.displayName}, ${record.status.wireName})';
}

/// The desk identifier as it may appear in a document id.
///
/// A Cosmos document id may not contain `/`, `\`, `?` or `#`, and the value this
/// is built from is a machine name an administrator chose — so it is folded to
/// lower case and everything outside `[a-z0-9._-]` becomes `-`, rather than
/// trusted. An empty or all-separator name becomes `onbekend`, which keeps the
/// registration mirrorable instead of throwing it away over a hostname.
String normalizeDeskId(String deskId) {
  final String folded = deskId
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  if (folded.isEmpty) return 'onbekend';
  return folded.length <= 64 ? folded : folded.substring(0, 64);
}
