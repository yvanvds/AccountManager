import 'package:account_core/account_core.dart' as core;

import '../parsing/mappings.dart';
import 'co_account_slot.dart';

/// A Smartschool account record — one entry from `getAllAccountsExtended`
/// or `getUserDetails`.
///
/// Implements [core.SmartschoolAccount] so the linker can refer to it
/// without depending on `smartschool_api`. The flat shape mirrors
/// Smartschool's SOAP contract (spec `docs/domain-model.md` §3.5) and must
/// not leak past the connector boundary into the linker.
///
/// Co-accounts are embedded as [coAccounts] slots, not separate records —
/// they share this account's [uid]. Legacy reference (read-only):
/// `legacy-wpf/AccountApi/Smartschool/Account.cs`.
class SmartschoolAccount implements core.SmartschoolAccount {
  /// Smartschool username / login.
  @override
  final String uid;

  /// Smartschool internal number ("Internnummer"). Operator convention:
  /// holds the WISA `wisaId` of the linked student (spec §3.5, §4).
  @override
  final String accountId;

  /// Linking key. Compared to Azure UPN case-insensitively + trimmed
  /// (INV-12) by the linker.
  @override
  final String mail;

  /// Always [core.AccountType.student] for a primary record. Co-accounts
  /// are surfaced via [coAccounts], not as separate accounts.
  @override
  core.AccountType get accountType => core.AccountType.student;

  /// Rijksregisternummer.
  final String registerId;

  /// Stamboeknummer, parsed to int by the connector (0 when absent).
  final int stemId;

  /// Mapped from `Basisrol`. `null` when the role code was unrecognised.
  final core.PersonRole? role;

  final String givenName;
  final String surname;
  final String extraNames;
  final String initials;

  /// "Roepnaam" — overrides given name in display contexts. Empty when unset.
  final String preferredName;

  final core.Gender gender;
  final DateTime? birthDate;
  final String birthPlace;
  final String birthCountry;

  final core.Address address;

  final String mobilePhone;
  final String homePhone;
  final String fax;

  /// Smartschool's UntisID field (not currently writable by Smartschool).
  final String untisId;

  /// Raw Smartschool status string (`actief` / `uitgeschakeld` / …). Use
  /// `accountStateFromStatus` for the typed view. Disabled accounts are
  /// filtered out at snapshot construction, so a snapshot account is never
  /// `uitgeschakeld`.
  final String status;

  /// Smartschool's raw `referenceIdentifier`, verbatim as returned —
  /// `<platformId>_<userId>_<coAccountIndex>`, e.g. `4069_12016_0` (#138).
  ///
  /// `null` when the payload omits it (older tenants, some co-account rows);
  /// the parser never fails on a missing or malformed value. Use
  /// [internalUserId] for the middle segment on its own.
  final String? referenceIdentifier;

  /// Smartschool's internal user id — the middle segment of
  /// [referenceIdentifier], e.g. `12016` for `4069_12016_0` (#138).
  ///
  /// This is the id Smartschool uses to address a user outside this SOAP API;
  /// it is none of [accountId] ("Internnummer"), [stemId], or the scannable
  /// code. `null` when [referenceIdentifier] is absent or does not have the
  /// documented three-segment shape.
  int? get internalUserId => smartschoolUserIdFrom(referenceIdentifier);

  /// Parent/guardian co-account slots, in ascending slot order. Only
  /// non-empty slots are present.
  final List<CoAccountSlot> coAccounts;

  const SmartschoolAccount({
    required this.uid,
    required this.accountId,
    required this.mail,
    required this.registerId,
    required this.stemId,
    required this.role,
    required this.givenName,
    required this.surname,
    required this.extraNames,
    required this.initials,
    required this.preferredName,
    required this.gender,
    required this.birthDate,
    required this.birthPlace,
    required this.birthCountry,
    required this.address,
    required this.mobilePhone,
    required this.homePhone,
    required this.fax,
    required this.untisId,
    required this.status,
    this.referenceIdentifier,
    this.coAccounts = const [],
  });

