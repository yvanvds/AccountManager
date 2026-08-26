import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

// ---------------------------------------------------------------------------
// Snapshot builders
// ---------------------------------------------------------------------------

core.Group _group(
  String code,
  String name, {
  String? parent,
  bool official = false,
  core.GroupType type = core.GroupType.group,
}) =>
    core.Group(
      id: core.GroupId(code),
      name: name,
      description: name,
      type: type,
      official: official,
      parentId: parent == null ? null : core.GroupId(parent),
      origin: core.Origin.smartschool,
    );

SmartschoolAccount _account(
  String uid, {
  core.PersonRole? role = core.PersonRole.teacher,
  String surname = 'Peeters',
  String givenName = 'Ann',
  String accountId = '',
}) =>
    SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: '$uid@school.be',
      registerId: '',
      stemId: 0,
      role: role,
      givenName: givenName,
      surname: surname,
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: const core.Address(
        street: '',
        houseNumber: '',
        postalCode: '',
        city: '',
        country: '',
      ),
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
    );

SmartschoolMembership _member(String uid, String code) =>
    SmartschoolMembership(uid: uid, groupId: core.GroupId(code));

/// The school's tree, reduced to the nodes this audit reasons about: a student
/// root with a class under it, a staff root with two staff groups under it, and
/// two unrelated roots an operator seats people in by hand.
List<core.Group> _tree() => [
      _group('LLN', 'Leerlingen'),
      _group('SSM1A', '1A',
          parent: 'LLN', official: true, type: core.GroupType.classGroup),
      _group('PER', 'Personeel'),
      _group('LKR', 'Leerkrachten', parent: 'PER'),
      _group('DIR', 'Directie', parent: 'PER'),
      _group('Stagiairs', 'Stagiairs'),
      _group('BEH', 'Beheerders'),
    ];

SmartschoolSnapshot _snapshot({
  List<core.Group>? groups,
  required List<SmartschoolAccount> accounts,
  required List<SmartschoolMembership> memberships,
}) =>
    SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026, 8, 26),
      groups: groups ?? _tree(),
      accounts: accounts,
      memberships: memberships,
    );

// ---------------------------------------------------------------------------
// Fake transport: records every call, answers writes with a configurable code.
// ---------------------------------------------------------------------------

class _Call {
  _Call(this.method, this.args);
  final String method;
  final Map<String, String> args;
}

class _FakeTransport implements SmartschoolSoapTransport {
  _FakeTransport({this.writeResults = const {}, this.throwOn = const {}});

  /// Per-method override for the integer result of write operations.
  final Map<String, int> writeResults;

  /// Methods that fail at the transport level instead of answering.
  final Set<String> throwOn;

  final List<_Call> calls = [];

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final method = XmlDocument.parse(envelope)
        .rootElement
        .childElements
        .first // Body
        .childElements
        .first; // method
    final name = method.name.local;
    calls.add(
      _Call(name, {
        for (final a in method.childElements) a.name.local: a.innerText,
      }),
    );
    if (throwOn.contains(name)) {
      throw SmartschoolSoapHttpException(500, 'boom');
    }

    final b = XmlBuilder();
    b.element(
      'soap:Envelope',
      namespaces: {
        'http://schemas.xmlsoap.org/soap/envelope/': 'soap',
        'http://www.w3.org/2001/XMLSchema-instance': 'xsi',
      },
      nest: () => b.element(
        'soap:Body',
        nest: () => b.element(
          '${name}Response',
          nest: () => b.element(
            'return',
            nest: () {
              b.attribute(
                'type',
                'xsd:int',
                namespace: 'http://www.w3.org/2001/XMLSchema-instance',
              );
              b.text('${writeResults[name] ?? 0}');
            },
          ),
        ),
      ),
    );
    return b.buildDocument().toXmlString();
  }
}

SmartschoolConnector _connector(_FakeTransport transport) =>
    SmartschoolConnector(
      credentials: const SmartschoolCredentials(
        site: 'school',
        accessCode: 'secret',
      ),
      transport: transport,
      errorCodes: SmartschoolErrorCodes.empty,
    );

