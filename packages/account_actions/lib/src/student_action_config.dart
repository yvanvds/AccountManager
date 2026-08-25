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

  /// The Azure `jobTitle` this school stamps on its own students (#358) — the
  /// second half of the membership rule of the dynamic group that grants the
  /// Office 365 student licence:
  ///
  ///     (user.companyName -eq "<PREFIX>") and (user.jobTitle -eq "LeerlingSec")
  ///
  /// Configuration rather than a literal in the action, because the two halves
  /// of the group answer to different values: a secondary school writes
  /// `LeerlingSec`, a basisschool `LeerlingBas`. Defaults to `LeerlingSec`, this
  /// port's own kind of school.
  ///
  /// Never derived from [schoolPrefix]. Our prefix says which school an account
  /// belongs to, not which *kind* of pupil holds it — a basisschool pupil whose
  /// account wrongly carries our prefix would be handed a secondary licence they
  /// are not entitled to. WISA is the authority, which is why the repair that
  /// writes this reads a **linked** record and never an Azure-only orphan.
  final String studentJobTitle;

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
    this.studentJobTitle = defaultStudentJobTitle,
    String Function()? newAccountPassword,
    String Function(String givenName, String surname)? smartschoolUid,
  })  : studentDomain = studentDomain ?? 'student.$azureDomain',
        newAccountPassword = newAccountPassword ?? _defaultPassword,
        smartschoolUid = smartschoolUid ?? _defaultUid;

  /// The [studentJobTitle] a secondary school writes (#358). A basisschool
  /// running this port would configure `LeerlingBas` instead.
  static const String defaultStudentJobTitle = 'LeerlingSec';

  static String _defaultPassword() => Password.create();

  static String _defaultUid(String givenName, String surname) =>
      '${givenName.trim()}.${surname.trim()}'.toLowerCase().replaceAll(' ', '');
}
