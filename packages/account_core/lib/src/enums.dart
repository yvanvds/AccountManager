/// Domain enums.
///
/// Names diverge from legacy `AccountApi.Enums` where the spec calls for it
/// (see `docs/domain-model.md` §3). Each enum exposes a [name]-based
/// `toJson`/`fromJson` round-trip; the legacy `Transgender` value maps to
/// [Gender.x] per spec.
library;

/// Role of a person in the school. Replaces legacy `AccountRole`.
enum PersonRole {
  other,
  student,
  teacher,
  director,
  maintenance,
  it,
  support,
  ;

  String toJson() => name;
  static PersonRole fromJson(String s) => values.byName(s);
}

/// Biological / administrative gender. Legacy `Transgender` ⇒ [Gender.x]
/// (spec §3.1).
enum Gender {
  male,
  female,
  x,
  ;

  String toJson() => name;
  static Gender fromJson(String s) => values.byName(s);
}

/// Whether a [Group] is a class (`Class`) or a non-class group (`Group`).
/// `Invalid` is kept for legacy compatibility but should not be persisted on
/// new records.
enum GroupType {
  invalid,
  group,
  classGroup,
  ;

  String toJson() => name;
  static GroupType fromJson(String s) => values.byName(s);
}

/// Smartschool account type. `Student` is the primary account; `CoAccount1`
/// through `CoAccount6` are parent/guardian co-accounts attached to the same
/// student record.
enum AccountType {
  student,
  coAccount1,
  coAccount2,
  coAccount3,
  coAccount4,
  coAccount5,
  coAccount6,
  ;

  /// Numeric value used by the Smartschool API (0..6).
  int get smartschoolValue => index;

  String toJson() => name;
  static AccountType fromJson(String s) => values.byName(s);
  static AccountType fromSmartschoolValue(int v) => values[v];
}

/// Account lifecycle state.
enum AccountState {
  invalid,
  active,
  inactive,
  administrative,
  ;

  String toJson() => name;
  static AccountState fromJson(String s) => values.byName(s);
}

/// Connection state for a per-system connector.
enum ConnectionState {
  unknown,
  inProgress,
  ok,
  failed,
  ;

  String toJson() => name;
  static ConnectionState fromJson(String s) => values.byName(s);
}

/// Which system a record originated from. `all` is a wildcard used by the
/// log sink.
enum Origin {
  all,
  wisa,
  smartschool,
  azure,
  other,
  ;

  String toJson() => name;
  static Origin fromJson(String s) => values.byName(s);
}

/// Import rules applied at snapshot construction time
/// (`docs/domain-model.md` §3.11).
enum Rule {
  // Smartschool import rules.
  ssDiscardGroup,
  ssNoSubGroups,
  // WISA import rules.
  wiReplaceInstitution,
  wiDontImportClass,
  wiMarkAsVirtual,
  wiDontImportUser,
  ;

  String toJson() => name;
  static Rule fromJson(String s) => values.byName(s);
}

/// Which system a [Rule] applies to.
enum RuleType {
  ssImport,
  wisaImport,
  ;

  String toJson() => name;
  static RuleType fromJson(String s) => values.byName(s);
}

/// What a [Rule] does to a matching record.
enum RuleAction {
  discard,
  modify,
  workDate,
  ;

  String toJson() => name;
  static RuleAction fromJson(String s) => values.byName(s);
}
