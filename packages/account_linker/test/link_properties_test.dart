// Property-based tests for the linker's invariants (INV-12/20/21/22/23).
//
// `glados` re-exports `package:test`, so it is the only test import here.
import 'package:account_core/account_core.dart';
import 'package:account_linker/account_linker.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:glados/glados.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'support/fixtures.dart';

const _prefix = 'Arcadia';

/// One synthetic person and how it shows up across the three systems. [tag]
/// drives the shared keys (`wisaId == 'W$tag'`, `mail == '$tag@s.be'`), so a
/// repeated tag creates real cross-system links and duplicate mails.
class PersonSpec {
  final String tag;
  final bool inWisa;
  final bool inSmartschool;
  final bool inAzure;

  /// When in Azure: `true` links via upn+employeeId; `false` is an orphan.
  final bool azureMatches;

  /// For an orphan: whether its `companyName` carries the school prefix.
  final bool azurePrefixed;

  PersonSpec(
    this.tag,
    this.inWisa,
    this.inSmartschool,
    this.inAzure,
    this.azureMatches,
    this.azurePrefixed,
  );
}

final Generator<List<PersonSpec>> _scenario = any.list(
  any.combine6(
    any.choose(['a', 'b', 'c', 'd', 'e']),
    any.bool,
    any.bool,
    any.bool,
    any.bool,
    any.bool,
    PersonSpec.new,
  ),
);

/// The built snapshots plus the source records, so identity-based invariant
/// checks can find each input record in the output.
class _Built {
  final List<wapi.WisaStudent> students;
  final List<ss.SmartschoolAccount> accounts;
  final List<az.AzureUser> users;
  final LinkedSnapshot linked;

  _Built(this.students, this.accounts, this.users, this.linked);
}

String _noise(String s) => '  ${s.toUpperCase()}  ';

_Built _build(
  List<PersonSpec> specs,
  PersonIdResolver resolver, {
  bool noisy = false,
}) {
  final students = <wapi.WisaStudent>[];
  final accounts = <ss.SmartschoolAccount>[];
  final users = <az.AzureUser>[];

  for (var i = 0; i < specs.length; i++) {
    final spec = specs[i];
    final wisaId = 'W${spec.tag}';
    final mail = '${spec.tag}@s.be';

    if (spec.inWisa) students.add(wisaStudent(wisaId));
    if (spec.inSmartschool) {
      accounts.add(
        ssAccount(
          uid: 's$i',
          accountId: wisaId,
          mail: noisy ? _noise(mail) : mail,
        ),
      );
    }
    if (spec.inAzure) {
      if (spec.azureMatches) {
        users.add(
          azureUser(
            id: 'a$i',
            upn: noisy ? _noise(mail) : mail,
            employeeId: noisy ? wisaId.toLowerCase() : wisaId,
            companyName: _prefix,
          ),
        );
      } else {
        users.add(
          azureUser(
            id: 'a$i',
            upn: 'orphan$i@x.be',
            companyName: spec.azurePrefixed ? _prefix : 'OtherSchool',
          ),
        );
      }
    }
  }

  final linked = link(
    wisaSnap(students),
    ssSnap(accounts),
    azSnap(users),
    resolver,
    schoolPrefix: _prefix,
  );
  return _Built(students, accounts, users, linked);
}

String? _norm(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return t.isEmpty ? null : t.toLowerCase();
}

