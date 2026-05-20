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
}
