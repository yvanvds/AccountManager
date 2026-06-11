import 'enums.dart';
import 'group.dart';
import 'ids.dart';
import 'source_records.dart';

/// How confident the linker is that a [LinkedAccount] is correct.
///
/// Spec `docs/domain-model.md` §3.9. Replaces the implicit "alumni" /
/// "placeholder" states that legacy encodes by which fields happen to be
/// null.
enum LinkConfidence {
  /// All linking keys agreed (e.g. `upn == mail` AND `employeeId == wisaId`).
  high,

  /// Some signal is missing or weak — typically an Azure-only record for a
  /// person who has left the school (the action engine raises a remove
  /// action for these) or a WISA-only placeholder for a student who hasn't
  /// been provisioned in Smartschool yet.
  medium,
  ;

  String toJson() => name;
  static LinkConfidence fromJson(String s) => values.byName(s);
}

/// Output of the linker: one record per identified person.
///
/// Any of [wisa], [smartschool], [azure] may be null; when all three are
/// present the linker has unified the systems' views of this person. When
/// one is missing, the action engine raises the matching add/remove action.
class LinkedAccount {
  final LinkedAccountId id;
  final PersonRole role;
  final WisaStudent? wisa;
  final SmartschoolAccount? smartschool;
  final AzureUser? azure;
  final LinkConfidence confidence;

  const LinkedAccount({
    required this.id,
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
  });
}

/// Output of the linker: one record per identified staff member.
///
/// Distinguished from [LinkedAccount] because staff use [WisaStaff] (with
/// its [WisaStaffCode]) instead of [WisaStudent].
class LinkedStaff {
  final LinkedAccountId id;
  final PersonRole role;
  final WisaStaff? wisa;
  final SmartschoolAccount? smartschool;
  final AzureUser? azure;
  final LinkConfidence confidence;

  const LinkedStaff({
    required this.id,
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
  });
}

/// Output of the linker: one record per identified group.
class LinkedGroup {
  final Group wisa;
  final Group? smartschool;
  final AzureGroup? azure;
  final LinkConfidence confidence;

  const LinkedGroup({
    required this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
  });
}

/// A non-fatal anomaly the linker surfaces for operator attention.
///
/// Collected into [LinkedSnapshot.warnings]. Sealed so the action engine
/// can dispatch exhaustively over the concrete variants.
sealed class LinkWarning {
  const LinkWarning();
}

/// INV-23: two or more Smartschool accounts claim the same [mail].
///
/// The legacy linker silently kept the first and dropped the rest (PAIN-7).
/// We retain every colliding account in the [LinkedSnapshot] and raise this
/// warning so the operator can resolve the collision (typically a stray
/// co-account; see INV-13).
class ResolveDuplicateMail extends LinkWarning {
  /// The address the colliding accounts share. Compared case-insensitively
  /// and trimmed per INV-12.
  final String mail;

  /// Every Smartschool account that claims [mail]; at least two.
  final List<SmartschoolAccount> accounts;

  const ResolveDuplicateMail({required this.mail, required this.accounts});
}

/// Per-system tally for one [LinkedSnapshot], mirroring the counters legacy
/// `LinkedAccounts.DoRelink` exposed.
///
/// A record counts toward [linked] when it is present in *every* system, and
/// toward [unlinked] when it is present in this system but missing from at
/// least one other. [total] == [linked] + [unlinked].
class LinkCounts {
  final int total;
  final int linked;
  final int unlinked;

  const LinkCounts({
    required this.total,
    required this.linked,
    required this.unlinked,
  });

  static const empty = LinkCounts(total: 0, linked: 0, unlinked: 0);
}

/// The complete output of one `link(wisa, smartschool, azure)` run.
///
/// Spec §6.2. Holds the reconciled [accounts], [staff], and [groups], the
/// per-system [LinkCounts], and any [warnings] raised while linking
/// (e.g. [ResolveDuplicateMail]). Pure data — produced by the linker (#43)
/// and consumed by the action engine (#46).
class LinkedSnapshot {
  final List<LinkedAccount> accounts;
  final List<LinkedStaff> staff;
  final List<LinkedGroup> groups;

  /// Account/staff tallies for WISA, Smartschool, and Azure respectively.
  final LinkCounts wisa;
  final LinkCounts smartschool;
  final LinkCounts azure;

  final List<LinkWarning> warnings;

  const LinkedSnapshot({
    required this.accounts,
    required this.staff,
    required this.groups,
    required this.wisa,
    required this.smartschool,
    required this.azure,
    this.warnings = const [],
  });

  /// Builds a snapshot and derives the per-system [LinkCounts] from the
  /// [accounts] and [staff] records, replicating legacy
  /// `LinkedAccounts.DoRelink`: a person counts toward a system's [total]
  /// when present there, and toward that system's [linked] only when present
  /// in all three systems. Groups are listed but not counted.
  factory LinkedSnapshot.fromRecords({
    required List<LinkedAccount> accounts,
    required List<LinkedStaff> staff,
    required List<LinkedGroup> groups,
    List<LinkWarning> warnings = const [],
  }) {
    var wisaTotal = 0, wisaLinked = 0;
    var ssTotal = 0, ssLinked = 0;
    var azTotal = 0, azLinked = 0;

    void tally({
      required bool inWisa,
      required bool inSmartschool,
      required bool inAzure,
    }) {
      final complete = inWisa && inSmartschool && inAzure;
      if (inWisa) {
        wisaTotal++;
        if (complete) wisaLinked++;
      }
      if (inSmartschool) {
        ssTotal++;
        if (complete) ssLinked++;
      }
      if (inAzure) {
        azTotal++;
        if (complete) azLinked++;
      }
    }

    for (final a in accounts) {
      tally(
        inWisa: a.wisa != null,
        inSmartschool: a.smartschool != null,
        inAzure: a.azure != null,
      );
    }
    for (final s in staff) {
      tally(
        inWisa: s.wisa != null,
        inSmartschool: s.smartschool != null,
        inAzure: s.azure != null,
      );
    }

    LinkCounts counts(int total, int linked) =>
        LinkCounts(total: total, linked: linked, unlinked: total - linked);

    return LinkedSnapshot(
      accounts: accounts,
      staff: staff,
      groups: groups,
      warnings: warnings,
      wisa: counts(wisaTotal, wisaLinked),
      smartschool: counts(ssTotal, ssLinked),
      azure: counts(azTotal, azLinked),
    );
  }
}
