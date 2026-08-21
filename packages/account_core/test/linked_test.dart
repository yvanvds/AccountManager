import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

class _FakeWisaStudent implements WisaStudent {
  @override
  final WisaId wisaId;
  const _FakeWisaStudent(this.wisaId);
}

class _FakeWisaStaff implements WisaStaff {
  @override
  final WisaStaffCode code;
  @override
  final WisaId? wisaId;
  const _FakeWisaStaff(this.code, [this.wisaId]);
}

class _FakeSmartschoolAccount implements SmartschoolAccount {
  @override
  final String uid;
  @override
  final String mail;
  @override
  final String accountId;
  @override
  final AccountType accountType;
  const _FakeSmartschoolAccount({
    required this.uid,
    required this.mail,
    required this.accountId,
    required this.accountType,
  });
}

class _FakeAzureUser implements AzureUser {
  @override
  final String id;
  @override
  final String upn;
  @override
  final String? employeeId;
  const _FakeAzureUser({required this.id, required this.upn, this.employeeId});
}

class _FakeAzureGroup implements AzureGroup {
  @override
  final String id;
  @override
  final String displayName;
  @override
  String? get mail => null;
  @override
  String? get mailNickname => null;
  const _FakeAzureGroup(this.id, this.displayName);
}

void main() {
  test('LinkedAccount holds the three optional per-system records', () {
    const acc = LinkedAccount(
      id: LinkedAccountId('la-1'),
      role: PersonRole.student,
      wisa: _FakeWisaStudent(WisaId('w-1')),
      smartschool: _FakeSmartschoolAccount(
        uid: 'janssens.anna',
        mail: 'anna@school.be',
        accountId: 'w-1',
        accountType: AccountType.student,
      ),
      azure: _FakeAzureUser(
        id: 'az-1',
        upn: 'anna@school.be',
        employeeId: 'w-1',
      ),
      confidence: LinkConfidence.high,
    );
    expect(acc.wisa?.wisaId, equals(const WisaId('w-1')));
    expect(acc.smartschool?.mail, equals('anna@school.be'));
    expect(acc.azure?.upn, equals('anna@school.be'));
    expect(acc.confidence, equals(LinkConfidence.high));
  });

  test('LinkedAccount allows nullable per-system records (alumni / WISA-only)',
      () {
    // Spec §3.9: confidence Medium replaces the implicit "this is alumni or
    // a placeholder" state legacy encoded by which fields happen to be null.
    const alumni = LinkedAccount(
      id: LinkedAccountId('la-2'),
      role: PersonRole.student,
      azure: _FakeAzureUser(id: 'az-2', upn: 'old@school.be'),
      confidence: LinkConfidence.medium,
    );
    expect(alumni.wisa, isNull);
    expect(alumni.smartschool, isNull);
    expect(alumni.azure, isNotNull);
  });

  group('WisaPresence classification getters (#134)', () {
    const wisa = _FakeWisaStudent(WisaId('w-1'));
    const ss = _FakeSmartschoolAccount(
      uid: 'a',
      mail: 'a@s.be',
      accountId: 'w-1',
      accountType: AccountType.student,
    );
    const az = _FakeAzureUser(id: 'az-1', upn: 'a@s.be', employeeId: 'w-1');

    test('present in our WISA → in our WISA, not left', () {
      const acc = LinkedAccount(
        id: LinkedAccountId('la-ours'),
        role: PersonRole.student,
        wisa: wisa,
        smartschool: ss,
        azure: az,
        confidence: LinkConfidence.high,
        wisaSchoolIds: {1},
      );
      expect(acc.isInOurWisa, isTrue);
      expect(acc.hasLeftOurSchool, isFalse);
      expect(acc.hasLeftGroup, isFalse);
      expect(acc.wisaSchoolIds, {1});
    });

    test('moved to a sibling group school → left our school, still in group',
        () {
      const acc = LinkedAccount(
        id: LinkedAccountId('la-group'),
        role: PersonRole.student,
        wisa: wisa,
        smartschool: ss,
        azure: az,
        confidence: LinkConfidence.medium,
        wisaSchoolIds: {2},
        wisaPresence: WisaPresence.groupOnly,
      );
      expect(acc.isInOurWisa, isFalse);
      expect(acc.hasLeftOurSchool, isTrue);
      // Still somewhere in the group ⇒ not a group-departure (Azure is kept).
      expect(acc.hasLeftGroup, isFalse);
    });

    test(
        'no WISA record → gone from the whole group, regardless of the '
        'default presence enum', () {
      // The default WisaPresence.ours must not leak through when there is no
      // WISA record: the getters fold in wisa-nullness.
      const acc = LinkedAccount(
        id: LinkedAccountId('la-absent'),
        role: PersonRole.student,
        azure: az,
        confidence: LinkConfidence.medium,
      );
      expect(acc.wisaPresence, WisaPresence.ours,
          reason: 'the field default, deliberately masked by the getters');
      expect(acc.isInOurWisa, isFalse);
      expect(acc.hasLeftOurSchool, isTrue);
      expect(acc.hasLeftGroup, isTrue);
      expect(acc.wisaSchoolIds, isEmpty);
    });

    test('WisaPresence round-trips through JSON', () {
      for (final p in WisaPresence.values) {
        expect(WisaPresence.fromJson(p.toJson()), p);
      }
    });
  });

  test('LinkedStaff distinguishes from LinkedAccount via WisaStaff', () {
    const staff = LinkedStaff(
      id: LinkedAccountId('ls-1'),
      role: PersonRole.teacher,
      wisa: _FakeWisaStaff(WisaStaffCode('s-1'), WisaId('w-100')),
      confidence: LinkConfidence.high,
    );
    expect(staff.wisa?.code, equals(const WisaStaffCode('s-1')));
    expect(staff.wisa?.wisaId, equals(const WisaId('w-100')));
  });

  test('LinkedGroup ties a WISA group to optional SS/Azure peers', () {
    const wisaGroup = Group(
      id: GroupId('g-wisa'),
      name: '5A',
      description: '',
      type: GroupType.classGroup,
      official: true,
      origin: Origin.wisa,
    );
    const lg = LinkedGroup(
      wisa: wisaGroup,
      azure: _FakeAzureGroup('az-g-1', '5A'),
      confidence: LinkConfidence.high,
    );
    expect(lg.wisa, equals(wisaGroup));
    expect(lg.azure?.displayName, equals('5A'));
    expect(lg.smartschool, isNull);
  });

  test(
      'ResolveDuplicateMail is a LinkWarning carrying the colliding accounts '
      '(INV-23)', () {
    const a = _FakeSmartschoolAccount(
      uid: 'janssens.anna',
      mail: 'anna@school.be',
      accountId: 'w-1',
      accountType: AccountType.student,
    );
    const b = _FakeSmartschoolAccount(
      uid: 'janssens.anna2',
      mail: 'anna@school.be',
      accountId: 'w-2',
      accountType: AccountType.coAccount1,
    );
    const warning =
        ResolveDuplicateMail(mail: 'anna@school.be', accounts: [a, b]);
    expect(warning, isA<LinkWarning>());
    expect(warning.mail, equals('anna@school.be'));
    expect(warning.accounts, hasLength(2));
    expect(
      warning.accounts.map((s) => s.uid),
      containsAll(<String>['janssens.anna', 'janssens.anna2']),
    );
  });

  test('LinkedSnapshot stores records, counts, and warnings (spec §6.2)', () {
    const snapshot = LinkedSnapshot(
      accounts: [],
      staff: [],
      groups: [],
      wisa: LinkCounts.empty,
      smartschool: LinkCounts.empty,
      azure: LinkCounts.empty,
    );
    expect(snapshot.accounts, isEmpty);
    expect(snapshot.warnings, isEmpty);
    expect(snapshot.wisa, equals(LinkCounts.empty));
  });

  test('LinkedSnapshot.fromRecords derives per-system counts like legacy', () {
    // Fully linked student: present in all three systems.
    const full = LinkedAccount(
      id: LinkedAccountId('la-full'),
      role: PersonRole.student,
      wisa: _FakeWisaStudent(WisaId('w-1')),
      smartschool: _FakeSmartschoolAccount(
        uid: 'a',
        mail: 'a@school.be',
        accountId: 'w-1',
        accountType: AccountType.student,
      ),
      azure: _FakeAzureUser(id: 'az-1', upn: 'a@school.be', employeeId: 'w-1'),
      confidence: LinkConfidence.high,
    );
    // WISA-only placeholder.
    const wisaOnly = LinkedAccount(
      id: LinkedAccountId('la-wisa'),
      role: PersonRole.student,
      wisa: _FakeWisaStudent(WisaId('w-2')),
      confidence: LinkConfidence.medium,
    );
    // Azure-only record for someone who has left (the engine will remove it).
    const azureOnly = LinkedAccount(
      id: LinkedAccountId('la-az'),
      role: PersonRole.student,
      azure: _FakeAzureUser(id: 'az-2', upn: 'old@school.be'),
      confidence: LinkConfidence.medium,
    );
    // Fully linked staff member contributes to every system total too.
    const staff = LinkedStaff(
      id: LinkedAccountId('ls-1'),
      role: PersonRole.teacher,
      wisa: _FakeWisaStaff(WisaStaffCode('s-1'), WisaId('w-100')),
      smartschool: _FakeSmartschoolAccount(
        uid: 'staff',
        mail: 'staff@school.be',
        accountId: 'w-100',
        accountType: AccountType.student,
      ),
      azure: _FakeAzureUser(
        id: 'az-100',
        upn: 'staff@school.be',
        employeeId: 'w-100',
      ),
      confidence: LinkConfidence.high,
    );

    final snapshot = LinkedSnapshot.fromRecords(
      accounts: const [full, wisaOnly, azureOnly],
      staff: const [staff],
      groups: const [],
      warnings: const [
        ResolveDuplicateMail(mail: 'dup@school.be', accounts: []),
      ],
    );

    // WISA: full, wisaOnly, staff present (3); only full + staff complete (2).
    expect(snapshot.wisa.total, equals(3));
    expect(snapshot.wisa.linked, equals(2));
    expect(snapshot.wisa.unlinked, equals(1));

    // Smartschool: full + staff present (2), both complete.
    expect(snapshot.smartschool.total, equals(2));
    expect(snapshot.smartschool.linked, equals(2));
    expect(snapshot.smartschool.unlinked, equals(0));

    // Azure: full, azureOnly, staff present (3); full + staff complete (2).
    expect(snapshot.azure.total, equals(3));
    expect(snapshot.azure.linked, equals(2));
    expect(snapshot.azure.unlinked, equals(1));

    // total always equals linked + unlinked.
    for (final c in [snapshot.wisa, snapshot.smartschool, snapshot.azure]) {
      expect(c.total, equals(c.linked + c.unlinked));
    }

    expect(snapshot.warnings, hasLength(1));
    expect(snapshot.warnings.single, isA<ResolveDuplicateMail>());
  });
}
