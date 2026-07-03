/// The three per-system connection profiles of the config model.
///
/// Each profile is the Dart counterpart of a legacy per-system `*State`'s
/// configuration half (PROJECT_OVERVIEW §6.2): the operator-tunable endpoint
/// and options that survive across runs. The loaded domain content those
/// classes also held is **not** here — snapshots are owned by `SystemState`
/// and never persisted in the settings blob.
///
/// Secrets are the sharp edge. The legacy `config.json` stored the WISA
/// password and Smartschool passphrase in cleartext; these profiles instead
/// carry a [SecretRef] naming where the secret lives and resolve the value
/// through a [SecretProvider], so nothing sensitive is ever serialized (see
/// `secret_provider.dart`).
///
/// Every profile is immutable — mutate by [WisaConnection.copyWith] et al. and
/// hand the result to a [SettingsStore] via [AppSettings].
library;

import 'secret_provider.dart';
import 'work_date.dart';

const _wisaPasswordRef = SecretRef('wisa.password');
const _smartschoolPassphraseRef = SecretRef('smartschool.passphrase');

/// WISA connection profile: endpoint, credentials seam, and the work-date pair.
///
/// Mirrors the config half of legacy `WisaState` (server/port/database/user +
/// password, plus the real and virtual [WorkDateSetting]s). The password is
/// resolved through [passwordRef], never stored inline.
class WisaConnection {
  const WisaConnection({
    this.server = '',
    this.port = '',
    this.database = '',
    this.username = '',
    this.passwordRef = _wisaPasswordRef,
    this.workDate = const WorkDateSetting(),
    this.virtualWorkDate = const WorkDateSetting(),
  });

  /// Database host. Legacy `WisaState.Server`.
  final String server;

  /// Database port. Kept as a string (as legacy did) because it is operator
  /// free-text; the connector parses and validates it at connect time.
  final String port;

  /// Database/schema name. Legacy `WisaState.Database`.
  final String database;

  /// Login user. Legacy `WisaState.User`.
  final String username;

  /// Where the WISA password is resolved from. The value never lives on this
  /// object or in the settings blob. Legacy `WisaState.Password` (was inline).
  final SecretRef passwordRef;

  /// The real export work date. Legacy `WorkDate` / `WorkDateIsNow`.
  final WorkDateSetting workDate;

  /// The virtual export work date. Legacy `WorkDateVirtual` /
  /// `WorkDateVirtualIsNow`.
  final WorkDateSetting virtualWorkDate;

  WisaConnection copyWith({
    String? server,
    String? port,
    String? database,
    String? username,
    SecretRef? passwordRef,
    WorkDateSetting? workDate,
    WorkDateSetting? virtualWorkDate,
  }) {
    return WisaConnection(
      server: server ?? this.server,
      port: port ?? this.port,
      database: database ?? this.database,
      username: username ?? this.username,
      passwordRef: passwordRef ?? this.passwordRef,
      workDate: workDate ?? this.workDate,
      virtualWorkDate: virtualWorkDate ?? this.virtualWorkDate,
    );
  }

  Map<String, dynamic> toJson() => {
        'server': server,
        'port': port,
        'database': database,
        'username': username,
        'passwordRef': passwordRef.name,
        'workDate': workDate.toJson(),
        'virtualWorkDate': virtualWorkDate.toJson(),
      };

