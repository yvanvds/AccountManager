import 'package:account_core/account_core.dart' as core;

/// One parent/guardian co-account attached to a Smartschool student record.
///
/// Smartschool exposes up to six co-account slots per account
/// (`*_coaccount1` … `*_coaccount6` fields on the JSON record). Co-accounts
/// are **not** separate accounts — they live on the holder's record and
/// share its UID. The legacy `LoadFromJSON` discarded these fields entirely;
/// the port preserves them (spec `docs/domain-model.md` §3.5, issue #21).
///
/// Passwords are never returned by Smartschool, so a slot carries only the
/// descriptive fields. The slot's [type] is Smartschool's free-text
/// relationship label (e.g. "Moeder", "Vader").
class CoAccountSlot {
  /// 1-based slot index (1..6). Maps to [core.AccountType.coAccount1] …
  /// [core.AccountType.coAccount6].
  final int slot;
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String mobile;
  final String type;

  const CoAccountSlot({
    required this.slot,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    required this.mobile,
    required this.type,
  });

  /// The [core.AccountType] this slot corresponds to
  /// (`coAccount1`..`coAccount6`).
  core.AccountType get accountType =>
      core.AccountType.fromSmartschoolValue(slot);

  /// A slot is empty when none of its descriptive fields carry data. Empty
  /// slots are dropped at parse time, so a surfaced [CoAccountSlot] is
  /// always non-empty — this getter exists for parser/tests.
  bool get isEmpty =>
      firstName.isEmpty &&
      lastName.isEmpty &&
      email.isEmpty &&
      phone.isEmpty &&
      mobile.isEmpty &&
      type.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoAccountSlot &&
          slot == other.slot &&
          firstName == other.firstName &&
          lastName == other.lastName &&
          email == other.email &&
          phone == other.phone &&
          mobile == other.mobile &&
          type == other.type;

  @override
  int get hashCode =>
      Object.hash(slot, firstName, lastName, email, phone, mobile, type);

  @override
  String toString() =>
      'CoAccountSlot($slot, $firstName $lastName, type: $type)';
}
