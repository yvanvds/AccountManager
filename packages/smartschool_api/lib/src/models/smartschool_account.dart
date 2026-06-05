import 'package:account_core/account_core.dart' as core;

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
    this.coAccounts = const [],
  });

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