  /// Returns a copy with the given fields replaced. Used by the action engine
  /// to project the mutated source record after a successful write, so the
  /// State layer can patch its snapshot without a re-sync (`account_actions`).
  SmartschoolAccount copyWith({
    String? uid,
    String? accountId,
    String? mail,
    String? registerId,
    int? stemId,
    core.PersonRole? role,
    String? givenName,
    String? surname,
    String? extraNames,
    String? initials,
    String? preferredName,
    core.Gender? gender,
    DateTime? birthDate,
    String? birthPlace,
    String? birthCountry,
    core.Address? address,
    String? mobilePhone,
    String? homePhone,
    String? fax,
    String? untisId,
    String? status,
    String? referenceIdentifier,
    List<CoAccountSlot>? coAccounts,
  }) =>
      SmartschoolAccount(
        uid: uid ?? this.uid,
        accountId: accountId ?? this.accountId,
        mail: mail ?? this.mail,
        registerId: registerId ?? this.registerId,
        stemId: stemId ?? this.stemId,
        role: role ?? this.role,
        givenName: givenName ?? this.givenName,
        surname: surname ?? this.surname,
        extraNames: extraNames ?? this.extraNames,
        initials: initials ?? this.initials,
        preferredName: preferredName ?? this.preferredName,
        gender: gender ?? this.gender,
        birthDate: birthDate ?? this.birthDate,
        birthPlace: birthPlace ?? this.birthPlace,
        birthCountry: birthCountry ?? this.birthCountry,
        address: address ?? this.address,
        mobilePhone: mobilePhone ?? this.mobilePhone,
        homePhone: homePhone ?? this.homePhone,
        fax: fax ?? this.fax,
        untisId: untisId ?? this.untisId,
        status: status ?? this.status,
        referenceIdentifier: referenceIdentifier ?? this.referenceIdentifier,
        coAccounts: coAccounts ?? this.coAccounts,
      );

  /// Serializes to the connector's own snapshot shape. Round-trips with
  /// [SmartschoolAccount.fromJson] for the persisted cold snapshot (#107).
  Map<String, dynamic> toJson() => {
        'uid': uid,
        'accountId': accountId,
        'mail': mail,
        'registerId': registerId,
        'stemId': stemId,
        if (role != null) 'role': role!.toJson(),
        'givenName': givenName,
        'surname': surname,
        'extraNames': extraNames,
        'initials': initials,
        'preferredName': preferredName,
        'gender': gender.toJson(),
        if (birthDate != null) 'birthDate': birthDate!.toIso8601String(),
        'birthPlace': birthPlace,
        'birthCountry': birthCountry,
        'address': address.toJson(),
        'mobilePhone': mobilePhone,
        'homePhone': homePhone,
        'fax': fax,
        'untisId': untisId,
        'status': status,
        if (referenceIdentifier != null)
          'referenceIdentifier': referenceIdentifier,
        'coAccounts': [for (final c in coAccounts) c.toJson()],
      };

  factory SmartschoolAccount.fromJson(Map<String, dynamic> json) =>
      SmartschoolAccount(
        uid: json['uid'] as String,
        accountId: json['accountId'] as String,
        mail: json['mail'] as String,
        registerId: json['registerId'] as String,
        stemId: json['stemId'] as int,
        role: json['role'] == null
            ? null
            : core.PersonRole.fromJson(json['role'] as String),
        givenName: json['givenName'] as String,
        surname: json['surname'] as String,
        extraNames: json['extraNames'] as String,
        initials: json['initials'] as String,
        preferredName: json['preferredName'] as String,
        gender: core.Gender.fromJson(json['gender'] as String),
        birthDate: json['birthDate'] == null
            ? null
            : DateTime.parse(json['birthDate'] as String),
        birthPlace: json['birthPlace'] as String,
        birthCountry: json['birthCountry'] as String,
        address: core.Address.fromJson(json['address'] as Map<String, dynamic>),
        mobilePhone: json['mobilePhone'] as String,
        homePhone: json['homePhone'] as String,
        fax: json['fax'] as String,
        untisId: json['untisId'] as String,
        status: json['status'] as String,
        referenceIdentifier: json['referenceIdentifier'] as String?,
        coAccounts: [
          for (final e in (json['coAccounts'] as List<dynamic>? ?? const []))
            CoAccountSlot.fromJson(e as Map<String, dynamic>),
        ],
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SmartschoolAccount &&
          uid == other.uid &&
          accountId == other.accountId &&
          mail == other.mail &&
          registerId == other.registerId &&
          stemId == other.stemId &&
          role == other.role &&
          givenName == other.givenName &&
          surname == other.surname &&
          extraNames == other.extraNames &&
          initials == other.initials &&
          preferredName == other.preferredName &&
          gender == other.gender &&
          birthDate == other.birthDate &&
          birthPlace == other.birthPlace &&
          birthCountry == other.birthCountry &&
          address == other.address &&
          mobilePhone == other.mobilePhone &&
          homePhone == other.homePhone &&
          fax == other.fax &&
          untisId == other.untisId &&
          status == other.status &&
          referenceIdentifier == other.referenceIdentifier &&
          _listEquals(coAccounts, other.coAccounts);

  @override
  int get hashCode => Object.hashAll([
        uid,
        accountId,
        mail,
        registerId,
        stemId,
        role,
        givenName,
        surname,
        extraNames,
        initials,
        preferredName,
        gender,
        birthDate,
        birthPlace,
        birthCountry,
        address,
        mobilePhone,
        homePhone,
        fax,
        untisId,
        status,
        referenceIdentifier,
        ...coAccounts,
      ]);

  @override
  String toString() =>
      'SmartschoolAccount(uid: $uid, accountId: $accountId, mail: $mail, '
      'coAccounts: ${coAccounts.length})';
}

bool _listEquals(List<CoAccountSlot> a, List<CoAccountSlot> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
