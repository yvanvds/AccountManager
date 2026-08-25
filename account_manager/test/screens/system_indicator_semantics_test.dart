/// #350 — the semantics tree the three system cells of a row serialize must
/// stay internally consistent while the operator sweeps the mouse across them.
///
/// The Windows embedder does not merely log a bad semantics update, it rejects
/// the whole thing: `ui::AXTree::Unserialize` fails with
/// `N will not be in the tree and is not the new root`, the accessibility tree
/// freezes for the life of the window, and the process has been observed to die
/// outright with no Dart exception to show for it. That only happens when
/// semantics are live — a screen reader attached, or an `integration_test` run
/// — which is why an ordinary session never sees it.
///
/// The engine-side invariant is simple enough to model from Dart: every node in
/// an update must be reachable from the root once the update is applied.
/// `_axTreeRejections` replays the real `SemanticsUpdateBuilder` traffic
/// through that rule, so this test fails for the same reason Windows fails,
/// without needing Windows.
///
/// What makes a row of ours trip it is upstream
/// https://github.com/flutter/flutter/issues/182444 and the diagnosis in
/// https://github.com/flutter/flutter/pull/190344: a `Tooltip` is an
/// `OverlayPortal`, whose overlay half is grafted onto its anchor by a
/// traversal-parent identifier, and that identifier is silently dropped when
/// the anchor's `SemanticsConfiguration` is absorbed into a neighbouring one.
/// A `ListView` supplies the second ingredient by describing its viewport with
/// two-pane semantics. Three adjacent tooltips in a scrolling row is exactly
/// that recipe, and [SystemIndicatorCell] is where this app writes it down.
///
/// Giving each tooltip its own semantics container is what stops the absorption
/// — see the note on [SystemIndicatorCell.build]. Without it this test records
/// ~90 rejected updates for a five-row sweep; with it, none.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/screens/action_tiles.dart'
    show ReadOnlyLock;
import 'package:account_manager/src/screens/system_indicator.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every `updateNode` call of one semantics update, as `id -> children`.
final List<Map<int, List<int>>> _updates = <Map<int, List<int>>>[];

/// Records the child lists the framework serializes, then hands the engine an
/// empty — but real — update, because the test view casts it to the native
/// type on the way out.
class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  final Map<int, List<int>> _nodes = <int, List<int>>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final int id = invocation.namedArguments[#id]! as int;
      final Int32List children =
          invocation.namedArguments[#childrenInTraversalOrder]! as Int32List;
      _nodes[id] = children.toList();
      return null;
    }
    if (invocation.memberName == #build) {
      _updates.add(Map<int, List<int>>.from(_nodes));
      return ui.SemanticsUpdateBuilder().build();
    }
    return null;
  }
}

class _RecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder();
}

/// The rejections `ui::AXTree::Unserialize` would have logged for the recorded
/// updates, as the node ids it would have named.
///
/// The engine keeps the nodes reachable from the root (id 0) between updates
/// and discards the rest, so an update may name a node whose parent it does not
/// resend — that is legal, and modelled here by merging each update into the
/// surviving tree before checking reachability.
List<int> _axTreeRejections() {
  final Map<int, List<int>> tree = <int, List<int>>{};
  final List<int> rejected = <int>[];
  for (final Map<int, List<int>> update in _updates) {
    final Map<int, List<int>> merged = Map<int, List<int>>.from(tree)
      ..addAll(update);
    final Set<int> reachable = <int>{};
    void walk(int id) {
      if (!reachable.add(id)) {
        return;
      }
      for (final int child in merged[id] ?? const <int>[]) {
        walk(child);
      }
    }

    if (merged.containsKey(0)) {
      walk(0);
    }
    for (final int id in update.keys) {
      if (!reachable.contains(id)) {
        rejected.add(id);
      }
    }
    tree
      ..clear()
      ..addEntries(merged.entries
          .where((MapEntry<int, List<int>> e) => reachable.contains(e.key)));
  }
  return rejected;
}

const List<core.Origin> _systems = <core.Origin>[
  core.Origin.wisa,
  core.Origin.smartschool,
  core.Origin.azure,
];

/// A stand-in for the Klasgroepen / Acties lists: rows of three system cells in
/// a scrolling viewport, which is the shape that matters here.
Widget _list({required bool withLock}) => MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            for (int row = 0; row < 8; row++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final core.Origin system in _systems)
                    Expanded(
                      child: SystemIndicatorCell(
                        key: ValueKey<String>('cell-$row-${system.name}'),
                        system: system,
                        state: SystemIndicatorState
                            .values[row % SystemIndicatorState.values.length],
                      ),
                    ),
                  if (withLock)
                    KeyedSubtree(
                      key: ValueKey<String>('lock-$row'),
                      child: const ReadOnlyLock(),
                    ),
                ],
              ),
          ],
        ),
      ),
    );

/// Sweeps the mouse across the tooltips of the first five rows three times,
/// pausing long enough for each to show and start dismissing — the interleave
/// that leaves one overlay fading out while the next is already up.
Future<void> _sweep(WidgetTester tester, {required bool withLock}) async {
  final TestGesture mouse =
      await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);

  Future<void> hover(Finder target) async {
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 20));
  }

  for (int pass = 0; pass < 3; pass++) {
    for (int row = 0; row < 5; row++) {
      for (final core.Origin system in _systems) {
        await hover(find.descendant(
          of: find.byKey(ValueKey<String>('cell-$row-${system.name}')),
          matching: find.byType(Icon),
        ));
      }
      if (withLock) {
        await hover(find.byKey(ValueKey<String>('lock-$row')));
      }
    }
  }
  await tester.pumpAndSettle();
}

void main() {
  _RecordingBinding();

  setUp(_updates.clear);

  testWidgets(
      'a mouse sweep across the system cells of a scrolling list '
      'serializes no unreachable semantics node', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    await tester.pumpWidget(_list(withLock: false));
    await _sweep(tester, withLock: false);
    semantics.dispose();

    expect(_updates, isNotEmpty,
        reason: 'the sweep must actually have moved tooltips in and out');
    expect(_axTreeRejections(), isEmpty,
        reason: 'ui::AXTree::Unserialize would reject these updates and the '
            'Windows accessibility tree would freeze — see #350');
  });

  // [ReadOnlyLock] is the app's other bare tooltip in a scrolling row, and it
  // is deliberately left as it is. A lone tooltip anchor cannot reach this
  // state: measured against the same harness, a row carrying one bare tooltip
  // records no rejection at all, because the fault needs a second overlay
  // showing while the first is still dismissing. Sweeping the lock into the
  // sequence is what pins that down — if a future row grows a second tooltip
  // beside it, or the framework widens the fault, this is where it surfaces
  // rather than on an operator's screen.
  testWidgets('the read-only lock swept in with them adds no rejection either',
      (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    await tester.pumpWidget(_list(withLock: true));
    await _sweep(tester, withLock: true);
    semantics.dispose();

    expect(_axTreeRejections(), isEmpty);
  });
}