  factory WisaConnection.fromJson(Map<String, dynamic> json) {
    final ref = json['passwordRef'] as String?;
    return WisaConnection(
      server: (json['server'] as String?) ?? '',
      port: (json['port'] as String?) ?? '',
      database: (json['database'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      passwordRef: ref == null ? _wisaPasswordRef : SecretRef(ref),
      workDate: _workDate(json['workDate']),
      virtualWorkDate: _workDate(json['virtualWorkDate']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WisaConnection &&
      other.server == server &&
      other.port == port &&
      other.database == database &&
      other.username == username &&
      other.passwordRef == passwordRef &&
      other.workDate == workDate &&
      other.virtualWorkDate == virtualWorkDate;

  @override
  int get hashCode => Object.hash(
      server, port, database, username, passwordRef, workDate, virtualWorkDate);
}

/// Smartschool connection profile: endpoint, credentials seam, group paths, and
/// the grade/year label vocabulary.
///
/// Mirrors the config half of legacy `SmartschoolState` (uri/testUser +
/// passphrase, student/staff group paths, the `UseGrades`/`UseYears` flags, and
/// the fixed-length `grades[3]` / `years[7]` label arrays). The passphrase is
/// resolved through [passphraseRef], never stored inline.
class SmartschoolConnection {
  SmartschoolConnection({
    this.uri = '',
    this.passphraseRef = _smartschoolPassphraseRef,
    this.testUser = '',
    this.studentGroup = '',
    this.staffGroup = '',
    this.useGrades = false,
    this.useYears = false,
    List<String> grades = const [],
    List<String> years = const [],
  })  : grades = _fixed(grades, gradeCount),
        years = _fixed(years, yearCount);

  /// Number of grade labels (legacy `grades[3]`).
  static const int gradeCount = 3;

  /// Number of year labels (legacy `years[7]`).
  static const int yearCount = 7;

  /// SOAP endpoint URI. Legacy `SmartschoolState.Uri`.
  final String uri;

  /// Where the Smartschool passphrase is resolved from. The value never lives
  /// on this object or in the settings blob. Legacy `Passphrase` (was inline).
  final SecretRef passphraseRef;

  /// Account used by the connection self-test. Legacy `TestUser`.
  final String testUser;

  /// Root path of the student group tree. Legacy `StudentGroup`.
  final String studentGroup;

  /// Root path of the staff group tree. Legacy `StaffGroup`.
  final String staffGroup;

  /// Whether grade labels are applied. Legacy `UseGrades`.
  final bool useGrades;

  /// Whether year labels are applied. Legacy `UseYears`.
  final bool useYears;

  /// Grade labels, always exactly [gradeCount] entries (empty strings pad a
  /// short list; extras are dropped). Trimmed. Legacy `Grade1..Grade3`.
  final List<String> grades;

  /// Year labels, always exactly [yearCount] entries (empty strings pad a short
  /// list; extras are dropped). Trimmed. Legacy `Year1..Year7`.
  final List<String> years;

  SmartschoolConnection copyWith({
    String? uri,
    SecretRef? passphraseRef,
    String? testUser,
    String? studentGroup,
    String? staffGroup,
    bool? useGrades,
    bool? useYears,
    List<String>? grades,
    List<String>? years,
  }) {
    return SmartschoolConnection(
      uri: uri ?? this.uri,
      passphraseRef: passphraseRef ?? this.passphraseRef,
      testUser: testUser ?? this.testUser,
      studentGroup: studentGroup ?? this.studentGroup,
      staffGroup: staffGroup ?? this.staffGroup,
      useGrades: useGrades ?? this.useGrades,
      useYears: useYears ?? this.useYears,
      grades: grades ?? this.grades,
      years: years ?? this.years,
    );
  }

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'passphraseRef': passphraseRef.name,
        'testUser': testUser,
        'studentGroup': studentGroup,
        'staffGroup': staffGroup,
        'useGrades': useGrades,
        'useYears': useYears,
        'grades': grades,
        'years': years,
      };

  factory SmartschoolConnection.fromJson(Map<String, dynamic> json) {
    final ref = json['passphraseRef'] as String?;
    return SmartschoolConnection(
      uri: (json['uri'] as String?) ?? '',
      passphraseRef: ref == null ? _smartschoolPassphraseRef : SecretRef(ref),
      testUser: (json['testUser'] as String?) ?? '',
      studentGroup: (json['studentGroup'] as String?) ?? '',
      staffGroup: (json['staffGroup'] as String?) ?? '',
      useGrades: (json['useGrades'] as bool?) ?? false,
      useYears: (json['useYears'] as bool?) ?? false,
      grades: _strings(json['grades']),
      years: _strings(json['years']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SmartschoolConnection &&
      other.uri == uri &&
      other.passphraseRef == passphraseRef &&
      other.testUser == testUser &&
      other.studentGroup == studentGroup &&
      other.staffGroup == staffGroup &&
      other.useGrades == useGrades &&
      other.useYears == useYears &&
      _listEq(other.grades, grades) &&
      _listEq(other.years, years);

  @override
  int get hashCode => Object.hash(
        uri,
        passphraseRef,
        testUser,
        studentGroup,
        staffGroup,
        useGrades,
        useYears,
        Object.hashAll(grades),
        Object.hashAll(years),
      );
}

/// Azure AD / Office 365 connection profile: app registration + domain.
///
/// Mirrors the config half of legacy `AzureState` (ClientID, TenantID, Domain).
/// Azure carries **no secret here**: the connector authenticates interactively
/// or via a federated identity (the `azure_api` auth seam), so there is no
/// client secret to store or resolve.
class AzureConnection {
  const AzureConnection({
    this.clientId = '',
    this.tenantId = '',
    this.domain = '',
  });

  /// App registration (application) ID. Legacy `AzureState.ClientID`.
  final String clientId;

  /// Directory (tenant) ID. Legacy `AzureState.TenantID`.
  final String tenantId;

  /// Primary domain, e.g. `school.onmicrosoft.com`. Legacy `AzureState.Domain`.
  final String domain;

  AzureConnection copyWith({
    String? clientId,
    String? tenantId,
    String? domain,
  }) {
    return AzureConnection(
      clientId: clientId ?? this.clientId,
      tenantId: tenantId ?? this.tenantId,
      domain: domain ?? this.domain,
    );
  }

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'tenantId': tenantId,
        'domain': domain,
      };

  factory AzureConnection.fromJson(Map<String, dynamic> json) {
    return AzureConnection(
      clientId: (json['clientId'] as String?) ?? '',
      tenantId: (json['tenantId'] as String?) ?? '',
      domain: (json['domain'] as String?) ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AzureConnection &&
      other.clientId == clientId &&
      other.tenantId == tenantId &&
      other.domain == domain;

  @override
  int get hashCode => Object.hash(clientId, tenantId, domain);
}

WorkDateSetting _workDate(Object? json) => json == null
    ? const WorkDateSetting()
    : WorkDateSetting.fromJson(json as Map<String, dynamic>);

/// Normalizes [values] to exactly [length] trimmed entries: pads a short list
/// with empty strings and drops any extras, so a profile always exposes a
/// fixed-shape label array regardless of what an older config held.
List<String> _fixed(List<String> values, int length) => List.unmodifiable([
      for (var i = 0; i < length; i++)
        i < values.length ? values[i].trim() : '',
    ]);

List<String> _strings(Object? json) => json == null
    ? const []
    : [for (final v in json as List<dynamic>) v as String];

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
