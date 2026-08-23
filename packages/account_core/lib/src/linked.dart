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

/// Where a linked student sits in the *aggregated* WISA snapshot relative to
/// the schools we actually manage (#113/#134).
///
/// The shared credentials pull **every** WISA school the group can see, so a
/// student's [LinkedAccount.wisa] being non-null only means they are somewhere
/// in the group — not necessarily in one of our schools. This enum makes the
/// distinction the departure actions turn on:
///
/// - [ours]: present in WISA in at least one school we manage — the normal
///   "still here" case. Also the backward-compatible default when no school is
///   flagged as ours (ownership unconfigured ⇒ every WISA-present student is
///   treated as ours), so a group that hasn't adopted the aggregated pull keeps
///   its pre-#134 behaviour.
/// - [groupOnly]: present in the aggregated snapshot but only in sibling group
///   schools we do **not** manage. The student left *our* school yet is still in
///   the group — remove them from *our* Smartschool but **keep** Azure.
/// - [absent]: no WISA record at all — gone from the whole group. Remove from
///   Smartschool *and* Azure (the "incomplete Azure-only record flagged for
///   deletion", per the no-alumni rule).
enum WisaPresence {
  ours,
  groupOnly,
  absent,
  ;

  String toJson() => name;
  static WisaPresence fromJson(String s) => values.byName(s);
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

  /// The WISA school ids this student's record was found in — the raw
  /// per-school membership the linker joins against the managed-school set
  /// (#133). Empty when [wisa] is null. Retained on the record so the ours-vs-
  /// group distinction is auditable, not just its derived [wisaPresence].
  final Set<int> wisaSchoolIds;

  /// Where this student sits relative to the schools we manage — the signal the
  /// departure actions turn on (#134). Defaults to [WisaPresence.ours]; the
  /// convenience getters below always fold in [wisa] nullness, so a hand-built
  /// record left on the default but carrying no WISA record still reads as
  /// having left.
  final WisaPresence wisaPresence;

  const LinkedAccount({
    required this.id,
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
    this.wisaSchoolIds = const <int>{},
    this.wisaPresence = WisaPresence.ours,
  });

  /// Whether this student is present in WISA in a school we manage. False when
  /// absent from WISA entirely or present only in sibling group schools.
  bool get isInOurWisa => wisa != null && wisaPresence == WisaPresence.ours;

  /// Whether this student has left the schools we manage — moved to a sibling
  /// group school, or gone from the group entirely. Drives the Smartschool
  /// departure actions (unregister / delete).
  bool get hasLeftOurSchool => !isInOurWisa;

  /// Whether this student is gone from the **entire** group — absent from the
  /// aggregated WISA snapshot. Drives the delete-both vs keep-Azure split: only
  /// a group-departure removes the Azure account. A student still present in a
  /// sibling group school ([WisaPresence.groupOnly]) keeps a non-null [wisa],
  /// so this is false and their Azure removal is suppressed.
  bool get hasLeftGroup => wisa == null;
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
///
/// [wisa] is nullable (#52): a group that vanished from WISA but still exists
/// in Smartschool and/or Azure is kept as an orphan record — symmetric with
/// how an Azure-only [LinkedAccount] is kept for a former student — so the
/// action engine can raise a delete action for it instead of it silently
/// disappearing. At least one of [wisa], [smartschool], [azure] is always
/// present.
class LinkedGroup {
  final Group? wisa;
  final Group? smartschool;
  final AzureGroup? azure;
  final LinkConfidence confidence;

  /// A Smartschool group that already carries this class's name but which the
  /// group link could **not** adopt as [smartschool] (#225) — set only when
  /// [smartschool] is null and [wisa] is not.
  ///
  /// Two shapes reach here, and the difference is visible on the record itself
  /// ([Group.official], [Group.name]):
  /// - the namesake is not flagged as an official class, so the link skipped
  ///   it (a class Smartschool holds as an organisational group);
  /// - the namesake *is* an official class but its name differs from the WISA
  ///   one by more than the match key tolerates (`2 G` vs `2G`).
  ///
  /// Either way the class exists downstream in some form, so proposing to
  /// create it would ask Smartschool for a duplicate name — it either rejects
  /// the write or ends up with two classes. The action engine raises an
  /// explicit notice on this field instead of a create.
  final Group? smartschoolNamesake;

