import 'late_arrival_record.dart';

/// Told about every durable change the journal makes (#403).
///
/// Deliberately one `void` method. It is the seam the Cosmos mirror hangs off,
/// and its shape *is* the design constraint: the mirror sits **behind** the
/// journal and never in front of it, so a sink cannot be awaited, cannot report
/// a failure back, and therefore cannot delay the ticket or the drain by a
/// single millisecond however slow the thing behind it is.
///
/// The journal calls it after the line is flushed to disk and the in-memory view
/// is updated — for the registration itself and for every later status change —
/// so a sink always sees a record that is already durable locally. An
/// implementation must not throw: there is nobody to catch it, and the local
/// record is safe regardless.
abstract interface class LateArrivalRecordSink {
  /// [record] has just been appended to the journal, in its new state.
  void onRecord(LateArrivalRecord record);
}

/// Feeds one journal's changes to several sinks.
///
/// The journal takes a single sink, and by #404 there are two things that want
/// one: the Cosmos mirror (#403) and the Smartschool drain. Rather than teach
/// the journal about lists, the fan-out is its own three-line object.
///
/// A sink that throws does not stop the others. The contract says
/// implementations must not throw, but "must not" is not "cannot", and the one
/// thing that must never happen here is a misbehaving mirror keeping the drain
/// from ever hearing about a registration.
final class FanOutRecordSink implements LateArrivalRecordSink {
  const FanOutRecordSink(this.sinks);

  final List<LateArrivalRecordSink> sinks;

  @override
  void onRecord(LateArrivalRecord record) {
    for (final LateArrivalRecordSink sink in sinks) {
      try {
        sink.onRecord(record);
      } on Object {
        // Nothing to report it to, and the record is already durable.
      }
    }
  }
}
