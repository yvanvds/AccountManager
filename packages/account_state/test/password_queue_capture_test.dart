import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

/// Covers #105: an apply that **creates** an account drops the password it
/// minted into the shared [PasswordQueueStore], keyed by person, with Azure and
/// Smartschool creates merging onto one [PasswordEntry] (legacy one sheet per
/// student). Every other action leaves the queue untouched.

final DateTime _d = DateTime.utc(2026);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

// ---------------------------------------------------------------------------
// Fakes: a SOAP transport whose every write succeeds, and a Graph transport
// that answers the create path — an empty `employeeId in (…)` collection to the
// duplicate-account guard (#224), 404 to the pre-create UPN-existence probe (so
// `createPrincipalName` takes the first candidate), and 201 with an id echo to
// the POST that creates the user.
// ---------------------------------------------------------------------------

class _OkSoap implements ss.SmartschoolSoapTransport {
  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async =>
      '<?xml version="1.0" encoding="utf-8"?>'
      '<soap:Envelope '
      'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
      '<soap:Body><response><return>0</return></response>'
      '</soap:Body></soap:Envelope>';
}

class _CreatingGraph implements az.GraphTransport {
  int _created = 0;

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    if (request.method == 'POST') {
      _created++;
      return az.GraphResponse(
        statusCode: 201,
        body: '{"id":"az-created-$_created"}',
      );
    }
    // The duplicate guard's lookup (#224): a `$filter` query never 404s — it
    // answers with an empty collection when the tenant holds no such account.
    if ((request.url.queryParameters[r'$filter'] ?? '')
        .startsWith('employeeId in')) {
      return const az.GraphResponse(
        statusCode: 200,
        headers: {'content-type': 'application/json'},
        body: '{"value":[]}',
      );
    }
    // The UPN-existence probe (GET) — report "not found" so the first
    // candidate UPN is taken.
    return const az.GraphResponse(statusCode: 404);
  }
}

ss.SmartschoolConnector _ssConn() => ss.SmartschoolConnector.fromParts(
      site: 'demo',
      accessCode: 'secret',
      transport: _OkSoap(),
    );

az.AzureConnector _azConn() => az.AzureConnector(
      credentials: az.AzureCredentials(
        clientId: 'c',
        tenantId: 't',
        azureDomain: 'school.example',
        schoolPrefix: 'SSM',
      ),
      authProvider: const az.StaticAuthProvider('token'),
      transport: _CreatingGraph(),
    );

// ---------------------------------------------------------------------------
// Record + snapshot builders.
// ---------------------------------------------------------------------------

