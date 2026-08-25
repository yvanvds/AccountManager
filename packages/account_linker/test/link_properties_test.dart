// Property-based tests for the linker's invariants (INV-12/20/21/22/23/26).
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
      'INV-22: every school-prefixed Azure user is retained exactly once',
      (specs) {
        // Retained, not "sits on a record's `azure` slot" — the slot holds one
        // account and `employeeId` is not unique (INV-26, #360), so a person's
        // second account lands on `azureDuplicates` instead. What INV-22 is
        // about is that no owned account is *lost*, and that is what this says:
        // exactly one record claims it, in one place or the other. Read off the
        // slot alone, this demanded the very orphan record #360 removed.
        final built = _build(specs, SeqResolver());
        final prefix = _norm(_prefix);
        final owned = built.users.where((u) => _norm(u.companyName) == prefix);
        for (final user in owned) {
          final hits = built.linked.accounts
              .where((a) => a.azureCandidates.any((u) => identical(u, user)))
              .length;
          expect(hits, 1, reason: 'azure ${user.id} appeared $hits×');
        }
      },
    );

    Glados(_scenario).test(
      'INV-26: an employeeId on two accounts always warns, and loses neither',
      (specs) {
        final built = _build(specs, SeqResolver());

        final byEmployeeId = <String, List<String>>{};
        for (final user in built.users) {
          final id = _norm(user.employeeId);
          if (id != null) byEmployeeId.putIfAbsent(id, () => []).add(user.id);
        }
        final colliding =
            byEmployeeId.entries.where((e) => e.value.length >= 2).toList();

        final warnings = built.linked.warnings
            .whereType<DuplicateAzureEmployeeId>()
            .toList();
        expect(warnings, hasLength(colliding.length));

        for (final entry in colliding) {
          final warning = warnings.firstWhere((w) => w.employeeId == entry.key);
          // Every colliding account, in snapshot order — the adopted one first.
          expect(warning.accounts.map((u) => u.id).toList(), entry.value);
          // …and each of them still reachable from exactly one record, so a
          // collision never becomes a way to lose an account.
          for (final user in warning.accounts) {
            expect(
              built.linked.accounts.where(
                (a) => a.azureCandidates.any((u) => identical(u, user)),
              ),
              hasLength(1),
              reason: 'azure ${user.id} was not retained',
            );
          }
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
      'INV-24: no two records share a LinkedAccountId (#323)',
      (specs) {
        // The scenarios repeat tags freely, so they routinely generate the
        // INV-23 duplicate-mail pair: two Smartschool accounts for one person,
        // kept as two records, both preferring the same `accountId` key — or,
        // with no accountId, the very mail that made them collide. That was a
        // live cause of the #319 card (filed as #323) and this property is what
        // found it. Since the natural key falls through to an unclaimed one, it
        // can be stated as the invariant itself: an ordinary pass over ordinary
        // data never puts two records on one id.
        final linked = _build(specs, SeqResolver()).linked;

        final ids = <String>[
          for (final a in linked.accounts) a.id.value,
          for (final s in linked.staff) s.id.value,
        ];
        expect(ids.toSet(), hasLength(ids.length),
            reason: 'every record must own its id');
        expect(linked.warnings.whereType<DuplicateLinkedId>(), isEmpty);
      },
    );

    Glados(_scenario).test(
      'INV-24: a shared LinkedAccountId is always reported, never silent',
      (specs) {
        // The guard itself, driven from a resolver that hands out one id for
        // every key: whatever collides must be reported, exactly once per id.
        // Two properties, because they say different things — the one above is
        // "the linker does not produce collisions", this one is "a collision
        // from anywhere cannot pass quietly".
        final linked = _build(specs, CollidingResolver()).linked;

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
