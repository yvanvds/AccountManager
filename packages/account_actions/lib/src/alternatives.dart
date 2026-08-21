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
/// one — [selected] — is the resolution that will actually run.
///
/// A departed student's "unregister *vs* delete" pair is one [Alternatives] with
/// two options; an ordinary modify action is one with a single option. The
/// distinction is [isChoice].
class Alternatives<T> {
  Alternatives({required this.options, required this.selected})
      : assert(options.isNotEmpty);

  /// The mutually-exclusive options (at least one), in first-seen order.
  final List<T> options;

  /// The pre-selected option — the declared default of the group, or the lone
  /// option. Callers that let an operator pick may substitute their own choice.
  final T selected;

  /// True when this is a real either/or the operator resolves, false for a lone
  /// action.
  bool get isChoice => options.length > 1;
}

/// Collapses [items] into the decision points they represent (#110/#251).
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
List<Alternatives<T>> collapseAlternatives<T>(
  Iterable<T> items, {
  required String? Function(T) groupOf,
  required bool Function(T) isDefault,
}) {
  final choices = <Alternatives<T>>[];
  final order = <String>[];
  final byGroup = <String, List<T>>{};
  for (final item in items) {
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
    ));
  }
  return choices;
}