void main() {
  group('link invariants', () {
    Glados(_scenario).test('INV-20: link is deterministic', (specs) {
      final first = _build(specs, SeqResolver()).linked;
      final second = _build(specs, SeqResolver()).linked;
      expect(structuralSignature(first), structuralSignature(second));
    });

    Glados(_scenario).test(
      'INV-21: every WISA person appears in exactly one account',
      (specs) {
        // Per **person**, not per row (#318). The shared WISA credentials pull
        // one school at a time and concatenate, and `schoolId` is a single int,
        // so one person enrolled in two group schools arrives as two rows
        // sharing a `wisaId`. Read per row — as this property was until #318 —
        // the invariant demanded a record for each of them, which is exactly
        // the second record that collapsed onto the first's `LinkedAccountId`.
        // What must hold is that the person links **once**, holding one of
        // their own rows; the tag pool is small enough that these scenarios
        // generate repeated wisaIds routinely.
        final built = _build(specs, SeqResolver());
        final rowsOf = <String, List<wapi.WisaStudent>>{};
        for (final student in built.students) {
          (rowsOf[student.wisaId.value] ??= <wapi.WisaStudent>[]).add(student);
        }
        for (final entry in rowsOf.entries) {
          final hits = built.linked.accounts
              .where((a) => entry.value.any((row) => identical(a.wisa, row)))
              .length;
          expect(hits, 1, reason: 'person ${entry.key} appeared $hits×');
        }
      },
    );

    Glados(_scenario).test(
      'INV-22: every school-prefixed Azure user appears in exactly one account',
      (specs) {
        final built = _build(specs, SeqResolver());
        final prefix = _norm(_prefix);
        final owned = built.users.where((u) => _norm(u.companyName) == prefix);
        for (final user in owned) {
          final hits = built.linked.accounts
              .where((a) => identical(a.azure, user))
              .length;
          expect(hits, 1, reason: 'azure ${user.id} appeared $hits×');
        }
      },
    );

    Glados(_scenario).test(
      'INV-23: no Smartschool account is dropped; collisions warn',
      (specs) {
        final built = _build(specs, SeqResolver());

        // Retention: every student account appears in exactly one record.
        for (final account in built.accounts) {
          final hits = built.linked.accounts
              .where((a) => identical(a.smartschool, account))
              .length;
          expect(hits, 1, reason: 'account ${account.uid} appeared $hits×');
        }

        // For each mail shared by ≥2 accounts there is exactly one warning
        // naming all of them.
        final byMail = <String, List<String>>{};
        for (final account in built.accounts) {
          final m = _norm(account.mail);
          if (m != null) byMail.putIfAbsent(m, () => []).add(account.uid);
        }
        final colliding =
            byMail.entries.where((e) => e.value.length >= 2).toList();

        final warnings =
            built.linked.warnings.whereType<ResolveDuplicateMail>().toList();
        expect(warnings, hasLength(colliding.length));

        for (final entry in colliding) {
          final warning = warnings.firstWhere((w) => w.mail == entry.key);
          expect(
            warning.accounts.map((a) => a.uid).toSet(),
            entry.value.toSet(),
          );
        }
      },
    );

    Glados(_scenario).test(
      'INV-24: a shared LinkedAccountId is always reported, never silent',
      (specs) {
        // This is the property #319 delivers, and it is deliberately *not* "ids
        // never collide". They do: an INV-23 duplicate-mail pair keeps two
        // records for one person, and both key on the same `accountId` — or,
        // with no accountId, on the very mail that made them collide — so the
        // resolver hands them one id. That is a live cause, independent of the
        // one #318 fixed, and it is filed as #323. Asserting its absence would
        // be asserting something false; what must hold is that no collision
        // gets through quietly.
        final linked = _build(specs, SeqResolver()).linked;

        final claims = <String, int>{};
        for (final a in linked.accounts) {
          claims[a.id.value] = (claims[a.id.value] ?? 0) + 1;
        }
        for (final s in linked.staff) {
          claims[s.id.value] = (claims[s.id.value] ?? 0) + 1;
        }
        final colliding = <String>{
          for (final e in claims.entries)
            if (e.value > 1) e.key,
        };

        final warnings =
            linked.warnings.whereType<DuplicateLinkedId>().toList();
        // Exactly one warning per colliding id: no misses, no false alarms, and
        // one warning per *id* rather than one per extra claimant.
        expect(warnings.map((w) => w.id.value).toSet(), colliding);
        expect(warnings, hasLength(colliding.length));
        for (final w in warnings) {
          expect(w.holdings, hasLength(claims[w.id.value]),
              reason: 'every record claiming ${w.id.value} must be listed');
        }

        // The tally counts people, so it can never exceed the distinct ids…
        for (final counts in [linked.wisa, linked.smartschool, linked.azure]) {
          expect(counts.total, lessThanOrEqualTo(claims.length));
          expect(counts.total, counts.linked + counts.unlinked);
        }
        // …and on a collision-free scenario it is exactly the pre-#319 number,
        // so the guard stays invisible on healthy data.
        if (colliding.isEmpty) {
          final wisa = linked.accounts.where((a) => a.wisa != null).length +
              linked.staff.where((s) => s.wisa != null).length;
          expect(linked.wisa.total, wisa);
        }
      },
    );

    Glados(_scenario).test(
      'INV-12: case/whitespace in mail and upn does not change linking',
      (specs) {
        final clean = _build(specs, SeqResolver()).linked;
        final noisy = _build(specs, SeqResolver(), noisy: true).linked;
        expect(structuralSignature(noisy), structuralSignature(clean));
      },
    );
  });
}
