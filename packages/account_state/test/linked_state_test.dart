import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime _d = DateTime.utc(2026);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

wapi.WisaStudent _wStudent({
  required String wisaId,
  String classGroup = '',
  String classSubGroup = '',
  int schoolId = 1,
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: classSubGroup,
      name: 'Doe',
      firstName: 'Jane',
      preferredName: '',
      birthDate: _d,
      stemId: '',
      gender: core.Gender.female,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: _addr,
      classChange: _d,
      schoolId: schoolId,
    );

ss.SmartschoolAccount _ssAccount({
  required String uid,
  required String accountId,
  required String mail,
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: core.PersonRole.student,
      givenName: 'Jane',
      surname: 'Doe',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: _addr,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
    );

az.AzureUser _azUser({
  required String id,
  required String upn,
  String? employeeId,
  String companyName = 'GBS',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      companyName: companyName,
    );

core.Group _ssGroup(
  String name, {
  String? code,
  bool official = true,
  core.GroupType type = core.GroupType.classGroup,
}) =>
    core.Group(
      id: core.GroupId(code ?? name),
      name: name,
      description: '',
      type: type,
      official: official,
      origin: core.Origin.smartschool,
    );

ss.SmartschoolMembership _member(String uid, String groupCode) =>
    ss.SmartschoolMembership(uid: uid, groupId: core.GroupId(groupCode));

wapi.WisaClassGroup _wClass(
  String name, {
  String groupName = '00',
  String adminCode = '',
  String schoolCode = '123',
  int schoolId = 1,
}) =>
    wapi.WisaClassGroup(
      name: name,
      groupName: groupName,
      description: '',
      adminCode: adminCode,
      schoolCode: schoolCode,
      schoolId: schoolId,
    );

wapi.WisaSnapshot _wSnap({
  List<wapi.WisaStudent> students = const [],
  List<wapi.WisaClassGroup> classGroups = const [],
}) =>
    wapi.WisaSnapshot(
      fetchedAt: _d,
      students: students,
      staff: const [],
      classGroups: classGroups,
      schools: const [],
    );

ss.SmartschoolSnapshot _sSnap({
  List<core.Group> groups = const [],
  List<ss.SmartschoolAccount> accounts = const [],
  List<ss.SmartschoolMembership> memberships = const [],
}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: _d,
      groups: groups,
      accounts: accounts,
      memberships: memberships,
    );

az.AzureSnapshot _aSnap({List<az.AzureUser> users = const []}) =>
    az.AzureSnapshot(fetchedAt: _d, users: users, groups: const []);

core.LinkedAccount _linkedStudent({
  required String wisaId,
  String classGroup = '',
  String? ssUid,
}) =>
    core.LinkedAccount(
      id: const core.LinkedAccountId('p0'),
      role: core.PersonRole.student,
      wisa: _wStudent(wisaId: wisaId, classGroup: classGroup),
      smartschool: ssUid == null
          ? null
          : _ssAccount(uid: ssUid, accountId: wisaId, mail: '$ssUid@x'),
      confidence: core.LinkConfidence.medium,
    );

core.LinkedGroup _linkedWisaGroup(String fullName) => core.LinkedGroup(
      wisa: core.Group(
        id: core.GroupId(fullName),
        name: fullName,
        description: '',
        type: core.GroupType.classGroup,
        official: true,
        origin: core.Origin.wisa,
      ),
      confidence: core.LinkConfidence.medium,
    );

/// Deterministic in-memory [PersonIdResolver] (mirrors the linker's fixture).
class _SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

/// A [PreparablePersonIdResolver] stand-in (the shape of the DB-backed one):
/// [resolve] is total and throws for any key not [prepare]d, so a test proves
/// the async link path primes exactly the keys the pure pass will resolve.
class _PreparableResolver implements core.PreparablePersonIdResolver {
  final Map<String, String> _cache = {};
  final List<Set<String>> prepareCalls = [];

  @override
  Future<void> prepare(Iterable<String> naturalKeys) async {
    prepareCalls.add(naturalKeys.toSet());
    for (final key in naturalKeys) {
      _cache.putIfAbsent(key, () => 'db${_cache.length}');
    }
  }

  @override
  core.PersonId resolve(String naturalKey) {
    final id = _cache[naturalKey];
    if (id == null) {
      throw StateError('resolve("$naturalKey") before prepare');
    }
    return core.PersonId(id);
  }
}

final _studentConfig =
    StudentActionConfig(schoolPrefix: 'GBS', azureDomain: 'school.example');
final _staffConfig =
    StaffActionConfig(schoolPrefix: 'GBS', azureDomain: 'school.example');

SystemState<S> _sys<S extends core.Snapshot>(core.Origin o, S? initial) =>
    SystemState<S>(
      system: o,
      syncer: (_) async => initial as S,
      initial: initial,
    );

void main() {
  group('PlacementResolver.classPlacementFor', () {
    test('appends the sub-group to the class name when the class uses them',
        () {
      final resolver = PlacementResolver(
        wisa: _wSnap(
          students: [
            _wStudent(wisaId: '1', classGroup: '1A', classSubGroup: 'A'),
          ],
          classGroups: [
            _wClass('1A', groupName: 'A', adminCode: 'a1'),
            _wClass('1A', groupName: 'B', adminCode: 'a2'),
          ],
        ),
        smartschool: _sSnap(),
      );

      final placement = resolver.classPlacementFor(_linkedStudent(wisaId: '1'));

      expect(placement.className, '1A A');
    });

    test('uses the bare class name when the class has a single admin code', () {
      final resolver = PlacementResolver(
        wisa: _wSnap(
          students: [
            _wStudent(wisaId: '1', classGroup: '3C', classSubGroup: 'x'),
          ],
          classGroups: [_wClass('3C', adminCode: 'c1')],
        ),
        smartschool: _sSnap(),
      );

      final placement = resolver.classPlacementFor(_linkedStudent(wisaId: '1'));

      expect(placement.className, '3C');
    });

    test('currentClass is the student\'s official-class membership', () {
      final resolver = PlacementResolver(
        wisa: _wSnap(students: [_wStudent(wisaId: '1', classGroup: '3C')]),
        smartschool: _sSnap(
          groups: [
            _ssGroup('2B', code: '2B_ss'),
            _ssGroup('Leerlingen',
                code: 'org', official: false, type: core.GroupType.group),
          ],
          memberships: [_member('jane', 'org'), _member('jane', '2B_ss')],
        ),
      );

      final placement = resolver.classPlacementFor(
        _linkedStudent(wisaId: '1', classGroup: '3C', ssUid: 'jane'),
      );

      expect(placement.currentClass?.name, '2B');
      expect(placement.currentClassName, '2B');
      expect(placement.className, '3C');
    });

    test('resolveClass finds any group by name across the whole tree', () {
      final resolver = PlacementResolver(
        wisa: _wSnap(),
        smartschool: _sSnap(
          groups: [
            _ssGroup('Leerlingen',
                code: 'root', official: false, type: core.GroupType.group),
            _ssGroup('1A', code: '1A_ss'),
          ],
        ),
      );

      final placement = resolver.classPlacementFor(_linkedStudent(wisaId: 'x'));

      expect(placement.resolveClass('1A')?.id.value, '1A_ss');
      expect(placement.resolveClass('Leerlingen')?.id.value, 'root');
      expect(placement.resolveClass('nope'), isNull);
    });
  });

  group('PlacementResolver.groupPlacementFor', () {
    test('populated WISA class → containsStudents + resolved grade parent', () {
      final resolver = PlacementResolver(
        wisa: _wSnap(
          students: [_wStudent(wisaId: '1', classGroup: '1A')],
          classGroups: [_wClass('1A', adminCode: 'a1')],
        ),
        smartschool: _sSnap(
          groups: [
            _ssGroup('Eerste graad',
                code: 'G1', official: false, type: core.GroupType.group),
          ],
        ),
        classTree: const SmartschoolClassTree(grades: ['G1', 'G2', 'G3']),
      );

      final placement = resolver.groupPlacementFor(_linkedWisaGroup('1A'));

      expect(placement.containsStudents, isTrue);
      expect(placement.parent?.id.value, 'G1');
    });

    test('empty WISA class → containsStudents false (parent still resolves)',
        () {
      final resolver = PlacementResolver(
        wisa: _wSnap(
          students: [_wStudent(wisaId: '1', classGroup: '1A')],
          classGroups: [_wClass('2B', adminCode: 'b1')],
        ),
        smartschool: _sSnap(
          groups: [
            _ssGroup('Eerste graad',
                code: 'G1', official: false, type: core.GroupType.group),
          ],
        ),
        classTree: const SmartschoolClassTree(grades: ['G1', 'G2', 'G3']),
      );

      final placement = resolver.groupPlacementFor(_linkedWisaGroup('2B'));

      expect(placement.containsStudents, isFalse);
      expect(placement.parent?.id.value, 'G1', reason: 'year 2 → first grade');
    });

    test('per-year scheme resolves the year code', () {
      final resolver = PlacementResolver(
        wisa: _wSnap(classGroups: [_wClass('4D', adminCode: 'd1')]),
        smartschool: _sSnap(
          groups: [
            _ssGroup('Vierde jaar',
                code: 'Y4', official: false, type: core.GroupType.group),
          ],
        ),
        classTree: const SmartschoolClassTree(
          years: ['Y1', 'Y2', 'Y3', 'Y4', 'Y5', 'Y6', 'Y7'],
        ),
      );

      final placement = resolver.groupPlacementFor(_linkedWisaGroup('4D'));

      expect(placement.parent?.id.value, 'Y4');
    });

    test('parent is null when the class year is out of range', () {
      final resolver = PlacementResolver(
        wisa: _wSnap(classGroups: [_wClass('KA', adminCode: 'k1')]),
        smartschool: _sSnap(),
        classTree: const SmartschoolClassTree(path: 'P'),
      );

      expect(resolver.groupPlacementFor(_linkedWisaGroup('KA')).parent, isNull);
    });

    test('parent is null when the resolved code is absent from the tree', () {
      final resolver = PlacementResolver(
        wisa: _wSnap(classGroups: [_wClass('1A', adminCode: 'a1')]),
        smartschool: _sSnap(),
        classTree: const SmartschoolClassTree(grades: ['G1', 'G2', 'G3']),
      );

      expect(resolver.groupPlacementFor(_linkedWisaGroup('1A')).parent, isNull);
    });
  });

  group('LinkedState wires placementFor into the dispatchers', () {
    test('group create actions surface only with the placement callback', () {
      final wisa = _wSnap(
        students: [_wStudent(wisaId: '1', classGroup: '1A')],
        classGroups: [
          _wClass('1A', adminCode: 'a1'),
          _wClass('2B', adminCode: 'b1'),
        ],
      );
      final smartschool = _sSnap(
        groups: [
          _ssGroup('Eerste graad',
              code: 'G1', official: false, type: core.GroupType.group),
        ],
      );

      final state = LinkedState.recompute(
        wisa: wisa,
        smartschool: smartschool,
        azure: _aSnap(),
        resolver: _SeqResolver(),
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
        classTree: const SmartschoolClassTree(grades: ['G1', 'G2', 'G3']),
      );

      // 1A holds a student → AddToSmartschool; 2B is empty → CreateInSmartschool.
      expect(state.groupActions.whereType<AddToSmartschool>(), hasLength(1));
      expect(state.groupActions.whereType<CreateInSmartschool>(), hasLength(1));

      // Without the placement callback the dispatch cannot answer "does the
      // WISA class have students?" so neither create action is considered.
      final unwired = groupActions(state.snapshot);
      expect(unwired.whereType<AddToSmartschool>(), isEmpty);
      expect(unwired.whereType<CreateInSmartschool>(), isEmpty);
    });

    test(
        'MoveToSmartschoolClassGroup surfaces only with the placement callback',
        () {
      final wisa = _wSnap(students: [_wStudent(wisaId: '1', classGroup: '3C')]);
      final smartschool = _sSnap(
        groups: [_ssGroup('2B', code: '2B_ss')],
        accounts: [
          _ssAccount(uid: 'jane', accountId: '1', mail: 'jane@school.example'),
        ],
        memberships: [_member('jane', '2B_ss')],
      );
      final azure = _aSnap(
        users: [
          _azUser(id: 'az1', upn: 'jane@school.example', employeeId: '1'),
        ],
      );

      final state = LinkedState.recompute(
        wisa: wisa,
        smartschool: smartschool,
        azure: azure,
        resolver: _SeqResolver(),
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
      );

      // The student is complete but WISA says 3C while Smartschool has them in
      // 2B → a class move is due, and it needs the membership placement.
      expect(
        state.studentActions.whereType<MoveToSmartschoolClassGroup>(),
        hasLength(1),
      );

      final unwired = studentActions(state.snapshot, _studentConfig);
      expect(
        unwired.whereType<MoveToSmartschoolClassGroup>(),
        isEmpty,
      );
    });
  });

  group('group actions are scoped to the schools we manage (#205)', () {
    /// Recomputes over [classGroups] + [students] with the managed-school set
    /// pinned to [ourSchoolIds] — the Settings-derived path the app wires.
    LinkedState recompute({
      required List<wapi.WisaClassGroup> classGroups,
      required List<wapi.WisaStudent> students,
      Set<int>? ourSchoolIds,
    }) =>
        LinkedState.recompute(
          wisa: _wSnap(students: students, classGroups: classGroups),
          smartschool: _sSnap(),
          azure: _aSnap(),
          resolver: _SeqResolver(),
          studentConfig: _studentConfig,
          staffConfig: _staffConfig,
          classTree: const SmartschoolClassTree(grades: ['G1', 'G2', 'G3']),
          ourSchoolIds: ourSchoolIds,
        );

    test(
        'a populated class of a school we manage still raises AddToSmartschool',
        () {
      final state = recompute(
        classGroups: [_wClass('1A', adminCode: 'a1', schoolId: 1)],
        students: [_wStudent(wisaId: '1', classGroup: '1A')],
        ourSchoolIds: const {1},
      );

      expect(state.groupActions.whereType<AddToSmartschool>(), hasLength(1));
    });

    test('a populated class of a school we do not manage raises nothing', () {
      final state = recompute(
        classGroups: [_wClass('9Z', adminCode: 'z1', schoolId: 2)],
        students: [_wStudent(wisaId: '2', classGroup: '9Z', schoolId: 2)],
        ourSchoolIds: const {1},
      );

      expect(state.snapshot.groups, isEmpty);
      expect(state.groupActions, isEmpty,
          reason: 'we have no business creating another school\'s class');
    });

    test('a foreign class sharing a name does not shadow ours in the action',
        () {
      // The sibling school's 1A arrives first; the action must still describe
      // *our* 1A (institute number 111), not the one we do not manage.
      final state = recompute(
        classGroups: [
          _wClass('1A', adminCode: 'a2', schoolCode: '222', schoolId: 2),
          _wClass('1A', adminCode: 'a1', schoolCode: '111', schoolId: 1),
        ],
        students: [_wStudent(wisaId: '1', classGroup: '1A')],
        ourSchoolIds: const {1},
      );

      final action = state.groupActions.whereType<AddToSmartschool>().single;
      expect(action.target.wisa!.instituteNumber, '111');
    });
  });

  group('LinkedState.fromApplication', () {
    test('links from the three current snapshots', () {
      final app = ApplicationState(
        wisa: _sys(
          core.Origin.wisa,
          _wSnap(students: [_wStudent(wisaId: '1', classGroup: '1A')]),
        ),
        smartschool: _sys(core.Origin.smartschool, _sSnap()),
        azure: _sys(core.Origin.azure, _aSnap()),
      );

      final state = LinkedState.fromApplication(
        app,
        resolver: _SeqResolver(),
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
      );

      expect(state.snapshot.accounts, hasLength(1));
    });

    test('throws when a system has not synced yet', () {
      final app = ApplicationState(
        wisa: _sys(core.Origin.wisa, _wSnap()),
        smartschool: _sys(core.Origin.smartschool, _sSnap()),
        azure: _sys<az.AzureSnapshot>(core.Origin.azure, null),
      );

      expect(
        () => LinkedState.fromApplication(
          app,
          resolver: _SeqResolver(),
          studentConfig: _studentConfig,
          staffConfig: _staffConfig,
        ),
        throwsStateError,
      );
    });
  });

  group('LinkedState async path primes a PreparablePersonIdResolver', () {
    test('recomputeAsync prepares the natural keys before linking', () async {
      final resolver = _PreparableResolver();
      final wisa = _wSnap(students: [_wStudent(wisaId: '1', classGroup: '1A')]);

      // A DB-backed resolver throws on an unprepared key, so this only succeeds
      // if recomputeAsync primed the key set before running the pure link().
      final state = await LinkedState.recomputeAsync(
        wisa: wisa,
        smartschool: _sSnap(),
        azure: _aSnap(),
        resolver: resolver,
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
      );

      expect(state.snapshot.accounts, hasLength(1));
      expect(resolver.prepareCalls, hasLength(1));
      expect(resolver.prepareCalls.single, contains('wisa:1'));
      expect(state.snapshot.accounts.single.id.value, startsWith('db'));
    });

    test('fromApplicationAsync primes from an ApplicationState', () async {
      final resolver = _PreparableResolver();
      final app = ApplicationState(
        wisa: _sys(
          core.Origin.wisa,
          _wSnap(students: [_wStudent(wisaId: '1', classGroup: '1A')]),
        ),
        smartschool: _sys(core.Origin.smartschool, _sSnap()),
        azure: _sys(core.Origin.azure, _aSnap()),
      );

      final state = await LinkedState.fromApplicationAsync(
        app,
        resolver: resolver,
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
      );

      expect(state.snapshot.accounts, hasLength(1));
      expect(resolver.prepareCalls.single, contains('wisa:1'));
    });

    test('fromApplicationAsync still guards on an unsynced system', () {
      final app = ApplicationState(
        wisa: _sys(core.Origin.wisa, _wSnap()),
        smartschool: _sys(core.Origin.smartschool, _sSnap()),
        azure: _sys<az.AzureSnapshot>(core.Origin.azure, null),
      );

      expect(
        LinkedState.fromApplicationAsync(
          app,
          resolver: _PreparableResolver(),
          studentConfig: _studentConfig,
          staffConfig: _staffConfig,
        ),
        throwsStateError,
      );
    });

    test('a non-preparable resolver skips prepare and links unchanged',
        () async {
      // recomputeAsync must stay a drop-in for a file/in-memory resolver: no
      // prepare capability, mints lazily inside resolve, same result.
      final state = await LinkedState.recomputeAsync(
        wisa: _wSnap(students: [_wStudent(wisaId: '1', classGroup: '1A')]),
        smartschool: _sSnap(),
        azure: _aSnap(),
        resolver: _SeqResolver(),
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
      );
      expect(state.snapshot.accounts, hasLength(1));
      expect(state.snapshot.accounts.single.id.value, startsWith('p'));
    });
  });
}
