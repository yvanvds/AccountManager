import 'package:account_core/account_core.dart';

/// Configuration the staff action family needs, holding the values the legacy
/// code hard-coded (`docs/domain-model.md` §7 lists these as things to
/// parameterize).
///
/// Mirrors [StudentActionConfig] but without a `studentDomain`: staff live on
/// the base [azureDomain] (legacy `CreateStaffMember` passes `isStudent:
/// false`), so there is no student sub-domain to move them onto.
class StaffActionConfig {
  /// The school prefix stamped on a staff member's Azure `department` when a
  /// new account is created (legacy `CreateStaffMember` sets
  /// `Department = Connector.Prefix`).
  ///
  /// **Never written *over* (#237).** Other software maintains `department` as a
  /// comma-separated list of every school prefix the teacher is active at, so
  /// rewriting the field would evict a sibling school's claim — which is what
  /// `ModifyStaffAzureSchool` did before it was removed.
  ///
  /// Three writes use this value, and all three leave the other entries alone:
  /// `AddStaffToAzure` stamps it on an account it is *creating*,
  /// `ClaimStaffForAzureSchool` appends it as one more list item (#373), and
  /// `ReleaseStaffFromAzureSchool` strikes exactly that item out again (#349).
  final String schoolPrefix;

  /// The base UPN domain, e.g. `arcadiascholen.be`. New staff UPNs are minted
  /// under it, and `ModifySmartschoolStaffEmail` only re-syncs a Smartschool
  /// mail still on this domain.
  final String azureDomain;

  /// Password for a newly created account. Defaults to the domain [Password]
  /// generator. (Legacy used `Password.Create()`; the holder resets it when
  /// the account is handed out.)
  final String Function() newAccountPassword;

  /// Builds a Smartschool login (`uid`) from a staff member's given name and
  /// surname. Defaults to `"<given>.<surname>"` lower-cased with spaces
  /// stripped. Uniqueness against existing accounts is the caller's concern
  /// (the State layer holds the account set); the default is deliberately
  /// simple. Mirrors legacy `AccountManager.CreateUID`.
  final String Function(String givenName, String surname) smartschoolUid;

  StaffActionConfig({
    required this.schoolPrefix,
    required this.azureDomain,
    String Function()? newAccountPassword,
    String Function(String givenName, String surname)? smartschoolUid,
  })  : newAccountPassword = newAccountPassword ?? _defaultPassword,
        smartschoolUid = smartschoolUid ?? _defaultUid;

  static String _defaultPassword() => Password.create();

  static String _defaultUid(String givenName, String surname) =>
      '${givenName.trim()}.${surname.trim()}'.toLowerCase().replaceAll(' ', '');
}
