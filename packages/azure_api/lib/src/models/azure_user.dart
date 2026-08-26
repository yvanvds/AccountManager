import 'package:account_core/account_core.dart' as core;

/// An Azure AD / Office 365 user, as read from Microsoft Graph.
///
/// Implements [core.AzureUser] so the linker can refer to it by its linking
/// keys (`id`, `upn`, `employeeId`) without depending on this package
/// (`docs/domain-model.md` §3.6, §4). The remaining fields are the ones the
/// connector reads and writes via Graph `$select`; nothing Graph emits that
/// the port does not use is carried.
///
/// Immutable. Legacy reference (read-only):
/// `legacy-wpf/AccountApi/Azure/User.cs`.
class AzureUser implements core.AzureUser {
  /// Azure object id (GUID). Stable across UPN changes.
  @override
  final String id;

  /// `userPrincipalName`. The primary linking key; compared
  /// case-insensitively and trimmed (INV-12).
  @override
  final String upn;

  /// Equals `WisaStudent.wisaId` / `WisaStaff.wisaId` when set — the
  /// cross-system bridge to WISA. `null`/empty for accounts not provisioned
  /// from WISA.
  @override
  final String? employeeId;

  final String displayName;
  final String givenName;
  final String surname;

  /// School prefix; the legacy connector uses it to identify alumni.
  final String? companyName;

  /// Holds the school prefix for staff; the student class group for students.
  final String? department;

  /// The account's function in the school — `LeerlingSec` for a secondary-school
  /// pupil, `LeerlingBas` for a basisschool one (#358).
  ///
  /// Half of the membership rule of the dynamic group that grants the student
  /// licence — the other half being [companyName]:
  ///
  ///     (user.companyName -eq "<PREFIX>") and (user.jobTitle -eq "LeerlingSec")
  ///
  /// An account with a blank or wrong `jobTitle` falls outside that group and is
  /// never licensed, however right its `companyName` is — which is why the field
  /// is read on every pull rather than only written.
  ///
  /// Staff carry values other software's own dynamic rules depend on, so this
  /// port reads the field for everybody and writes it for students only.
  final String? jobTitle;

  /// Whether the account is enabled for sign-in.
  final bool accountEnabled;

  /// When Entra created the account (`createdDateTime`), in UTC. `null` when a
  /// row did not carry it.
  ///
  /// The discriminator the #360 audit itself used: the two accounts of a
  /// duplicated `employeeId` pair were made by different runs of this app,
  /// months apart, so the date is what pairs an account with the run — and the
  /// UPN-normalisation rule — that made it (#363).
  ///
  /// An ordinary user property needing no permission beyond the ones the pull
  /// already holds, so it rides along in [graphSelectFields] rather than being
  /// fetched separately. Verified against the live tenant on both reads that
  /// carry the `$select`: the `$filter`ed bulk read and the `/users/delta`
  /// walk (including the `$deltatoken=latest` priming, whose options Graph
  /// replays on every resume).
  final DateTime? createdAt;

  /// The most recent sign-in Entra recorded for the account, in UTC — the later
  /// of `signInActivity.lastSignInDateTime` (an interactive sign-in) and
  /// `lastNonInteractiveSignInDateTime` (a token refresh by a mail or Teams
  /// client). `null` when it was not read, or when the account has never signed
  /// in.
  ///
  /// The fact that says which twin of a duplicated pair the student is actually
  /// working in — in at least one live pair that is the *unlicensed* one, so
  /// the student has no Office at all (#363). Both halves are taken because an
  /// account somebody only ever meets through a signed-in Outlook produces
  /// nothing but non-interactive refreshes, and calling that "never used" would
  /// be exactly the wrong answer.
  ///
  /// **Deliberately not in [graphSelectFields].** `signInActivity` is not an
  /// ordinary property:
  ///
  /// * it needs `AuditLog.Read.All` on top of the app's current grant (Entra ID
  ///   P1+), which neither app registration holds today, so putting it in the
  ///   bulk `$select` would fail *every* pull rather than one extra read; and
  /// * a collection read that selects it silently **ignores** `$filter`.
  ///   Verified live: `/users?$select=id,signInActivity&$filter=id in (…)` came
  ///   back paging the whole directory, ids that were never asked for included
  ///   — no error, just the full-tenant read PAIN-2 exists to prevent.
  ///
  /// So it is read one account at a time, and only for the bounded set of
  /// accounts a collision names ([UserManager.withSignInActivity]).
  final DateTime? lastSignIn;

