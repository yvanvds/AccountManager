import 'package:account_core/account_core.dart' as core;

/// A WISA staff record (one row of the `SmaSyncPer` CSV).
///
/// Per the resolution of OQ-1 (`docs/domain-model.md` §3.4), `code` is the
/// primary key in WISA's staff scope and [wisaId] is retained as a
/// separate numeric identifier (which may be empty for some staff).
///
/// Implements the [core.WisaStaff] interface declared in `account_core`.
class WisaStaff implements core.WisaStaff {
  @override
  final core.WisaStaffCode code;

  @override
  final core.WisaId? wisaId;

  final String firstName;
  final String lastName;

  const WisaStaff({
    required this.code,
    this.wisaId,
    required this.firstName,
    required this.lastName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WisaStaff &&
          code == other.code &&
          wisaId == other.wisaId &&
          firstName == other.firstName &&
          lastName == other.lastName;

  @override
  int get hashCode => Object.hash(code, wisaId, firstName, lastName);

  @override
  String toString() =>
      'WisaStaff(code: $code, name: $firstName $lastName, wisaId: $wisaId)';
}
