import 'package:wisa_api/wisa_api.dart';

/// Whether two WISA snapshots hold the same content — the "smart sync" test
/// (#99): after a fresh WISA pull, the reconcile flow diffs it against the
/// previously retained snapshot and, when nothing changed, reports "no account
/// changes needed" instead of re-linking and re-deriving actions.
///
/// Content equality only: `fetchedAt` is deliberately ignored (a re-pull always
/// carries a new timestamp), and so is row order — WISA assembles the snapshot
/// per school, so a reordering without a record change is still "unchanged".
/// The comparison leans on the value equality of the four record types
/// ([WisaStudent], [WisaStaff], [WisaClassGroup], [WisaSchool]).
bool wisaSnapshotUnchanged(WisaSnapshot previous, WisaSnapshot fresh) =>
    _sameRecords(previous.students, fresh.students) &&
    _sameRecords(previous.staff, fresh.staff) &&
    _sameRecords(previous.classGroups, fresh.classGroups) &&
    _sameRecords(previous.schools, fresh.schools);

/// Order-insensitive list comparison. A plain set comparison would treat
/// duplicate records as one, so both the length and the set must match.
bool _sameRecords<T>(List<T> a, List<T> b) =>
    a.length == b.length && Set<T>.of(a).containsAll(b);