  const AzureUser({
    required this.id,
    required this.upn,
    this.employeeId,
    this.displayName = '',
    this.givenName = '',
    this.surname = '',
    this.companyName,
    this.department,
    this.jobTitle,
    this.accountEnabled = true,
    this.createdAt,
    this.lastSignIn,
  });

  /// Fields the connector requests from Graph (`$select`). Kept minimal so the
  /// initial bulk read never pulls more than the port uses (PAIN-2).
  static const List<String> graphSelectFields = [
    'id',
    'userPrincipalName',
    'employeeId',
    'displayName',
    'givenName',
    'surname',
    'companyName',
    'department',
    // Read for every account, student and staff alike (#358): it is the second
    // half of the licensing rule, so a pull that cannot see it cannot tell a
    // student who will never be licensed from one who already is.
    'jobTitle',
    'accountEnabled',
    // #363: the audit's own discriminator between the two accounts of a
    // duplicated `employeeId` pair. An ordinary property needing no new
    // consent, so it costs one more field on a read the pull already makes —
    // unlike `signInActivity`, which is fetched per account and only for a
    // collision ([lastSignIn]).
    'createdDateTime',
  ];

  /// Parses a single Graph `user` resource (a JSON object as returned by
  /// `/users`, `/users/{id}` or `/users/delta`). Missing optional fields
  /// become `null`; missing strings become empty.
  factory AzureUser.fromGraphJson(Map<String, dynamic> json) {
    String str(String key) => (json[key] as String?) ?? '';
    String? nullable(String key) {
      final v = json[key] as String?;
      return (v == null || v.isEmpty) ? null : v;
    }

    return AzureUser(
      id: str('id'),
      upn: str('userPrincipalName'),
      employeeId: nullable('employeeId'),
      displayName: str('displayName'),
      givenName: str('givenName'),
      surname: str('surname'),
      companyName: nullable('companyName'),
      department: nullable('department'),
      jobTitle: nullable('jobTitle'),
      accountEnabled: (json['accountEnabled'] as bool?) ?? true,
      createdAt: parseTimestamp(json['createdDateTime']),
      lastSignIn: parseSignInActivity(json['signInActivity']),
    );
  }

