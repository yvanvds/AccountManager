/// The mutually-exclusive-alternative collapse (#110), as one shared primitive.
///
/// Two layers have to answer the same question — "what are the *decisions* this
/// pile of actions really represents?" — over two different representations of
/// the same actions: the live `StudentAction` / `StaffAction` / `GroupAction`
/// the reconcile controller holds, and the flattened `CandidateAction` the
/// materialized view persists. Both partition on [StudentAction.alternativeGroup]
/// and pre-select [StudentAction.isDefaultAlternative]; #251 is what happens when
/// only one of them does it.
///
/// Pure and family-agnostic: the keys are read through the callers' accessors,
/// so nothing here knows about actions, candidates, or any concrete family.
library;

/// One decision point: a set of mutually-exclusive [options] of which exactly
/// one — [selected] — is the resolution that will actually run, plus whatever
/// [notices] are context for it.
///
/// A departed student's "unregister *vs* delete" pair is one [Alternatives] with
/// two options; an ordinary modify action is one with a single option. The
/// distinction is [isChoice].
class Alternatives<T> {
  Alternatives({
    required this.options,
    required this.selected,
    this.notices = const [],
  }) : assert(options.isNotEmpty);

  /// The mutually-exclusive options (at least one), in first-seen order.
  ///
  /// **Every one of them writes** (#329). An informational item — one with no
  /// automated write — is never an option here: it is context on the decision,
  /// which is what [notices] holds.
  final List<T> options;

  /// The pre-selected option — the declared default of the group, or the lone
  /// option. Callers that let an operator pick may substitute their own choice.
  final T selected;

  /// The informational items this decision carries as **context** (#329), in
  /// dispatch order — what a card states above the decision rather than offering
  /// as one of its answers.
  ///
  /// The rule they exist for: *a notice is context, not an alternative.* An
  /// action with no automated write and a real write are not comparable answers
  /// to one question, so pairing them as radios asked the operator to choose
  /// between "here is what is wrong" and "here is the one thing the app can do".
  /// The notice still has to be read — "go make this group official in
  /// Smartschool" is genuine instruction — so it stays on the decision it
  /// belongs to, marked as informational, without a radio of its own.
  ///
  /// Empty for every decision that carries no such notice, which is nearly all
  /// of them.
  final List<T> notices;

  /// True when this is a real either/or the operator resolves, false for a lone
  /// action. Since #329 both sides of such a choice always write.
  bool get isChoice => options.length > 1;
}

/// Collapses [items] into the decision points they represent (#110/#251/#329).
///
/// Items whose [groupOf] key is the same non-null string are alternatives of one
/// choice, ordered by where the group was first seen; every item with a `null`
/// key is a choice of its own, in place. Each group's [Alternatives.selected] is
/// the item [isDefault] marks — or, if a family ever forgets to mark one, the
/// first item of the group, which every dispatch keeps as the provisioning half
/// rather than the opt-out.
///
/// Counting the result — rather than the raw items — is what makes one either/or
/// one pending decision instead of two.
///
/// [noticeFor], when supplied, reads the situation an **informational** item is
/// context for (#329). Such an item is not a decision and never an option: it is
/// lifted out and attached to the choice keyed by the string it names, as
/// [Alternatives.notices]. That is what makes "an informational action never
/// stands in an either/or" a property of this one collapse rather than of every
/// caller that renders one. A notice naming a situation this list does not
/// contain becomes a lone choice of its own, at the end — it is still something
/// the operator has to read, and dropping a row silently is the one outcome that
/// would not be honest.
List<Alternatives<T>> collapseAlternatives<T>(
  Iterable<T> items, {
  required String? Function(T) groupOf,
  required bool Function(T) isDefault,
  String? Function(T)? noticeFor,
}) {
  final noticesByKey = <String, List<T>>{};
  final noticeKeyOrder = <String>[];
  if (noticeFor != null) {
    for (final item in items) {
      final key = noticeFor(item);
      if (key == null) continue;
      if (!noticesByKey.containsKey(key)) noticeKeyOrder.add(key);
      (noticesByKey[key] ??= <T>[]).add(item);
    }
  }

  final choices = <Alternatives<T>>[];
  final order = <String>[];
  final byGroup = <String, List<T>>{};
  for (final item in items) {
    if (noticeFor != null && noticeFor(item) != null) continue;
    final group = groupOf(item);
    if (group == null) {
      choices.add(Alternatives<T>(options: <T>[item], selected: item));
      continue;
    }
    if (!byGroup.containsKey(group)) order.add(group);
    (byGroup[group] ??= <T>[]).add(item);
  }
  for (final group in order) {
    final alternatives = byGroup[group]!;
    choices.add(Alternatives<T>(
      options: alternatives,
      selected:
          alternatives.firstWhere(isDefault, orElse: () => alternatives.first),
      notices: noticesByKey.remove(group) ?? const [],
    ));
  }
  for (final key in noticeKeyOrder) {
    for (final orphan in noticesByKey[key] ?? <T>[]) {
      choices.add(Alternatives<T>(options: <T>[orphan], selected: orphan));
    }
  }
  return choices;
}
