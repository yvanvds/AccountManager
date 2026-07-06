import 'package:account_core/account_core.dart';

/// Whether a pending password sheet is for a person's own account or a
/// co-account (the legacy split between `Passwords.json` and
/// `CoPasswords.json`, PROJECT_OVERVIEW §6.3).
enum PasswordAccountKind { account, coAccount }

/// One pending password sheet in the password queue.
///
/// When the operator generates a password for a new account, an entry lands
/// here until a PDF sheet is exported and distributed. It is the port's
/// counterpart of the legacy `AbstractPassword` hierarchy
/// (`AccountPassword` / `CoAccountPassword`) that `PasswordManager` persisted.
///
/// The fields mirror the legacy `AccountPassword` (the common new-student
/// case): a login name, display name, mail, class group, and the two backend
/// passwords. A [kind] of [PasswordAccountKind.coAccount] instead carries the
/// freshly-generated co-account passwords in [coAccountPasswords], keyed by the
/// 1-based Smartschool slot (1..6) — the port of the legacy `CoAccountPassword`
/// with its `Co1..Co6` fields (#180). An `account`-kind entry leaves that map
/// empty; a `coAccount`-kind entry leaves the two backend passwords null.
///
/// [personId] anchors the entry to a stable [PersonId] so the queue survives a
/// re-sync that changes a login or mail.
class PasswordEntry {
  const PasswordEntry({
    required this.personId,
    required this.kind,
    required this.accountName,
    required this.displayName,
    this.mail,
    this.classGroup,
    this.smartschoolPassword,
    this.azurePassword,
    this.coAccountPasswords = const <int, String>{},
  });

  /// Stable identity of the person this sheet belongs to.
  final PersonId personId;

  /// Own account vs co-account.
  final PasswordAccountKind kind;

  /// Login / account name. Legacy `AccountName`.
  final String accountName;

  /// Human-readable name printed on the sheet. Legacy `Name`.
  final String displayName;

  /// Contact mail, when known. Legacy `AccountPassword.Mail`.
  final String? mail;

  /// Class or group label printed on the sheet. Legacy `ClassGroup`.
  final String? classGroup;

  /// The Smartschool password. Legacy `SSPassword`.
  final String? smartschoolPassword;

  /// The Azure / Office 365 password. Legacy `AzurePassword`.
  final String? azurePassword;

  /// Freshly-generated co-account passwords, keyed by 1-based Smartschool slot
  /// (1..6). Non-empty only for a [PasswordAccountKind.coAccount] entry; the
  /// port of the legacy `CoAccountPassword.Co1..Co6` fields (#180). Only the
  /// slots that were regenerated appear; the rest are absent (exported as blank
  /// CSV cells).
  final Map<int, String> coAccountPasswords;

  /// Serializes to a JSON-encodable map.
  Map<String, dynamic> toJson() {
    return {
      'personId': personId.value,
      'kind': kind.name,
      'accountName': accountName,
      'displayName': displayName,
      if (mail != null) 'mail': mail,
      if (classGroup != null) 'classGroup': classGroup,
      if (smartschoolPassword != null)
        'smartschoolPassword': smartschoolPassword,
      if (azurePassword != null) 'azurePassword': azurePassword,
      if (coAccountPasswords.isNotEmpty)
        'coAccountPasswords': <String, String>{
          for (final e in coAccountPasswords.entries) '${e.key}': e.value,
        },
    };
  }

  /// Reconstructs a [PasswordEntry] from a map produced by [toJson].
  ///
  /// Throws [FormatException] on an unknown `kind` tag.
  factory PasswordEntry.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String;
    final kind = PasswordAccountKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () =>
          throw FormatException('Unknown PasswordAccountKind: $kindName'),
    );
    return PasswordEntry(
      personId: PersonId(json['personId'] as String),
      kind: kind,
      accountName: json['accountName'] as String,
      displayName: json['displayName'] as String,
      mail: json['mail'] as String?,
      classGroup: json['classGroup'] as String?,
      smartschoolPassword: json['smartschoolPassword'] as String?,
      azurePassword: json['azurePassword'] as String?,
      coAccountPasswords: <int, String>{
        for (final e in (json['coAccountPasswords'] as Map<String, dynamic>? ??
                const <String, dynamic>{})
            .entries)
          int.parse(e.key): e.value as String,
      },
    );
  }
}
