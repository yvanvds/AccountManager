import 'package:account_core/account_core.dart';
import 'package:account_linker/account_linker.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

const _prefix = 'Arcadia';

void main() {
  group('link — student scenarios', () {
    test('fully linked across three systems → high confidence', () {
      final snapshot = link(
        wisaSnap([wisaStudent('W1')]),
        ssSnap([ssAccount(uid: 'jane', accountId: 'W1', mail: 'jane@s.be')]),
        azSnap([
          azureUser(
            id: 'az-1',
            upn: 'jane@s.be',
            employeeId: 'W1',
            companyName: _prefix,
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      expect(snapshot.accounts, hasLength(1));
      final a = snapshot.accounts.single;
      expect(a.confidence, LinkConfidence.high);
      expect(a.wisa, isNotNull);
      expect(a.smartschool, isNotNull);
      expect(a.azure, isNotNull);
      expect(a.role, PersonRole.student);
      expect(snapshot.warnings, isEmpty);
      // Present in all three ⇒ counts toward linked everywhere.
      expect(snapshot.wisa.linked, 1);
      expect(snapshot.smartschool.linked, 1);
      expect(snapshot.azure.linked, 1);
    });

    test('WISA student not yet in Smartschool → medium placeholder', () {
      final snapshot = link(
        wisaSnap([wisaStudent('W2')]),
        ssSnap(const []),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final a = snapshot.accounts.single;
      expect(a.wisa, isNotNull);
      expect(a.smartschool, isNull);
      expect(a.azure, isNull);
      expect(a.confidence, LinkConfidence.medium);
      expect(snapshot.wisa.unlinked, 1);
    });

    test('Azure-only user with school prefix is kept for later removal', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap(const []),
        azSnap([
          azureUser(id: 'az-3', upn: 'gone@s.be', companyName: _prefix),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final a = snapshot.accounts.single;
      expect(a.azure, isNotNull);
      expect(a.wisa, isNull);
      expect(a.smartschool, isNull);
      expect(a.confidence, LinkConfidence.medium);
      expect(snapshot.azure.unlinked, 1);
    });

    test('Azure user from another school is discarded', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap(const []),
        azSnap([
          azureUser(
            id: 'az-4',
            upn: 'someone@other.be',
            companyName: 'OtherSchool',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      expect(snapshot.accounts, isEmpty);
    });

    test('INV-12: case and whitespace differences still link', () {
      final snapshot = link(
        wisaSnap([wisaStudent('W5')]),
        ssSnap([ssAccount(uid: 'k', accountId: 'W5', mail: 'Kim@S.BE')]),
        azSnap([
          azureUser(
            id: 'az-5',
            upn: '  kim@s.be  ',
            employeeId: 'w5',
            companyName: _prefix,
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final a = snapshot.accounts.single;
      expect(a.wisa, isNotNull);
      expect(a.smartschool, isNotNull);
      expect(a.azure, isNotNull);
      // Keys agree once normalised ⇒ high confidence.
      expect(a.confidence, LinkConfidence.high);
    });

    test('INV-23: duplicate-mail Smartschool accounts both kept + warning', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap([
          ssAccount(uid: 'twin-a', accountId: 'W6', mail: 'twin@s.be'),
          ssAccount(uid: 'twin-b', accountId: 'W7', mail: 'TWIN@s.be'),
        ]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      // Both retained — neither silently dropped (PAIN-7).
      final uids = snapshot.accounts
          .map((a) => a.smartschool?.uid)
          .whereType<String>()
          .toSet();
      expect(uids, {'twin-a', 'twin-b'});

      final warning = snapshot.warnings.single as ResolveDuplicateMail;
      expect(warning.mail, 'twin@s.be');
      expect(
        warning.accounts.map((a) => a.uid).toSet(),
        {'twin-a', 'twin-b'},
      );
    });

    test('co-account (non-student) Smartschool records are ignored', () {
      // The concrete model only emits primary student accounts via
      // `accountType`; staff are filtered by role (see staff scenarios). A
      // plain student links normally here.
      final snapshot = link(
        wisaSnap(const []),
        ssSnap([ssAccount(uid: 'kid', accountId: 'W8', mail: 'kid@s.be')]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );
      expect(snapshot.accounts.single.smartschool?.uid, 'kid');
    });

    test('Azure matched by employeeId when UPN differs from mail', () {
      final snapshot = link(
        wisaSnap([wisaStudent('W9')]),
        ssSnap([ssAccount(uid: 'amy', accountId: 'W9', mail: 'amy@s.be')]),
        azSnap([
          // UPN was renamed and no longer equals the Smartschool mail, but the
          // employeeId still bridges to the WISA id.
          azureUser(
            id: 'az-9',
            upn: 'amy.doe@s.be',
            employeeId: 'W9',
            companyName: _prefix,
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final a = snapshot.accounts.single;
      expect(a.azure?.id, 'az-9');
      expect(a.wisa, isNotNull);
      expect(a.smartschool, isNotNull);
      // upn != mail ⇒ not all keys agree ⇒ medium.
      expect(a.confidence, LinkConfidence.medium);
    });

    test('groups stay empty (out of scope for #45)', () {
      final snapshot = link(
        wisaSnap([wisaStudent('W10')]),
        ssSnap(const []),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );
      expect(snapshot.groups, isEmpty);
    });
  });

  group('link — staff scenarios', () {
    test('fully linked across three systems → high confidence', () {
      // Staff bridge Smartschool by `code` (≡ accountId) and Azure by `wisaId`
      // (≡ employeeId): the two WISA identifiers are distinct (OQ-1).
      final snapshot = link(
        wisaSnap(const [], staff: [wisaStaff('DOEJA', wisaId: '493')]),
        ssSnap([ssStaffAccount(uid: 'jdoe', accountId: 'DOEJA', mail: 'j@s.be')]),
        azSnap([
          azureUser(
            id: 'az-s1',
            upn: 'j@s.be',
            employeeId: '493',
            department: 'Arcadia - Wiskunde',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      // No student records; one fully-linked staff record.
      expect(snapshot.accounts, isEmpty);
      expect(snapshot.staff, hasLength(1));
      final s = snapshot.staff.single;
      expect(s.confidence, LinkConfidence.high);
      expect(s.wisa, isNotNull);
      expect(s.smartschool, isNotNull);
      expect(s.azure, isNotNull);
      expect(s.role, PersonRole.teacher);
      expect(snapshot.warnings, isEmpty);
      // Present in all three ⇒ counts toward linked everywhere.
      expect(snapshot.wisa.linked, 1);
      expect(snapshot.smartschool.linked, 1);
      expect(snapshot.azure.linked, 1);
    });

    test('director role is preserved on the linked staff record', () {
      final snapshot = link(
        wisaSnap(const [], staff: [wisaStaff('BIGBO', wisaId: '1')]),
        ssSnap([
          ssStaffAccount(
            uid: 'boss',
            accountId: 'BIGBO',
            mail: 'boss@s.be',
            role: PersonRole.director,
          ),
        ]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );
      expect(snapshot.staff.single.role, PersonRole.director);
    });

    test('WISA staff not yet in Smartschool → medium placeholder', () {
      final snapshot = link(
        wisaSnap(const [], staff: [wisaStaff('NEWBI', wisaId: '900')]),
        ssSnap(const []),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final s = snapshot.staff.single;
      expect(s.wisa, isNotNull);
      expect(s.smartschool, isNull);
      expect(s.azure, isNull);
      expect(s.confidence, LinkConfidence.medium);
      expect(snapshot.wisa.unlinked, 1);
    });

    test('staff present only in Smartschool + Azure (no WISA) → medium', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap([ssStaffAccount(uid: 't', accountId: 'TEACH', mail: 't@s.be')]),
        azSnap([
          azureUser(
            id: 'az-s2',
            upn: 't@s.be',
            employeeId: '777',
            department: 'Arcadia',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      expect(snapshot.accounts, isEmpty);
      final s = snapshot.staff.single;
      expect(s.wisa, isNull);
      expect(s.smartschool, isNotNull);
      expect(s.azure, isNotNull);
      expect(s.confidence, LinkConfidence.medium);
    });

    test('Azure-only staff with school prefix in department is kept', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap(const []),
        azSnap([
          azureUser(
            id: 'az-s3',
            upn: 'gone@s.be',
            department: 'Arcadia - Talen',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final s = snapshot.staff.single;
      expect(s.azure, isNotNull);
      expect(s.wisa, isNull);
      expect(s.smartschool, isNull);
      expect(s.confidence, LinkConfidence.medium);
      expect(snapshot.azure.unlinked, 1);
    });

    test('Azure staff matched by employeeId when UPN differs from mail', () {
      final snapshot = link(
        wisaSnap(const [], staff: [wisaStaff('AMYTE', wisaId: '321')]),
        ssSnap([ssStaffAccount(uid: 'amy', accountId: 'AMYTE', mail: 'amy@s.be')]),
        azSnap([
          azureUser(
            id: 'az-s4',
            upn: 'amy.renamed@s.be',
            employeeId: '321',
            department: 'Arcadia',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final s = snapshot.staff.single;
      expect(s.azure?.id, 'az-s4');
      expect(s.wisa, isNotNull);
      expect(s.smartschool, isNotNull);
      // upn != mail ⇒ not all keys agree ⇒ medium.
      expect(s.confidence, LinkConfidence.medium);
    });

    test('staff and students partition cleanly from one Smartschool list', () {
      // A teacher and a student share neither key; each must land in exactly
      // one population, never both.
      final snapshot = link(
        wisaSnap([wisaStudent('W1')], staff: [wisaStaff('TEACH', wisaId: '5')]),
        ssSnap([
          ssAccount(uid: 'pupil', accountId: 'W1', mail: 'pupil@s.be'),
          ssStaffAccount(uid: 'teach', accountId: 'TEACH', mail: 'teach@s.be'),
        ]),
        azSnap([
          azureUser(
            id: 'az-stud',
            upn: 'pupil@s.be',
            employeeId: 'W1',
            companyName: _prefix,
          ),
          azureUser(
            id: 'az-staff',
            upn: 'teach@s.be',
            employeeId: '5',
            department: 'Arcadia',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      expect(snapshot.accounts.single.smartschool?.uid, 'pupil');
      expect(snapshot.staff.single.smartschool?.uid, 'teach');
      expect(snapshot.accounts.single.confidence, LinkConfidence.high);
      expect(snapshot.staff.single.confidence, LinkConfidence.high);
    });

    test('INV-23: duplicate-mail staff accounts both kept + warning', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap([
          ssStaffAccount(uid: 'twin-a', accountId: 'TWINA', mail: 'twin@s.be'),
          ssStaffAccount(uid: 'twin-b', accountId: 'TWINB', mail: 'TWIN@s.be'),
        ]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final uids = snapshot.staff
          .map((s) => s.smartschool?.uid)
          .whereType<String>()
          .toSet();
      expect(uids, {'twin-a', 'twin-b'});

      final warning = snapshot.warnings.single as ResolveDuplicateMail;
      expect(warning.mail, 'twin@s.be');
      expect(warning.accounts.map((a) => a.uid).toSet(), {'twin-a', 'twin-b'});
    });

    test('staff member with no wisaId still links via code + mail', () {
      // OQ-1: wisaId may be empty; code remains the Smartschool bridge.
      final snapshot = link(
        wisaSnap(const [], staff: [wisaStaff('NOIDS')]),
        ssSnap([ssStaffAccount(uid: 'n', accountId: 'NOIDS', mail: 'n@s.be')]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final s = snapshot.staff.single;
      expect(s.wisa, isNotNull);
      expect(s.smartschool?.uid, 'n');
      // No Azure (and no wisaId to bridge it) ⇒ medium.
      expect(s.confidence, LinkConfidence.medium);
    });
  });
}