  /// The **bare** class name behind this record — `2F` for the sub-grouped
  /// class `2F ECO`, and simply the class name for a class without sub-groups
  /// (#228).
  ///
  /// [wisa] is keyed and named by the WISA `fullName` (the cross-system match
  /// key), which is what Smartschool spells a class by. The Office 365 group is
  /// named after the *parent* class instead — sub-groups get no group of their
  /// own — so without this the bare name is gone by the time an action sees the
  /// record. Carrying it here keeps the linker the single place that knows how a
  /// WISA class projects, rather than teaching every consumer to re-derive it.
  ///
  /// For an Azure-only orphan it is the name recovered from the group's
  /// `<PREFIX>-` display name ([azureClassNameOf]); `null` for a record with
  /// neither — a Smartschool-only orphan carries no WISA class to name.
  final String? className;

  const LinkedGroup({
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
    this.smartschoolNamesake,
    this.className,
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

/// #225: a WISA class whose name already exists in Smartschool as a group the
/// class link did not adopt — because the group is not flagged as an official
/// class, or because its name differs from the WISA one by more than the match
/// key tolerates.
///
/// The skip itself is legitimate (only official classes link), but it used to
/// be **silent**: the WISA class then looked unmatched, and the action engine
/// offered to create a class Smartschool already had. Every skipped namesake is
/// surfaced so the operator can see which class was passed over and why.
class SmartschoolNamesakeSkipped extends LinkWarning {
  /// The WISA class name as written (its `fullName`, the match key's source).
  final String wisaName;

  /// The Smartschool group carrying that name. [Group.official] says which of
  /// the two skip reasons applies; [Group.name] shows the name as Smartschool
  /// spells it.
  final Group smartschool;

  const SmartschoolNamesakeSkipped({
    required this.wisaName,
    required this.smartschool,
  });
}

/// What one of the records behind a [DuplicateLinkedId] holds — enough of each
/// colliding record for an operator (or a log line) to tell them apart.
///
/// Deliberately flattened to the per-system keys rather than carrying the
/// records themselves: a collision can be between two [LinkedAccount]s, two
/// [LinkedStaff], or one of each, and a single shape lets every consumer render
/// all three the same way.
class LinkedIdHolding {
  /// The role the colliding record was minted with.
  final PersonRole role;

  /// The WISA key — a student's `wisaId` or a staff member's `code`. Null when
  /// the record has no WISA side.
  final String? wisa;

  /// The Smartschool `uid`, or null when the record has no Smartschool side.
  final String? smartschool;

  /// The Azure object id, or null when the record has no Azure side.
  final String? azure;

  const LinkedIdHolding({
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
  });

  /// The holding of a colliding student record.
  factory LinkedIdHolding.ofAccount(LinkedAccount a) => LinkedIdHolding(
        role: a.role,
        wisa: a.wisa?.wisaId.value,
        smartschool: a.smartschool?.uid,
        azure: a.azure?.id,
      );

  /// The holding of a colliding staff record.
  factory LinkedIdHolding.ofStaff(LinkedStaff s) => LinkedIdHolding(
        role: s.role,
        wisa: s.wisa?.code.value,
        smartschool: s.smartschool?.uid,
        azure: s.azure?.id,
      );
}

/// INV-24: two or more linker records resolved to the same [LinkedAccountId].
///
/// Every layer below the linker is keyed by that id and each one degrades
/// differently and silently — the materializer hands both records the *union*
/// of their candidate actions, the Acties list keeps whichever pending entry
/// arrived last, and the shared store holds one document per id, so one record
/// is what every other operator inherits. The first sign of trouble used to be
/// an operator reading a card whose presence chips come from one record and
/// whose actions come from another (#319).
///
/// So a collision is reported as what it is — a linker invariant violation —
/// rather than merged away by each consumer's own assumption. Both records are
/// kept in the [LinkedSnapshot]: dropping one silently is the very failure
/// INV-23 exists to prevent. The tally counts the id once ([LinkCounts]), so
/// the dashboard's linked/total ratio does not drift while the collision lasts.
class DuplicateLinkedId extends LinkWarning {
  /// The id the colliding records share.
  final LinkedAccountId id;

  /// What each record claiming [id] holds; at least two, in snapshot order
  /// (students before staff).
  final List<LinkedIdHolding> holdings;

  const DuplicateLinkedId({required this.id, required this.holdings});
}

/// Per-system tally for one [LinkedSnapshot], mirroring the counters legacy
/// `LinkedAccounts.DoRelink` exposed.
///
/// A record counts toward [linked] when it is present in *every* system, and
/// toward [unlinked] when it is present in this system but missing from at
/// least one other. [total] == [linked] + [unlinked].
///
/// The unit is a **person**, not a record: [LinkedSnapshot.fromRecords] counts
/// each [LinkedAccountId] once, so a colliding id (INV-24, #319) cannot inflate
/// a system's total or skew the dashboard's linked/total ratio for as long as
/// the collision lasts.
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
  ///
  /// This is also where [LinkedAccountId] uniqueness (INV-24) is enforced, so
  /// the invariant lives with the type rather than in each consumer's
  /// assumptions (#319). Every record — student or staff — is bucketed by its
  /// id, and any id claimed more than once yields one [DuplicateLinkedId]
  /// warning appended to [warnings], in first-seen order.
  ///
  /// The colliding records are **kept**, never deduped away: a silent drop is
  /// what INV-23 exists to prevent, and one of the two is generally the record
  /// carrying the actions an operator is about to apply. What changes is that
  /// the collision is now loud, and that the tally below counts each id once —
  /// counting per record inflated a system's [total] by one per collision and
  /// skewed the dashboard's linked/total ratio.
  factory LinkedSnapshot.fromRecords({
    required List<LinkedAccount> accounts,
    required List<LinkedStaff> staff,
    required List<LinkedGroup> groups,
    List<LinkWarning> warnings = const [],
  }) {
    var wisaTotal = 0, wisaLinked = 0;
    var ssTotal = 0, ssLinked = 0;
    var azTotal = 0, azLinked = 0;

    // INV-24 bookkeeping: what each id is claimed by, in first-seen order so
    // the warnings a given input produces are deterministic (INV-20).
    final holdingsById = <String, List<LinkedIdHolding>>{};
    final idOrder = <String>[];
    final idByValue = <String, LinkedAccountId>{};

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

    /// Registers a record's claim on [id] and reports whether it is the first —
    /// the only claim that counts toward the tally, since the unit is a person.
    bool claim(LinkedAccountId id, LinkedIdHolding holding) {
      final key = id.value;
      final existing = holdingsById[key];
      if (existing == null) {
        idOrder.add(key);
        idByValue[key] = id;
        holdingsById[key] = <LinkedIdHolding>[holding];
        return true;
      }
      existing.add(holding);
      return false;
    }

    for (final a in accounts) {
      if (!claim(a.id, LinkedIdHolding.ofAccount(a))) continue;
      tally(
        inWisa: a.wisa != null,
        inSmartschool: a.smartschool != null,
        inAzure: a.azure != null,
      );
    }
    for (final s in staff) {
      if (!claim(s.id, LinkedIdHolding.ofStaff(s))) continue;
      tally(
        inWisa: s.wisa != null,
        inSmartschool: s.smartschool != null,
        inAzure: s.azure != null,
      );
    }

    final collisions = <DuplicateLinkedId>[
      for (final key in idOrder)
        if (holdingsById[key]!.length > 1)
          DuplicateLinkedId(
            id: idByValue[key]!,
            holdings: List<LinkedIdHolding>.unmodifiable(holdingsById[key]!),
          ),
    ];

    LinkCounts counts(int total, int linked) =>
        LinkCounts(total: total, linked: linked, unlinked: total - linked);

    return LinkedSnapshot(
      accounts: accounts,
      staff: staff,
      groups: groups,
      // A fresh list rather than an append: `warnings` is the caller's own
      // accumulator (and may be `const []`).
      warnings: collisions.isEmpty
          ? warnings
          : <LinkWarning>[...warnings, ...collisions],
      wisa: counts(wisaTotal, wisaLinked),
      smartschool: counts(ssTotal, ssLinked),
      azure: counts(azTotal, azLinked),
    );
  }
}