  /// Reads one Graph ISO-8601 timestamp as UTC. `null` for anything that is not
  /// a parseable non-empty string — Graph answers `null` for a property the
  /// caller may read but this object has no value for, and a row that never
  /// mentioned it is no different.
  static DateTime? parseTimestamp(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  /// The later of the two timestamps a Graph `signInActivity` object carries,
  /// as UTC; `null` when the property is absent or holds neither.
  ///
  /// See [lastSignIn] for why the non-interactive half counts.
  static DateTime? parseSignInActivity(Object? activity) {
    if (activity is! Map<String, dynamic>) return null;
    final interactive = parseTimestamp(activity['lastSignInDateTime']);
    final background =
        parseTimestamp(activity['lastNonInteractiveSignInDateTime']);
    if (interactive == null) return background;
    if (background == null) return interactive;
    return background.isAfter(interactive) ? background : interactive;
  }

  /// Whether this delta entry marks the user as removed. Graph signals a
  /// deleted user with an `@removed` annotation on the resource.
  static bool isRemoved(Map<String, dynamic> json) =>
      json.containsKey('@removed');

  /// This user with every property [json] actually carries written over it,
  /// leaving the ones it stays silent about untouched (#288).
  ///
  /// The merge [AzureUser.fromGraphJson] cannot do. Graph represents a changed
  /// instance in a delta walk by its `id` plus *at least* the properties that
  /// changed, so a resumed row for a hand-edited account is routinely
  /// `{"id": "…", "displayName": "…"}` and nothing more. Read as a whole user
  /// that row is a wreck — blank `upn`, blank `displayName`, no `employeeId`,
  /// which is the `employeeId → wisaId` bridge the linker joins on — and
  /// upserting it over the previous snapshot destroyed the record it was
  /// supposed to update.
  ///
  /// Presence, not emptiness, decides: a property Graph *sent* wins even when
  /// it is `null` (that is how a cleared `employeeId` or `companyName` arrives),
  /// a property Graph omitted keeps its current value. `id` is the one
  /// exception — an empty incoming id never replaces the one this record is
  /// keyed by.
  AzureUser mergeGraphJson(Map<String, dynamic> json) {
    String str(String key, String current) =>
        json.containsKey(key) ? ((json[key] as String?) ?? '') : current;
    String? nullable(String key, String? current) {
      if (!json.containsKey(key)) return current;
      final v = json[key] as String?;
      return (v == null || v.isEmpty) ? null : v;
    }

    final incomingId = (json['id'] as String?) ?? '';
    return AzureUser(
      id: incomingId.isEmpty ? id : incomingId,
      upn: str('userPrincipalName', upn),
      employeeId: nullable('employeeId', employeeId),
      displayName: str('displayName', displayName),
      givenName: str('givenName', givenName),
      surname: str('surname', surname),
      companyName: nullable('companyName', companyName),
      department: nullable('department', department),
      jobTitle: nullable('jobTitle', jobTitle),
      accountEnabled: json.containsKey('accountEnabled')
          ? ((json['accountEnabled'] as bool?) ?? true)
          : accountEnabled,
      createdAt: json.containsKey('createdDateTime')
          ? parseTimestamp(json['createdDateTime'])
          : createdAt,
      // A delta row never carries `signInActivity` — it is not in the walk's
      // `$select` and could not be — so this branch keeps what the targeted
      // read of a previous pass put there rather than blanking it.
      lastSignIn: json.containsKey('signInActivity')
          ? parseSignInActivity(json['signInActivity'])
          : lastSignIn,
    );
  }

  /// Serializes to the connector's own cache shape (not Graph's). Round-trips
  /// with [AzureUser.fromJson] for the on-disk "last known good" snapshot.
  Map<String, dynamic> toJson() => {
        'id': id,
        'upn': upn,
        if (employeeId != null) 'employeeId': employeeId,
        'displayName': displayName,
        'givenName': givenName,
        'surname': surname,
        if (companyName != null) 'companyName': companyName,
        if (department != null) 'department': department,
        if (jobTitle != null) 'jobTitle': jobTitle,
        'accountEnabled': accountEnabled,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (lastSignIn != null) 'lastSignIn': lastSignIn!.toIso8601String(),
      };

  factory AzureUser.fromJson(Map<String, dynamic> json) => AzureUser(
        id: json['id'] as String,
        upn: json['upn'] as String,
        employeeId: json['employeeId'] as String?,
        displayName: (json['displayName'] as String?) ?? '',
        givenName: (json['givenName'] as String?) ?? '',
        surname: (json['surname'] as String?) ?? '',
        companyName: json['companyName'] as String?,
        department: json['department'] as String?,
        jobTitle: json['jobTitle'] as String?,
        accountEnabled: (json['accountEnabled'] as bool?) ?? true,
        createdAt: parseTimestamp(json['createdAt']),
        lastSignIn: parseTimestamp(json['lastSignIn']),
      );

  /// Returns a copy with the given fields replaced. Used to apply writes
  /// locally after a successful Graph PATCH.
  AzureUser copyWith({
    String? id,
    String? upn,
    String? employeeId,
    String? displayName,
    String? givenName,
    String? surname,
    String? companyName,
    String? department,
    String? jobTitle,
    bool? accountEnabled,
    DateTime? createdAt,
    DateTime? lastSignIn,
  }) =>
      AzureUser(
        id: id ?? this.id,
        upn: upn ?? this.upn,
        employeeId: employeeId ?? this.employeeId,
        displayName: displayName ?? this.displayName,
        givenName: givenName ?? this.givenName,
        surname: surname ?? this.surname,
        companyName: companyName ?? this.companyName,
        department: department ?? this.department,
        jobTitle: jobTitle ?? this.jobTitle,
        accountEnabled: accountEnabled ?? this.accountEnabled,
        createdAt: createdAt ?? this.createdAt,
        lastSignIn: lastSignIn ?? this.lastSignIn,
      );

  @override
  bool operator ==(Object other) =>
      other is AzureUser &&
      other.id == id &&
      other.upn == upn &&
      other.employeeId == employeeId &&
      other.displayName == displayName &&
      other.givenName == givenName &&
      other.surname == surname &&
      other.companyName == companyName &&
      other.department == department &&
      other.jobTitle == jobTitle &&
      other.accountEnabled == accountEnabled &&
      other.createdAt == createdAt &&
      other.lastSignIn == lastSignIn;

  @override
  int get hashCode => Object.hash(
        id,
        upn,
        employeeId,
        displayName,
        givenName,
        surname,
        companyName,
        department,
        jobTitle,
        accountEnabled,
        createdAt,
        lastSignIn,
      );

  @override
  String toString() => 'AzureUser($upn, id: $id, employeeId: $employeeId)';
}