void main() {
  group('misSeatedStaffAccounts', () {
    test('flags a teacher left in the default group and in no staff group', () {
      // The #374 footprint exactly: `saveUser` seated the account in the
      // default group node itself, and the two follow-up writes never happened.
      final snapshot = _snapshot(
        accounts: [_account('ann.peeters')],
        memberships: [_member('ann.peeters', 'LLN')],
      );

      final found = misSeatedStaffAccounts(snapshot);

      expect(found, hasLength(1));
      expect(found.single.account.uid, 'ann.peeters');
      expect(found.single.defaultGroup.id.value, 'LLN');
      expect(found.single.otherGroups, isEmpty);
    });

    test('flags a director too — staff is every role but student', () {
      final snapshot = _snapshot(
        accounts: [_account('jos.baert', role: core.PersonRole.director)],
        memberships: [_member('jos.baert', 'LLN')],
      );

      expect(misSeatedStaffAccounts(snapshot), hasLength(1));
    });

    test('ignores a student in the default group', () {
      // Where a student belongs: the student create deliberately leaves them.
      final snapshot = _snapshot(
        accounts: [_account('lies.jans', role: core.PersonRole.student)],
        memberships: [
          _member('lies.jans', 'LLN'),
          _member('lies.jans', 'SSM1A'),
        ],
      );

      expect(misSeatedStaffAccounts(snapshot), isEmpty);
    });

    test('ignores a staff member who also sits under the staff root', () {
      // Seated by an operator on purpose — in `Directie`, not even the staff
      // group the repair writes — so undoing it is not this repair's business.
      final snapshot = _snapshot(
        accounts: [_account('jos.baert', role: core.PersonRole.director)],
        memberships: [
          _member('jos.baert', 'LLN'),
          _member('jos.baert', 'DIR'),
        ],
      );

      expect(misSeatedStaffAccounts(snapshot), isEmpty);
    });

    test('ignores a correctly seated staff member', () {
      final snapshot = _snapshot(
        accounts: [_account('ann.peeters')],
        memberships: [_member('ann.peeters', 'LKR')],
      );

      expect(misSeatedStaffAccounts(snapshot), isEmpty);
    });

    test('ignores a staff member who is not in the default group at all', () {
      // A beheerder or stagiair account: not ours to move, and nothing to
      // remove them from.
      final snapshot = _snapshot(
        accounts: [_account('yvanadmin'), _account('nils.jacquet')],
        memberships: [
          _member('yvanadmin', 'BEH'),
          _member('nils.jacquet', 'Stagiairs'),
        ],
      );

      expect(misSeatedStaffAccounts(snapshot), isEmpty);
    });

    test('ignores an account whose Basisrol Smartschool did not map', () {
      // `role == null` means the connector could not read the role. Claiming
      // it is staff would add a possible student to the staff group.
      final snapshot = _snapshot(
        accounts: [_account('mystery', role: null)],
        memberships: [_member('mystery', 'LLN')],
      );

      expect(misSeatedStaffAccounts(snapshot), isEmpty);
    });

    test('reports the other groups a mis-seated account sits in', () {
      final snapshot = _snapshot(
        accounts: [_account('felien.cockx')],
        memberships: [
          _member('felien.cockx', 'LLN'),
          _member('felien.cockx', 'Stagiairs'),
        ],
      );

      final found = misSeatedStaffAccounts(snapshot);

      expect(found, hasLength(1));
      expect(
        found.single.otherGroups.map((g) => g.name),
        ['Stagiairs'],
      );
    });

    test('matches the group names the way the rest of the port does', () {
      // `normalizeGroupName` (#225): case- and whitespace-tolerant, because
      // both sides of this comparison are operator-typed.
      final snapshot = _snapshot(
        groups: [
          _group('LLN', '  leerlingen '),
          _group('PER', 'PERSONEEL'),
          _group('LKR', 'Leerkrachten', parent: 'PER'),
        ],
        accounts: [_account('ann.peeters')],
        memberships: [_member('ann.peeters', 'LLN')],
      );

      expect(misSeatedStaffAccounts(snapshot), hasLength(1));
    });

    test('a namesake default group deeper in the tree seats just as much', () {
      final snapshot = _snapshot(
        groups: [
          _group('LLN', 'Leerlingen'),
          _group('GR1', '1ste Graad', parent: 'LLN'),
          _group('LLN2', 'Leerlingen', parent: 'GR1'),
          _group('PER', 'Personeel'),
          _group('LKR', 'Leerkrachten', parent: 'PER'),
        ],
        accounts: [_account('ann.peeters')],
        memberships: [_member('ann.peeters', 'LLN2')],
      );

      final found = misSeatedStaffAccounts(snapshot);

      expect(found, hasLength(1));
      expect(found.single.defaultGroup.id.value, 'LLN2');
    });

    test('a staff group nested two levels down still counts as staff-side', () {
      final snapshot = _snapshot(
        groups: [
          _group('LLN', 'Leerlingen'),
          _group('PER', 'Personeel'),
          _group('LKR', 'Leerkrachten', parent: 'PER'),
          // Declared *before* its parent: the flattened tree is in no
          // guaranteed order, and the subtree walk must not depend on one.
          _group('LKR1A', 'Klastitularissen', parent: 'LKR'),
        ],
        accounts: [_account('ann.peeters')],
        memberships: [
          _member('ann.peeters', 'LLN'),
          _member('ann.peeters', 'LKR1A'),
        ],
      );

      expect(misSeatedStaffAccounts(snapshot), isEmpty);
    });

    test('finds nothing when the tree carries no default group', () {
      final snapshot = _snapshot(
        groups: [
          _group('PER', 'Personeel'),
          _group('LKR', 'Leerkrachten', parent: 'PER'),
        ],
        accounts: [_account('ann.peeters')],
        memberships: [_member('ann.peeters', 'LKR')],
      );

      expect(misSeatedStaffAccounts(snapshot), isEmpty);
    });

    test('an unnamed staff root leaves every seated staff account flagged', () {
      // The fail-loud direction: a tenant whose staff root is named otherwise
      // gets a long list to eyeball, never a silent empty one.
      final snapshot = _snapshot(
        accounts: [_account('ann.peeters')],
        memberships: [
          _member('ann.peeters', 'LLN'),
          _member('ann.peeters', 'LKR'),
        ],
      );

      expect(
        misSeatedStaffAccounts(snapshot, staffRootName: 'Medewerkers'),
        hasLength(1),
      );
    });

    test('returns the accounts in snapshot order', () {
      final snapshot = _snapshot(
        accounts: [
          _account('b.een'),
          _account('a.twee'),
          _account('c.drie'),
        ],
        memberships: [
          _member('a.twee', 'LLN'),
          _member('c.drie', 'LLN'),
          _member('b.een', 'LLN'),
        ],
      );

      expect(
        misSeatedStaffAccounts(snapshot).map((r) => r.account.uid),
        ['b.een', 'a.twee', 'c.drie'],
      );
    });
  });

  group('resolveStaffGroup', () {
    test('resolves the staff group by name', () {
      final snapshot = _snapshot(accounts: const [], memberships: const []);

      expect(resolveStaffGroup(snapshot)?.id.value, 'LKR');
    });

    test('is null when the tree carries no such group', () {
      final snapshot = _snapshot(
        groups: [_group('LLN', 'Leerlingen')],
        accounts: const [],
        memberships: const [],
      );

      expect(resolveStaffGroup(snapshot), isNull);
    });
  });

  group('repairStaffSeating', () {
    late _FakeTransport transport;

    List<MisSeatedStaffAccount> found() => misSeatedStaffAccounts(
          _snapshot(
            accounts: [_account('ann.peeters')],
            memberships: [_member('ann.peeters', 'LLN')],
          ),
        );

    test('issues #374\'s two seat writes, add first, per account', () {
      transport = _FakeTransport();

      return repairStaffSeating(
        _connector(transport),
        found(),
        staffGroup: _group('LKR', 'Leerkrachten', parent: 'PER'),
      ).then((results) {
        expect(results, hasLength(1));
        expect(results.single.repaired, isTrue);
        expect(results.single.problems, isEmpty);

        expect(
          transport.calls.map((c) => c.method),
          [
            SmartschoolMethod.saveUserToClassesAndGroups,
            SmartschoolMethod.removeUserFromGroup,
          ],
        );
        // Addressed by **code** — that is what `saveUserToClassesAndGroups`
        // takes — and keeping the account's existing memberships.
        expect(transport.calls.first.args['userIdentifier'], 'ann.peeters');
        expect(transport.calls.first.args['csvList'], 'LKR');
        expect(transport.calls.first.args['keepOld'], '1');
        // Addressed by **name** — that is what `removeUserFromGroup` takes.
        expect(transport.calls.last.args['userIdentifier'], 'ann.peeters');
        expect(transport.calls.last.args['class'], 'Leerlingen');
      });
    });

    test('removes from the default group even when the add was refused', () {
      // The two writes are independent: leaving a teacher in the student
      // subtree is the worse half of the same bug.
      transport = _FakeTransport(
        writeResults: const {SmartschoolMethod.saveUserToClassesAndGroups: 5},
      );

      return repairStaffSeating(
        _connector(transport),
        found(),
        staffGroup: _group('LKR', 'Leerkrachten', parent: 'PER'),
      ).then((results) {
        final result = results.single;
        expect(result.joined, isFalse);
        expect(result.left, isTrue);
        expect(result.repaired, isFalse);
        expect(result.problems, hasLength(1));
        expect(result.problems.single, contains('refused to add'));
        expect(
          transport.calls.map((c) => c.method),
          contains(SmartschoolMethod.removeUserFromGroup),
        );
      });
    });

    test('a transport failure becomes a problem, not an exception', () async {
      transport = _FakeTransport(
        throwOn: const {SmartschoolMethod.removeUserFromGroup},
      );

      final results = await repairStaffSeating(
        _connector(transport),
        found(),
        staffGroup: _group('LKR', 'Leerkrachten', parent: 'PER'),
      );

      final result = results.single;
      expect(result.joined, isTrue);
      expect(result.left, isFalse);
      expect(result.problems.single, contains('failed'));
    });

    test('an unresolved staff group still empties the default group', () async {
      final results = await repairStaffSeating(
        _connector(transport = _FakeTransport()),
        found(),
        staffGroup: null,
      );

      final result = results.single;
      expect(result.joined, isFalse);
      expect(result.left, isTrue);
      expect(result.problems.single, contains('Leerkrachten'));
      // No add was attempted: there is no code to address.
      expect(
        transport.calls.map((c) => c.method),
        [SmartschoolMethod.removeUserFromGroup],
      );
    });

    test('an official staff group is refused without a write', () async {
      // Smartschool refuses group members on an official class; legacy guards
      // it in `AddUserToGroup` and the ported connector leaves it to the caller.
      final results = await repairStaffSeating(
        _connector(transport = _FakeTransport()),
        found(),
        staffGroup: _group('LKR', 'Leerkrachten',
            parent: 'PER', official: true, type: core.GroupType.classGroup),
      );

      expect(results.single.joined, isFalse);
      expect(results.single.problems.single, contains('official class'));
      expect(
        transport.calls.map((c) => c.method),
        [SmartschoolMethod.removeUserFromGroup],
      );
    });

    test('one failing account does not abandon the rest of the batch',
        () async {
      transport = _FakeTransport();
      final batch = misSeatedStaffAccounts(
        _snapshot(
          accounts: [_account('een'), _account('twee'), _account('drie')],
          memberships: [
            _member('een', 'LLN'),
            _member('twee', 'LLN'),
            _member('drie', 'LLN'),
          ],
        ),
      );

      final results = await repairStaffSeating(
        _connector(transport),
        batch,
        staffGroup: _group('LKR', 'Leerkrachten', parent: 'PER'),
      );

      expect(results.map((r) => r.uid), ['een', 'twee', 'drie']);
      expect(results.every((r) => r.repaired), isTrue);
      expect(transport.calls, hasLength(6));
    });
  });
}
