import '../journal/school_day.dart';
import 'mirrored_registration.dart';

/// Where the day's registrations are shared between machines (#403).
///
/// A seam for the same reason `JournalStore` is one: this package is pure Dart
/// and must be testable with no network, while the concrete store is a Cosmos
/// container wired up in `account_state`. Every method may fail — that is the
/// normal case this feature is built around, not an exception — and the mirror
/// worker above it is what turns a failure into a retry rather than a lost
/// student.
///
/// Nothing here is on the hot path: the desk never waits on it.
abstract interface class LateArrivalMirrorStore {
  /// Creates or replaces [entry]'s document. Called once per registration and
  /// again on every status change, so it must be an idempotent upsert on
  /// [MirroredRegistration.documentId] — not an append.
  Future<void> put(MirroredRegistration entry);

  /// Every desk's registrations for [day]. The startup reconciliation's one
  /// read; an empty list when nothing has been mirrored for that day.
  Future<List<MirroredRegistration>> readDay(SchoolDay day);
}

/// A [LateArrivalMirrorStore] that keeps the documents in memory.
///
/// What a test binds, and what a build with no Cosmos coordinates can fall back
/// to — the mirror then guarantees nothing across machines, which is strictly
/// what it guaranteed before it existed and never worse.
class InMemoryLateArrivalMirrorStore implements LateArrivalMirrorStore {
  final Map<String, MirroredRegistration> _documents =
      <String, MirroredRegistration>{};

  /// When set, every call throws it — the "Cosmos is unreachable" fake the retry
  /// path is exercised against. Clear it to bring the store back up.
  Object? failure;

  /// How many [put]s were attempted, failures included.
  int putAttempts = 0;

  /// How many [readDay]s were attempted, failures included.
  int readAttempts = 0;

  /// Everything currently stored, in document-id order.
  List<MirroredRegistration> get entries =>
      _documents.values.toList(growable: false)
        ..sort(
          (MirroredRegistration a, MirroredRegistration b) =>
              a.documentId.compareTo(b.documentId),
        );

  /// Seeds a document directly, as if another desk had mirrored it.
  void seed(MirroredRegistration entry) {
    _documents[entry.documentId] = entry;
  }

  @override
  Future<void> put(MirroredRegistration entry) async {
    putAttempts++;
    final Object? boom = failure;
    if (boom != null) throw boom;
    _documents[entry.documentId] = entry;
  }

  @override
  Future<List<MirroredRegistration>> readDay(SchoolDay day) async {
    readAttempts++;
    final Object? boom = failure;
    if (boom != null) throw boom;
    return <MirroredRegistration>[
      for (final MirroredRegistration e in entries)
        if (e.day == day) e,
    ];
  }
}
