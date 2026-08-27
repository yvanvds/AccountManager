import 'package:account_core/account_core.dart';
import 'package:account_linker/account_linker.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// A [PersonIdResolver] that records every key `link` asks it to resolve, so a
/// test can compare that set against what [naturalKeysFor] enumerates.
class _RecordingResolver implements PersonIdResolver {
  final List<String> resolved = [];
  final SeqResolver _delegate = SeqResolver();

  @override
  PersonId resolve(String naturalKey) {
    resolved.add(naturalKey);
    return _delegate.resolve(naturalKey);
  }
}

void main() {
  // A scenario spanning every record shape that carries a PersonId: a fully
  // linked student, an Azure-only orphan student (INV-22), a fully linked staff
  // member, and an Azure-only orphan staff member. Groups deliberately included
  // to prove they contribute no keys.
  final wisa = wisaSnap(
    [wisaStudent('1')],
    staff: [wisaStaff('DOE', wisaId: '100')],
    classGroups: [wisaClassGroup('1A')],
  );
  final smartschool = ssSnap(
    [ssAccount(uid: 'jane', accountId: '1', mail: 'jane@school.example')],
    groups: [ssGroup('1A')],
  );
  final smartschoolStaff = ssStaffAccount(
    uid: 'doe',
    accountId: 'DOE',
    mail: 'doe@school.example',
  );
  final withStaff = ssSnap(
    [
      ssAccount(uid: 'jane', accountId: '1', mail: 'jane@school.example'),
      smartschoolStaff,
    ],
    groups: [ssGroup('1A')],
  );
  final azure = azSnap([
    azureUser(id: 'az1', upn: 'jane@school.example', employeeId: '1'),
    azureUser(id: 'az2', upn: 'ghost@school.example', companyName: 'SMA'),
    azureUser(
        id: 'az3',
        upn: 'doe@school.example',
        employeeId: '100',
        department: 'SMA-team'),
    azureUser(id: 'az4', upn: 'exstaff@school.example', department: 'SMA-team'),
  ]);

  group('naturalKeysFor', () {
    test('returns exactly the keys link() resolves (the seam contract)', () {
      final recorder = _RecordingResolver();
      link(wisa, withStaff, azure, recorder, schoolPrefix: 'SMA');

      final enumerated =
          naturalKeysFor(wisa, withStaff, azure, schoolPrefix: 'SMA');

      // Every key link asked for, deduplicated, is exactly what the enumerator
      // returns — so a DB-backed resolver primed from naturalKeysFor can never
      // hit an unprepared key inside the pure pass, and never mints a key link
      // won't use.
      expect(enumerated, equals(recorder.resolved.toSet()));
    });

    test('covers students, orphans, and staff under the right namespaces', () {
      final keys = naturalKeysFor(wisa, withStaff, azure, schoolPrefix: 'SMA');
      expect(
        keys,
        containsAll(<String>[
          'wisa:1', // fully linked student
          'upn:ghost@school.example', // Azure-only orphan student (INV-22)
          'staff:wisa:100', // fully linked staff member
          'staff:upn:exstaff@school.example', // Azure-only orphan staff
        ]),
      );
    });

    test('uid-only records keep the seam contract via the ss: fallback', () {
      // Intern-style accounts with no accountId and no mail key by uid; the
      // enumerator must hand the same fallback keys to a DB-backed resolver.
      final uidOnly = ssSnap([
        ssAccount(uid: 'stagiair1', accountId: '', mail: ''),
        ssStaffAccount(uid: 'begeleider', accountId: '', mail: ''),
      ]);
      final recorder = _RecordingResolver();
      link(wisaSnap(const []), uidOnly, azSnap(const []), recorder,
          schoolPrefix: 'SMA');

      final keys = naturalKeysFor(wisaSnap(const []), uidOnly, azSnap(const []),
          schoolPrefix: 'SMA');

      expect(keys, equals(recorder.resolved.toSet()));
      expect(
          keys, containsAll(<String>['ss:stagiair1', 'staff:ss:begeleider']));
    });

    test('a duplicate-mail pair enumerates both of its keys (#323)', () {
      // The keys are claimed as they are handed out, so the co-account's
      // fall-through key has to be enumerated too — a DB-backed resolver primed
      // from this set must find it prepared, not mint it mid-pass.
      final coAccounts = ssSnap([
        ssAccount(uid: 'jane', accountId: '1', mail: 'jane@school.example'),
        ssAccount(
            uid: 'jane-admin', accountId: '1', mail: 'jane@school.example'),
      ]);
      final recorder = _RecordingResolver();
      link(wisa, coAccounts, azSnap(const []), recorder, schoolPrefix: 'SMA');

      final keys = naturalKeysFor(wisa, coAccounts, azSnap(const []),
          schoolPrefix: 'SMA');

      expect(recorder.resolved.toSet(), hasLength(recorder.resolved.length),
          reason: 'no key is handed out twice, so no two records share an id');
      expect(keys, equals(recorder.resolved.toSet()));
      expect(keys, containsAll(<String>['wisa:1', 'mail:jane@school.example']));
    });

    test('an account both populations claim enumerates one key, not two (#386)',
        () {
      // INV-27 drops the record the losing pass manufactured, and the seam has
      // to see the same population `link` does: a key enumerated for a record
      // that no longer exists would be minted and persisted for nobody, and a
      // record `link` kept but the enumerator dropped would hit an unprepared
      // key mid-pass. Both are the same drift, in opposite directions.
      final teacher = azSnap([
        azureUser(
          id: 'az-titular',
          upn: 'titularis@school.example',
          employeeId: '100',
          companyName: 'SMA',
          department: 'SMA-team',
        ),
      ]);
      final staffOnly =
          wisaSnap(const [], staff: [wisaStaff('DOE', wisaId: '100')]);
      final recorder = _RecordingResolver();
      link(staffOnly, ssSnap(const []), teacher, recorder, schoolPrefix: 'SMA');

      final keys = naturalKeysFor(staffOnly, ssSnap(const []), teacher,
          schoolPrefix: 'SMA');

      expect(keys, equals(recorder.resolved.toSet()));
      expect(keys, <String>{'staff:wisa:100'});
      expect(keys.any((k) => k.startsWith('upn:')), isFalse,
          reason: 'the dropped student orphan contributes no key');
    });

    test('is a pure function of the snapshots — no group keys, stable', () {
      // Groups carry no PersonId; the enumerated set is unchanged whether or not
      // the resolver would be called, and repeated calls agree.
      final first =
          naturalKeysFor(wisa, smartschool, azure, schoolPrefix: 'SMA');
      final second =
          naturalKeysFor(wisa, smartschool, azure, schoolPrefix: 'SMA');
      expect(first, equals(second));
      expect(first.any((k) => k.contains('1a')), isFalse,
          reason: 'a class-group name must never leak into the id key set');
    });
  });
}