wapi.WisaStudent _wStudent({
  String wisaId = 'W1',
  String firstName = 'Jan',
  String name = 'Peeters',
  String classGroup = '3A',
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '00',
      name: name,
      firstName: firstName,
      preferredName: '',
      birthDate: _d,
      stemId: '',
      gender: core.Gender.male,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: _addr,
      classChange: _d,
      schoolId: 1,
    );

ss.SmartschoolAccount _ssAccount({
  String uid = 'jan.peeters',
  String accountId = 'W1',
  String mail = 'jan.peeters@student.school.example',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: core.PersonRole.student,
      givenName: 'Jan',
      surname: 'Peeters',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.male,
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
  String id = 'az-1',
  String upn = 'jan.peeters@student.school.example',
  String employeeId = 'W1',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: 'Jan Peeters',
      givenName: 'Jan',
      surname: 'Peeters',
      companyName: 'SSM',
      department: '3A',
    );

wapi.WisaSnapshot _wSnap({List<wapi.WisaStudent> students = const []}) =>
    wapi.WisaSnapshot(
      fetchedAt: _d,
      students: students,
      staff: const [],
      classGroups: const [],
      schools: const [],
    );

ss.SmartschoolSnapshot _sSnap(
        {List<ss.SmartschoolAccount> accounts = const []}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: _d,
      groups: const [],
      accounts: accounts,
      memberships: const [],
    );

az.AzureSnapshot _aSnap({List<az.AzureUser> users = const []}) =>
    az.AzureSnapshot(fetchedAt: _d, users: users, groups: const []);

core.LinkedAccount _linkedStudent({
  wapi.WisaStudent? wisa,
  ss.SmartschoolAccount? smartschool,
  az.AzureUser? azure,
  String id = 'p0',
}) =>
    core.LinkedAccount(
      id: core.LinkedAccountId(id),
      role: core.PersonRole.student,
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      confidence: core.LinkConfidence.high,
    );

/// Deterministic in-memory [core.PersonIdResolver] (mirrors the linker fixture):
/// the same natural key always maps to the same id.
class _SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

/// One assembled State layer with the password queue wired, and a password
/// generator that mints a distinct value per call so a test can tell the Azure
/// password from the Smartschool one (the two systems deliberately differ).
class _Harness {
  _Harness({
    wapi.WisaSnapshot? wisa,
    ss.SmartschoolSnapshot? smartschool,
    az.AzureSnapshot? azure,
    this.wireQueue = true,
  }) {
    app = ApplicationState(
      wisa: SystemState<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        initial: wisa ?? _wSnap(),
        syncer: (_) async => wisa ?? _wSnap(),
      ),
      smartschool: SystemState<ss.SmartschoolSnapshot>(
        system: core.Origin.smartschool,
        initial: smartschool ?? _sSnap(),
        syncer: (_) async => smartschool ?? _sSnap(),
      ),
      azure: SystemState<az.AzureSnapshot>(
        system: core.Origin.azure,
        initial: azure ?? _aSnap(),
        syncer: (_) async => azure ?? _aSnap(),
      ),
    );
    var n = 0;
    String nextPassword() => 'pw${++n}';
    applier = StateApplier(
      app: app,
      connectors: Connectors(smartschool: _ssConn(), azure: _azConn()),
      resolver: _SeqResolver(),
      wisaRules: WisaImportRules(),
      studentConfig: StudentActionConfig(
        schoolPrefix: 'SSM',
        azureDomain: 'school.example',
        newAccountPassword: nextPassword,
      ),
      staffConfig: StaffActionConfig(
        schoolPrefix: 'SSM',
        azureDomain: 'school.example',
        newAccountPassword: nextPassword,
      ),
      passwordQueue: wireQueue ? queue : null,
    );
  }

  final bool wireQueue;
  final InMemoryPasswordQueueStore queue = InMemoryPasswordQueueStore();
  late final ApplicationState app;
  late final StateApplier applier;
}

void main() {
  group('an account-creating apply captures its password', () {
    test('a Smartschool create enqueues the Smartschool password only',
        () async {
      // WISA + Azure present, Smartschool missing → AddStudentToSmartschool.
      final harness = _Harness(
        wisa: _wSnap(students: [_wStudent()]),
        azure: _aSnap(users: [_azUser()]),
      );
      final target = _linkedStudent(wisa: _wStudent(), azure: _azUser());

      await harness.applier.applyStudent(
        AddStudentToSmartschool(target, harness.applier.studentConfig),
      );

      final entries = await harness.queue.load();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.kind, PasswordAccountKind.account);
      expect(entry.smartschoolPassword, 'pw1');
      expect(entry.azurePassword, isNull);
      expect(entry.accountName, 'jan.peeters');
      expect(entry.displayName, 'Jan Peeters');
      expect(entry.classGroup, '3A');
      expect(entry.mail, 'jan.peeters@student.school.example');
    });

    test(
        "provisioning a new student fills both halves of one sheet from the "
        "operator's single apply (#230)", () async {
      // WISA only — a new intake. The dispatcher offers just AddStudentToAzure,
      // because the Smartschool create needs the Azure UPN as its mail; the
      // State layer then chains that follow-up against the relinked record, so
      // one apply mints two passwords. They belong to the same student, so they
      // must land on one sheet — not two rows (legacy `AccountPassword`).
      final harness = _Harness(wisa: _wSnap(students: [_wStudent()]));
      final target = _linkedStudent(wisa: _wStudent());

      final applied = await harness.applier.applyStudent(
        AddStudentToAzure(target, harness.applier.studentConfig),
      );
      expect(applied.followUps, hasLength(1), reason: 'the chain ran');

      final entries = await harness.queue.load();
      expect(entries, hasLength(1), reason: 'one sheet per student, not two');
      final entry = entries.single;
      expect(entry.kind, PasswordAccountKind.account);
      expect(entry.azurePassword, 'pw1', reason: 'from the Azure create');
      expect(entry.smartschoolPassword, 'pw2',
          reason: 'from the chained Smartschool create — a distinct password');
      expect(entry.displayName, 'Jan Peeters');
      expect(entry.accountName, 'jan.peeters',
          reason: 'the now-known Smartschool uid');
      expect(entry.classGroup, '3A');
    });

    test('a dry-run create enqueues nothing (no write, no password)', () async {
      final harness = _Harness(wisa: _wSnap(students: [_wStudent()]));

      await harness.applier.applyStudent(
        AddStudentToAzure(
          _linkedStudent(wisa: _wStudent()),
          harness.applier.studentConfig,
        ),
        options: ApplyOptions.dry,
      );

      expect(await harness.queue.load(), isEmpty);
    });

    test('a non-creating modify apply enqueues nothing', () async {
      final account = _linkedStudent(
        wisa: _wStudent(),
        smartschool: _ssAccount(accountId: 'OLD'),
        azure: _azUser(),
      );
      final harness = _Harness(
        wisa: _wSnap(students: [_wStudent()]),
        smartschool: _sSnap(accounts: [_ssAccount(accountId: 'OLD')]),
        azure: _aSnap(users: [_azUser()]),
      );

      await harness.applier.applyStudent(
        ModifyAccountId(account, harness.applier.studentConfig),
      );

      expect(await harness.queue.load(), isEmpty);
    });

    test('a create applies cleanly when no queue is wired', () async {
      final harness = _Harness(
        wisa: _wSnap(students: [_wStudent()]),
        wireQueue: false,
      );

      final applied = await harness.applier.applyStudent(
        AddStudentToAzure(
          _linkedStudent(wisa: _wStudent()),
          harness.applier.studentConfig,
        ),
      );

      expect(applied.result.wrote, isTrue);
      // The unwired queue is untouched — no throw, nothing enqueued.
      expect(await harness.queue.load(), isEmpty);
    });
  });
}
