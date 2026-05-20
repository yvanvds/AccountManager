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
}
