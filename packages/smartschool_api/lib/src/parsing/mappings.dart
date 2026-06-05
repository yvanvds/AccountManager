/// Value mappings between the canonical domain model and Smartschool's flat
/// SOAP shape. Every function here is a verbatim port of the legacy
/// conversions in `legacy-wpf/AccountApi/Smartschool/AccountManager.cs` and
/// `Group.cs`, table-driven so the edge cases are easy to test.
library;

import 'package:account_core/account_core.dart' as core;

/// Thrown by [smartschoolRole] when a role cannot be represented in
/// Smartschool. Mirrors the legacy `Save` returning `false` for
/// `AccountRole.Other` (`AccountManager.cs:37`).
class UnsupportedSmartschoolRole implements Exception {
  final core.PersonRole role;
  UnsupportedSmartschoolRole(this.role);
  @override
  String toString() =>
      'UnsupportedSmartschoolRole: $role cannot be saved to Smartschool';
}

/// Maps a [core.PersonRole] to the Dutch role string Smartschool expects on
/// `saveUser` (`Leerling` / `Leerkracht` / `Directie`).
///
/// `Student → Leerling`; `Teacher | Support | IT | Maintenance → Leerkracht`;
/// `Director → Directie`; `Other →` throws [UnsupportedSmartschoolRole]
/// (legacy refuses to save these). Legacy: `AccountManager.cs:28-38`.
String smartschoolRole(core.PersonRole role) {
  switch (role) {
    case core.PersonRole.student:
      return 'Leerling';
    case core.PersonRole.teacher:
    case core.PersonRole.support:
    case core.PersonRole.it:
    case core.PersonRole.maintenance:
      return 'Leerkracht';
    case core.PersonRole.director:
      return 'Directie';
    case core.PersonRole.other:
      throw UnsupportedSmartschoolRole(role);
  }
}

/// Maps the `Basisrol` code returned by `getUserDetails` /
/// `getAllAccountsExtended` to a [core.PersonRole].
///
/// `1 → Student`; `0 | 13 → Teacher`; `30 → Director`. Any other value is
/// unknown and yields `null` (legacy logged an error and left the role
/// unset). Legacy: `AccountManager.cs:521-535`.
core.PersonRole? personRoleFromBasisrol(String? basisrol) {
  switch (basisrol) {
    case '1':
      return core.PersonRole.student;
    case '0':
    case '13':
      return core.PersonRole.teacher;
    case '30':
      return core.PersonRole.director;
    default:
      return null;
  }
}

/// Maps a [core.Gender] to Smartschool's `m`/`f` (its only supported pair).
/// `Male → m`; `Female | X → f`. Legacy: `AccountManager.cs:41-43`.
String smartschoolGender(core.Gender gender) =>
    gender == core.Gender.male ? 'm' : 'f';

/// Maps Smartschool's `Geslacht` (`m`/`f`/other) back to a [core.Gender].
/// `m → Male`; `f → Female`; anything else → `X` (legacy mapped the
/// "neither" case to `Transgender`, which is `Gender.x` in the port).
/// Legacy: `AccountManager.cs:546-557`.
core.Gender genderFromSmartschool(String? geslacht) {
  switch (geslacht) {
    case 'm':
      return core.Gender.male;
    case 'f':
      return core.Gender.female;
    default:
      return core.Gender.x;
  }
}

/// Formats a stamboeknummer for `saveUser`.
///
/// `0 → ""`; values `< 1_000_000` are zero-padded with a single leading `0`
/// (legacy `"0" + stemID`, yielding 7 digits for 6-digit numbers); larger
/// values are emitted as-is. Legacy: `AccountManager.cs:50-52`.
String formatStamboek(int stemId) {
  if (stemId == 0) return '';
  if (stemId < 1000000) return '0$stemId';
  return '$stemId';
}

/// Parses a stamboeknummer string into an int. Returns `0` when [value] is
/// null/empty/non-numeric (legacy swallowed the parse error and left the
/// previous value, which defaulted to `0`). Legacy: `AccountManager.cs:512-518`.
int parseStamboek(String? value) =>
    value == null ? 0 : (int.tryParse(value.trim()) ?? 0);

/// Maps a Smartschool `Status` string to a [core.AccountState].
///
/// Known values (see also the open question in issue #21): `actief` /
/// `active` / `enabled → Active`; `uitgeschakeld → Inactive`;
/// `administratief` / `administrative → Administrative`; anything else
/// `→ Invalid`. Legacy: `AccountManager.cs:353-366`.
core.AccountState accountStateFromStatus(String? status) {
  switch (status) {
    case 'actief':
    case 'active':
    case 'enabled':
      return core.AccountState.active;
    case 'uitgeschakeld':
      return core.AccountState.inactive;
    case 'administratief':
    case 'administrative':
      return core.AccountState.administrative;
    default:
      return core.AccountState.invalid;
  }
}

/// The raw Smartschool status string for a disabled account. Accounts with
/// this status are filtered out at snapshot construction (legacy
/// `Group.cs:400`).
const String disabledStatus = 'uitgeschakeld';

/// Maps a [core.AccountState] to the string `setAccountStatus` expects.
/// `Active → active`; `Inactive → inactive`; `Administrative →
/// administrative`; `Invalid → invalid`. Legacy: `AccountManager.cs:291-305`.
String statusFromAccountState(core.AccountState state) {
  switch (state) {
    case core.AccountState.active:
      return 'active';
    case core.AccountState.inactive:
      return 'inactive';
    case core.AccountState.administrative:
      return 'administrative';
    case core.AccountState.invalid:
      return 'invalid';
  }
}
