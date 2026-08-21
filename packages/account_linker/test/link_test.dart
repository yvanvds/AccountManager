import 'package:account_core/account_core.dart';
import 'package:account_linker/account_linker.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

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

    test(
        'a transferred student\'s account links by employeeId alone — no '
        'companyName, an unusable UPN (#224)', () {
      // The state a transfer from a sibling group school leaves behind: the
      // account exists, the employeeId is our WISA id, `companyName` was never
      // stamped, `department` still names the other school, and that school
      // mangled the given/family-name order of a foreign name, so the UPN is
      // nothing we would ever project. `employeeId` is the only usable key —
      // and it must be enough, or the app proposes a second account.
      final snapshot = link(
        wisaSnap([wisaStudent('W7')]),
        ssSnap(const []),
        azSnap([
          azureUser(
            id: 'az-transferred',
            upn: 'alfio.ambre@student.other.example',
            employeeId: 'W7',
            department: 'OTHER-3A',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      // One record, not two: the Azure user joined the WISA student rather
      // than being dropped as "another school's" or kept as an orphan.
      expect(snapshot.accounts, hasLength(1));
      final a = snapshot.accounts.single;
      expect(a.wisa?.wisaId.value, 'W7');
      expect(a.azure?.id, 'az-transferred');
      expect(a.smartschool, isNull);
    });

    test('a WISA student leaves groups untouched', () {
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

  group('link — group scenarios', () {
    test('fully linked across three systems → high confidence', () {
      final snapshot = link(
        wisaSnap(const [], classGroups: [wisaClassGroup('5A')]),
        ssSnap(const [], groups: [ssGroup('5A')]),
        azSnap(const [], groups: [azureGroup('5A')]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      expect(snapshot.groups, hasLength(1));
      final g = snapshot.groups.single;
      expect(g.confidence, LinkConfidence.high);
      expect(g.wisa!.name, '5A');
      expect(g.wisa!.origin, Origin.wisa);
      expect(g.smartschool, isNotNull);
      expect(g.azure, isNotNull);
    });

    test('WISA-only group → medium, no Smartschool/Azure', () {
      final snapshot = link(
        wisaSnap(const [], classGroups: [wisaClassGroup('3B')]),
        ssSnap(const []),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final g = snapshot.groups.single;
      expect(g.wisa!.name, '3B');
      expect(g.smartschool, isNull);
      expect(g.azure, isNull);
      expect(g.confidence, LinkConfidence.medium);
    });

    test('WISA projection carries adminCode as adminNumber, empty untis (#65)',
        () {
      final snapshot = link(
        wisaSnap(
          const [],
          classGroups: [
            wisaClassGroup('3B', schoolCode: '456', adminCode: '42'),
          ],
        ),
        ssSnap(const []),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final wisa = snapshot.groups.single.wisa!;
      expect(wisa.instituteNumber, '456');
      expect(wisa.adminNumber, 42);
      // WISA carries no Untis code; AddToSmartschool seeds it from the name.
      expect(wisa.untis, '');
    });

    test('Smartschool-only orphan group is kept (#52)', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap(const [], groups: [ssGroup('6C')]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final g = snapshot.groups.single;
      expect(g.wisa, isNull);
      expect(g.smartschool, isNotNull);
      expect(g.azure, isNull);
      expect(g.confidence, LinkConfidence.medium);
    });

    test('non-official Smartschool group does not seed an orphan', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap(const [], groups: [ssGroup('6C', official: false)]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );
      expect(snapshot.groups, isEmpty);
    });

    test('Azure-only orphan group is kept (#52)', () {
      final snapshot = link(
        wisaSnap(const []),
        ssSnap(const []),
        azSnap(const [], groups: [azureGroup('6C')]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final g = snapshot.groups.single;
      expect(g.wisa, isNull);
      expect(g.smartschool, isNull);
      expect(g.azure, isNotNull);
      expect(g.confidence, LinkConfidence.medium);
    });

    test(
      'an Azure staff/administrative group is not kept as a class orphan (#52)',
      () {
        final snapshot = link(
          wisaSnap(const []),
          ssSnap(const []),
          azSnap(
            const [],
            groups: [
              azureGroup('$_prefix-Personeel'),
              azureGroup('$_prefix-Directie'),
              azureGroup('$_prefix-Secretariaat'),
              azureGroup('$_prefix-Leraren'),
            ],
          ),
          SeqResolver(),
          schoolPrefix: _prefix,
        );
        expect(snapshot.groups, isEmpty);
      },
    );

    test('WISA + Smartschool but no Azure → medium', () {
      final snapshot = link(
        wisaSnap(const [], classGroups: [wisaClassGroup('5A')]),
        ssSnap(const [], groups: [ssGroup('5A')]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final g = snapshot.groups.single;
      expect(g.smartschool, isNotNull);
      expect(g.azure, isNull);
      expect(g.confidence, LinkConfidence.medium);
    });

    test('non-official Smartschool group never links', () {
      final snapshot = link(
        wisaSnap(const [], classGroups: [wisaClassGroup('5A')]),
        ssSnap(const [], groups: [ssGroup('5A', official: false)]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final g = snapshot.groups.single;
      // The organisational group with the same name is ignored.
      expect(g.smartschool, isNull);
      expect(g.confidence, LinkConfidence.medium);
    });

    test('subgroup fullName (name + groupName) is the match key', () {
      final snapshot = link(
        wisaSnap(const [],
            classGroups: [wisaClassGroup('5A', groupName: '01')]),
        ssSnap(const [], groups: [ssGroup('5A 01')]),
        azSnap(const [], groups: [azureGroup('5A 01')]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final g = snapshot.groups.single;
      expect(g.wisa!.name, '5A 01');
      expect(g.smartschool, isNotNull);
      expect(g.azure, isNotNull);
      expect(g.confidence, LinkConfidence.high);
    });

    test('INV-12: case/whitespace differences still link → high', () {
      final snapshot = link(
        wisaSnap(const [], classGroups: [wisaClassGroup('5A')]),
        ssSnap(const [], groups: [ssGroup('5a')]),
        azSnap(const [], groups: [azureGroup('  5A  ')]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      final g = snapshot.groups.single;
      expect(g.smartschool, isNotNull);
      expect(g.azure, isNotNull);
      expect(g.confidence, LinkConfidence.high);
    });

    test('duplicate WISA fullName collapses to one record', () {
      final snapshot = link(
        wisaSnap(
          const [],
          // Same fullName from two schools — one linked group, first wins.
          classGroups: [
            wisaClassGroup('5A', schoolCode: '111'),
            wisaClassGroup('5A', schoolCode: '222'),
          ],
        ),
        ssSnap(const []),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      expect(snapshot.groups, hasLength(1));
      expect(snapshot.groups.single.wisa!.instituteNumber, '111');
    });
  });

  group('link — class groups are scoped to the schools we manage (#205)', () {
    /// Links [classGroups] alone (no people), with the managed-school set
    /// pinned by [ourSchoolIds] (the Settings path) or derived from [schools].
    LinkedSnapshot linkClasses(
      List<wapi.WisaClassGroup> classGroups, {
      Set<int>? ourSchoolIds,
      List<wapi.WisaSchool> schools = const [],
      List<Group> ssGroups = const [],
    }) =>
        link(
          wisaSnap(const [], classGroups: classGroups, schools: schools),
          ssSnap(const [], groups: ssGroups),
          azSnap(const []),
          SeqResolver(),
          schoolPrefix: _prefix,
          ourSchoolIds: ourSchoolIds,
        );

    test('a class of a school we do not manage is not linked at all', () {
      final snapshot = linkClasses(
        [wisaClassGroup('9Z', schoolId: 2)],
        ourSchoolIds: const {1},
      );

      // No record ⇒ no group candidate for the action engine to raise.
      expect(snapshot.groups, isEmpty);
    });

    test('a class of a school we manage still links', () {
      final snapshot = linkClasses(
        [wisaClassGroup('3B', schoolCode: '111', schoolId: 1)],
        ourSchoolIds: const {1},
      );

      final g = snapshot.groups.single;
      expect(g.wisa!.name, '3B');
      expect(g.wisa!.instituteNumber, '111');
      expect(g.smartschool, isNull);
      expect(g.confidence, LinkConfidence.medium);
    });

    test('a foreign class sharing a name does not shadow ours', () {
      // The sibling school's 5A arrives first: before #205 it seeded the name
      // key and *our* 5A was dropped as a duplicate, so the class proposed to
      // Smartschool carried the wrong school's institute number.
      final snapshot = linkClasses(
        [
          wisaClassGroup('5A', schoolCode: '222', schoolId: 2),
          wisaClassGroup('5A', schoolCode: '111', schoolId: 1),
        ],
        ourSchoolIds: const {1},
      );

      expect(snapshot.groups, hasLength(1));
      expect(snapshot.groups.single.wisa!.instituteNumber, '111');
    });

    test('the managed set falls back to WisaSchool.isOurs when unset', () {
      final snapshot = linkClasses(
        [
          wisaClassGroup('5A', schoolId: 1),
          wisaClassGroup('9Z', schoolId: 2),
        ],
        schools: [wisaSchool(1, ours: true), wisaSchool(2)],
      );

      expect([for (final g in snapshot.groups) g.wisa!.name], ['5A']);
    });

    test('ownership unconfigured → every class still links', () {
      // No explicit set and no isOurs flags anywhere: the pre-#205 behaviour is
      // preserved for a group that has not marked its schools yet.
      final snapshot = linkClasses([
        wisaClassGroup('5A', schoolId: 1),
        wisaClassGroup('9Z', schoolId: 2),
      ]);

      expect([for (final g in snapshot.groups) g.wisa!.name], ['5A', '9Z']);
    });

    test(
        'a Smartschool class matching only a foreign WISA class becomes an '
        'orphan rather than a link', () {
      final snapshot = linkClasses(
        [wisaClassGroup('9Z', schoolId: 2)],
        ourSchoolIds: const {1},
        ssGroups: [ssGroup('9Z')],
      );

      final g = snapshot.groups.single;
      expect(g.wisa, isNull,
          reason: 'linking it would treat a class we do not manage as in sync');
      expect(g.smartschool, isNotNull);
      expect(g.confidence, LinkConfidence.medium);
    });
  });

  group('link — class groups of a virtual school are never imported (#209)',
      () {
    /// Links [classGroups] (and optionally [students]) with the schools list
    /// carrying the virtual/ours flags the linker derives its two group filters
    /// from. [ourSchoolIds] pins the managed set the Settings path supplies.
    LinkedSnapshot linkVirtual(
      List<wapi.WisaClassGroup> classGroups, {
      List<wapi.WisaSchool> schools = const [],
      Set<int>? ourSchoolIds,
      List<wapi.WisaStudent> students = const [],
      List<Group> ssGroups = const [],
    }) =>
        link(
          wisaSnap(students, classGroups: classGroups, schools: schools),
          ssSnap(const [], groups: ssGroups),
          azSnap(const []),
          SeqResolver(),
          schoolPrefix: _prefix,
          ourSchoolIds: ourSchoolIds,
        );

    test('a class of a virtual school raises no record, even when managed', () {
      // The real config: the virtual school is ticked "beheerd" too, so the
      // #205 ownership filter passes it straight through. Only the virtual
      // exclusion keeps its classes out.
      final snapshot = linkVirtual(
        [wisaClassGroup('1V', schoolId: 99)],
        schools: [wisaSchool(99, ours: true, virtual: true)],
        ourSchoolIds: const {1, 99},
      );

      expect(snapshot.groups, isEmpty);
    });

    test('a class of a managed, non-virtual school is unaffected', () {
      final snapshot = linkVirtual(
        [
          wisaClassGroup('3B', schoolCode: '111', schoolId: 1),
          wisaClassGroup('1V', schoolId: 99),
        ],
        schools: [wisaSchool(1, ours: true), wisaSchool(99, virtual: true)],
        ourSchoolIds: const {1, 99},
      );

      expect([for (final g in snapshot.groups) g.wisa!.name], ['3B']);
      expect(snapshot.groups.single.wisa!.instituteNumber, '111');
    });

    test('the virtual exclusion applies on top of the #205 ours fallback', () {
      // Ownership unconfigured ⇒ every school is ours (the pre-#205 fallback),
      // but a virtual school's classes are still dropped.
      final snapshot = linkVirtual(
        [
          wisaClassGroup('5A', schoolId: 1),
          wisaClassGroup('1V', schoolId: 99),
        ],
        schools: [wisaSchool(1), wisaSchool(99, virtual: true)],
      );

      expect([for (final g in snapshot.groups) g.wisa!.name], ['5A']);
    });

    test('a virtual class arriving first no longer shadows ours', () {
      // The name key is claimed at the seed, so a same-named virtual class used
      // to occupy it and the surviving proposal described the virtual school.
      final snapshot = linkVirtual(
        [
          wisaClassGroup('1A', schoolCode: '999', schoolId: 99),
          wisaClassGroup('1A', schoolCode: '111', schoolId: 1),
        ],
        schools: [
          wisaSchool(1, ours: true),
          wisaSchool(99, ours: true, virtual: true)
        ],
        ourSchoolIds: const {1, 99},
      );

      expect(snapshot.groups, hasLength(1));
      expect(snapshot.groups.single.wisa!.instituteNumber, '111');
    });

    test('students of a virtual school still link, and stay ours', () {
      // The virtual work date exists precisely so these people come back; only
      // the class-group records are in scope. Placement reads the student's own
      // `classGroup` string, so dropping the records moves nobody.
      final snapshot = linkVirtual(
        [wisaClassGroup('1V', schoolId: 99)],
        schools: [
          wisaSchool(1, ours: true),
          wisaSchool(99, ours: true, virtual: true)
        ],
        ourSchoolIds: const {1, 99},
        students: [wisaStudent('W9', schoolId: 99)],
      );

      expect(snapshot.groups, isEmpty);
      final a = snapshot.accounts.single;
      expect(a.wisa, isNotNull);
      expect(a.wisaSchoolIds, {99});
      expect(a.wisaPresence, WisaPresence.ours);
    });

    test(
        'a Smartschool class whose only WISA counterpart is virtual becomes an '
        'orphan', () {
      final snapshot = linkVirtual(
        [wisaClassGroup('1V', schoolId: 99)],
        schools: [wisaSchool(99, ours: true, virtual: true)],
        ourSchoolIds: const {99},
        ssGroups: [ssGroup('1V')],
      );

      final g = snapshot.groups.single;
      expect(g.wisa, isNull);
      expect(g.smartschool, isNotNull);
      expect(g.confidence, LinkConfidence.medium);
    });
  });

  group('link — staff scenarios', () {
    test('fully linked across three systems → high confidence', () {
      // Staff bridge Smartschool by `code` (≡ accountId) and Azure by `wisaId`
      // (≡ employeeId): the two WISA identifiers are distinct (OQ-1).
      final snapshot = link(
        wisaSnap(const [], staff: [wisaStaff('DOEJA', wisaId: '493')]),
        ssSnap(
            [ssStaffAccount(uid: 'jdoe', accountId: 'DOEJA', mail: 'j@s.be')]),
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
        ssSnap(
            [ssStaffAccount(uid: 'amy', accountId: 'AMYTE', mail: 'amy@s.be')]),
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

    test(
        'a moved staff member\'s account links by employeeId alone — another '
        'school\'s department, an unusable UPN (#231)', () {
      // The state a move from a sibling group school leaves behind, the staff
      // counterpart of #224: the account exists, its `employeeId` is our WISA
      // id, but `department` still names the school they came from — so it
      // matches neither leg of the connector's `$filter` *and* would be dropped
      // here as "another school's" if `employeeId` did not bridge it. The UPN
      // that school wrote is no key either. Without this link the app proposes
      // a second Office 365 account.
      final snapshot = link(
        wisaSnap(const [], staff: [wisaStaff('SMITA', wisaId: '42')]),
        ssSnap(const []),
        azSnap([
          azureUser(
            id: 'az-moved',
            upn: 'smit.anna@other.example',
            employeeId: '42',
            department: 'OTHER - Wiskunde',
          ),
        ]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      // One record, not two: the Azure user joined the WISA staff member
      // rather than being dropped as another school's.
      expect(snapshot.staff, hasLength(1));
      final s = snapshot.staff.single;
      expect(s.wisa?.wisaId?.value, '42');
      expect(s.azure?.id, 'az-moved');
      expect(s.smartschool, isNull);
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

    test('a Smartschool-only account with no accountId or mail keys by uid',
        () {
      // Real tenant data (found live in #99): intern accounts carry neither
      // the WISA-id convention nor a mail address, so the uid is their only
      // identity. This used to hit the "no identifying key" StateError.
      final snapshot = link(
        wisaSnap(const []),
        ssSnap([
          ssAccount(uid: 'stagiair1', accountId: '', mail: ''),
          ssStaffAccount(uid: 'begeleider', accountId: '', mail: ''),
        ]),
        azSnap(const []),
        SeqResolver(),
        schoolPrefix: _prefix,
      );

      expect(snapshot.accounts.single.smartschool?.uid, 'stagiair1');
      expect(snapshot.staff.single.smartschool?.uid, 'begeleider');
    });
  });

  group('link — WISA-school membership + ours-vs-group (#134)', () {
    /// A student fully linked across the three systems whose WISA row sits in
    /// [schoolId]. [schools] carries the managed-school flags the linker derives
    /// its ownership set from; [ourSchoolIds] overrides that derivation.
    LinkedSnapshot linkStudentIn(
      int schoolId, {
      List<wapi.WisaSchool> schools = const [],
      Set<int>? ourSchoolIds,
    }) =>
        link(
          wisaSnap([wisaStudent('W1', schoolId: schoolId)], schools: schools),
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
          ourSchoolIds: ourSchoolIds,
        );

    test('the record retains the WISA school ids it was found in', () {
      final a = linkStudentIn(7).accounts.single;
      expect(a.wisaSchoolIds, {7});
    });

    test('ownership unconfigured → any WISA presence counts as ours', () {
      // No managed-school flags anywhere: pre-#134 behaviour, every WISA-present
      // student is ours.
      final a = linkStudentIn(2).accounts.single;
      expect(a.wisaPresence, WisaPresence.ours);
      expect(a.isInOurWisa, isTrue);
      expect(a.hasLeftOurSchool, isFalse);
    });

    test('present in a managed school (explicit set) → ours', () {
      final a = linkStudentIn(1, ourSchoolIds: {1}).accounts.single;
      expect(a.wisaPresence, WisaPresence.ours);
      expect(a.isInOurWisa, isTrue);
    });

    test('present only in a sibling group school → groupOnly, has left ours',
        () {
      final a = linkStudentIn(2, ourSchoolIds: {1}).accounts.single;
      expect(a.wisaPresence, WisaPresence.groupOnly);
      expect(a.isInOurWisa, isFalse);
      expect(a.hasLeftOurSchool, isTrue);
      // Still in the group ⇒ not a group-departure.
      expect(a.hasLeftGroup, isFalse);
    });

    test('the managed-school set is derived from WisaSchool.isOurs by default',
        () {
      // No explicit ourSchoolIds: the snapshot's own isOurs flags decide.
      final ours = linkStudentIn(
        1,
        schools: [wisaSchool(1, ours: true), wisaSchool(2)],
      ).accounts.single;
      expect(ours.wisaPresence, WisaPresence.ours);

      final sibling = linkStudentIn(
        2,
        schools: [wisaSchool(1, ours: true), wisaSchool(2)],
      ).accounts.single;
      expect(sibling.wisaPresence, WisaPresence.groupOnly);
    });

    test('a WISA-absent (Azure-only) record is classified absent', () {
      final snapshot = link(
        wisaSnap(const [], schools: [wisaSchool(1, ours: true)]),
        ssSnap(const []),
        azSnap([azureUser(id: 'az-9', upn: 'gone@s.be', companyName: _prefix)]),
        SeqResolver(),
        schoolPrefix: _prefix,
      );
      final a = snapshot.accounts.single;
      expect(a.wisaPresence, WisaPresence.absent);
      expect(a.wisaSchoolIds, isEmpty);
      expect(a.hasLeftGroup, isTrue);
    });
  });
}
