import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

/// Reconciles the three connector snapshots into one [LinkedAccount] per
/// student, ported from legacy `LinkedAccounts.DoRelink` but extracted from
/// WPF state and fixed for the known matching bugs.
///
/// Pure and deterministic (INV-20): the same snapshots and the same
/// [resolver] state always yield the same [LinkedSnapshot]. All impurity —
/// minting and persisting the stable [PersonId] — is delegated to [resolver],
/// so `link` itself does no I/O.
///
/// This issue (#43) links **students** only; [LinkedSnapshot.staff] and
/// [LinkedSnapshot.groups] are returned empty (staff #44, groups #45).
///
/// The bridges used (spec `docs/domain-model.md` §4, §6.2):
/// - `AzureUser.upn` ≡ `SmartschoolAccount.mail` (case-insensitive, trimmed)
/// - `SmartschoolAccount.accountId` ≡ `WisaStudent.wisaId` ≡
///   `AzureUser.employeeId`
///
/// Fixes carried over from the legacy linker:
/// - **INV-12:** every `mail`/`upn`/id comparison is trimmed and
///   case-insensitive (legacy `.Equals()` was case-sensitive).
/// - **INV-23:** two Smartschool accounts sharing a `mail` are *both* kept and
///   a [ResolveDuplicateMail] warning is raised (legacy silently dropped one).
///
/// [schoolPrefix] is the Azure `companyName` value the school stamps on its
/// own users; an Azure-only user carrying it is a former student kept as an
/// incomplete record so the action engine can flag it for deletion (INV-22).
LinkedSnapshot link(
  wapi.WisaSnapshot wisaSnapshot,
  ss.SmartschoolSnapshot smartschoolSnapshot,
  az.AzureSnapshot azureSnapshot,
  PersonIdResolver resolver, {
  required String schoolPrefix,
}) {
  // Records in creation order; the output preserves this order so the result
  // is a deterministic function of the input lists' order (INV-20).
  final records = <_Record>[];
  // Normalized mail -> the records that claim it (usually one; >1 ⇒ INV-23).
  final byMail = <String, List<_Record>>{};
  // Normalized wisaId/accountId -> the first record indexed under it.
  final byWisaId = <String, _Record>{};
  final warnings = <LinkWarning>[];

  // 1. Seed one record per Smartschool student account, in snapshot order.
  for (final account in smartschoolSnapshot.accounts) {
    if (account.accountType != AccountType.student) continue;
    final rec = _Record(smartschool: account);
    records.add(rec);

    final mail = _norm(account.mail);
    if (mail != null) byMail.putIfAbsent(mail, () => []).add(rec);

    final wisaId = _norm(account.accountId);
    if (wisaId != null) byWisaId.putIfAbsent(wisaId, () => rec);
  }

  // INV-23: surface every mail shared by two or more accounts.
  for (final entry in byMail.entries) {
    if (entry.value.length < 2) continue;
    warnings.add(
      ResolveDuplicateMail(
        mail: entry.key,
        accounts: <SmartschoolAccount>[
          for (final rec in entry.value) rec.smartschool!,
        ],
      ),
    );
  }

  // 2. Attach WISA students by wisaId; unmatched ones become WISA-only
  //    placeholders. INV-21: every WISA student lands in exactly one record.
  for (final student in wisaSnapshot.students) {
    final key = _norm(student.wisaId.value);
    final match = key == null ? null : byWisaId[key];
    if (match != null && match.wisa == null) {
      match.wisa = student;
    } else {
      final placeholder = _Record(wisa: student);
      records.add(placeholder);
      if (key != null) byWisaId.putIfAbsent(key, () => placeholder);
    }
  }

  // 3. Attach Azure users: by upn → mail, else by employeeId → wisaId, else
  //    keep school-prefix orphans (INV-22), else discard (another school).
  for (final user in azureSnapshot.users) {
    final upn = _norm(user.upn);
    final employeeId = _norm(user.employeeId);

    _Record? target;
    if (upn != null) {
      final candidates = byMail[upn];
      if (candidates != null) {
        for (final rec in candidates) {
          if (rec.azure == null) {
            target = rec;
            break;
          }
        }
      }
    }
    if (target == null && employeeId != null) {
      final rec = byWisaId[employeeId];
      if (rec != null && rec.azure == null) target = rec;
    }

    if (target != null) {
      target.azure = user;
    } else if (_matchesPrefix(user.companyName, schoolPrefix)) {
      records.add(_Record(azure: user));
    }
    // else: a user belonging to another school — not our concern, dropped.
  }

  // 4. Resolve a stable identity and confidence for each record.
  final accounts = <LinkedAccount>[
    for (final rec in records)
      LinkedAccount(
        id: LinkedAccountId(resolver.resolve(_naturalKey(rec)).value),
        role: PersonRole.student,
        wisa: rec.wisa,
        smartschool: rec.smartschool,
        azure: rec.azure,
        confidence: _confidence(rec),
      ),
  ];

  return LinkedSnapshot.fromRecords(
    accounts: accounts,
    staff: const [],
    groups: const [],
    warnings: warnings,
  );
}

