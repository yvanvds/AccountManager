import 'package:account_core/account_core.dart';

/// Configuration the student action family needs, holding the values the
/// legacy code hard-coded (`docs/domain-model.md` §7 lists these as things to
/// parameterize).
///
/// Legacy hard-coded `"arcadiascholen.be"` / `"student.arcadiascholen.be"`, a
/// `"FakeP4ssword"` placeholder for new Smartschool accounts, and a UID
/// builder (`AccountManager.CreateUID`). Those become injectable here so the
/// engine stays testable and reusable.
class StudentActionConfig {
  /// The Azure `companyName` value the school stamps on its own students
  /// (`ModifyAzureSchool` / `RemoveStudentFromAzure` gate on it).
  final String schoolPrefix;

  /// The base UPN domain, e.g. `arcadiascholen.be`. Used to detect accounts
  /// still on the staff/base domain that should move to [studentDomain].
  final String azureDomain;

  /// The student UPN domain, e.g. `student.arcadiascholen.be`. Defaults to
  /// `student.<azureDomain>`.
  final String studentDomain;

  /// Password for a newly created account. Defaults to the domain [Password]
  /// generator. (Legacy used a `"FakeP4ssword"` placeholder that the holder
  /// resets on first login.)
  final String Function() newAccountPassword;

  /// Builds a Smartschool login (`uid`) from a student's given name and
  /// surname. Defaults to `"<given>.<surname>"` lower-cased with spaces
  /// stripped. Uniqueness against existing accounts is the caller's concern
  /// (the State layer holds the account set); the default is deliberately
  /// simple.
  final String Function(String givenName, String surname) smartschoolUid;

  StudentActionConfig({
    required this.schoolPrefix,
    required this.azureDomain,
    String? studentDomain,
    String Function()? newAccountPassword,
    String Function(String givenName, String surname)? smartschoolUid,
  })  : studentDomain = studentDomain ?? 'student.$azureDomain',
        newAccountPassword = newAccountPassword ?? _defaultPassword,
        smartschoolUid = smartschoolUid ?? _defaultUid;

  static String _defaultPassword() => Password.create();

  static String _defaultUid(String givenName, String surname) =>
      '${givenName.trim()}.${surname.trim()}'.toLowerCase().replaceAll(' ', '');
}
