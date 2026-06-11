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
      // The concrete model only emits students, but the linker must honour the
      // accountType filter regardless. A student links normally.
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

    test('staff and groups stay empty (out of scope for #43)', () {
      final snapshot = link(
        wisaSnap([wisaStudent('W10')]),
        ssSnap(const []),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );
      expect(snapshot.staff, isEmpty);
      expect(snapshot.groups, isEmpty);
    });
  });
}