/// Mutable accumulator for one linked person while the passes run; frozen into
/// an immutable [LinkedAccount] at the end.
class _Record {
  ss.SmartschoolAccount? smartschool;
  wapi.WisaStudent? wisa;
  az.AzureUser? azure;

  _Record({this.smartschool, this.wisa, this.azure});
}

/// Trims and lowercases [value] for case-insensitive, whitespace-tolerant
/// comparison (INV-12). Returns `null` when [value] is null or blank so empty
/// keys never match or index anything.
String? _norm(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed.toLowerCase();
}

/// Whether an Azure user's [companyName] marks it as one of the school's own
/// (a current or former student). Trimmed + case-insensitive.
bool _matchesPrefix(String? companyName, String schoolPrefix) {
  final company = _norm(companyName);
  final prefix = _norm(schoolPrefix);
  return company != null && prefix != null && company == prefix;
}

/// The natural key handed to the [PersonIdResolver]: `wisaId → mail → upn →
/// azureId`, normalized and namespaced so the resolver mints a stable, derived
/// [PersonId]. The wisaId is taken from whichever system carries it.
String _naturalKey(_Record rec) {
  final wisaId = _norm(
    rec.wisa?.wisaId.value ??
        rec.smartschool?.accountId ??
        rec.azure?.employeeId,
  );
  if (wisaId != null) return 'wisa:$wisaId';

  final mail = _norm(rec.smartschool?.mail);
  if (mail != null) return 'mail:$mail';

  final upn = _norm(rec.azure?.upn);
  if (upn != null) return 'upn:$upn';

  final azureId = _norm(rec.azure?.id);
  if (azureId != null) return 'azure:$azureId';

  // Unreachable: every record carries at least one identifying field.
  throw StateError('LinkedAccount record has no identifying key: $rec');
}

/// `high` only when all three systems are present *and* every bridge key
/// agrees; anything weaker (a missing system, or a forced match where a key
/// disagrees) is `medium`.
LinkConfidence _confidence(_Record rec) {
  final student = rec.wisa;
  final account = rec.smartschool;
  final user = rec.azure;
  if (student == null || account == null || user == null) {
    return LinkConfidence.medium;
  }

  final upn = _norm(user.upn);
  final mail = _norm(account.mail);
  final mailAgrees = upn != null && upn == mail;

  final wisaId = _norm(student.wisaId.value);
  final accountId = _norm(account.accountId);
  final employeeId = _norm(user.employeeId);
  final idAgrees =
      wisaId != null && wisaId == accountId && wisaId == employeeId;

  return mailAgrees && idAgrees ? LinkConfidence.high : LinkConfidence.medium;
}
