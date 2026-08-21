/// Minimal interfaces for per-system source records.
///
/// Connector packages (`wisa_api`, `smartschool_api`, `azure_api`) provide
/// concrete classes implementing these interfaces with all the per-system
/// fields. `account_core` only exposes the linking keys the linker needs
/// (spec `docs/domain-model.md` §4) so `LinkedAccount` can refer to them
/// without depending on any connector.
library;

import 'enums.dart';
import 'ids.dart';

/// What `account_core` needs to know about a WISA student record.
abstract interface class WisaStudent {
  WisaId get wisaId;
}

/// What `account_core` needs to know about a WISA staff record.
abstract interface class WisaStaff {
  WisaStaffCode get code;
  WisaId? get wisaId;
}

/// What `account_core` needs to know about a Smartschool account record.
abstract interface class SmartschoolAccount {
  String get uid;
  String get mail;

  /// Operator convention: holds the WISA id of the linked student.
  String get accountId;
  AccountType get accountType;
}

/// What `account_core` needs to know about an Azure user record.
abstract interface class AzureUser {
  String get id;
  String get upn;
  String? get employeeId;
}

/// What `account_core` needs to know about an Azure group record.
abstract interface class AzureGroup {
  String get id;
  String get displayName;

  /// The group's SMTP address, e.g. `SSM-2A@student.arcadiascholen.be`. Only a
  /// mail-enabled (Microsoft 365 "unified") group has one; `null` for a plain
  /// security group, and `null` on a record read back from a snapshot written
  /// before the field was selected (#228).
  String? get mail;

  /// The group's mail alias — the local part [mail] is built from. Carried
  /// beside [displayName] because two groups may share a display name while
  /// addressing different mailboxes, and the class group is identified by the
  /// address it answers on (#228).
  String? get mailNickname;
}
