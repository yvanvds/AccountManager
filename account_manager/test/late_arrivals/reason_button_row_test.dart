/// The reason button row (#407 over #405's shared list).
library;

import 'package:account_manager/src/late_arrivals/reason_button_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';

const List<LateArrivalReason> _reasons = <LateArrivalReason>[
  LateArrivalReason('Bus of trein te laat'),
  LateArrivalReason('Verkeer'),
  LateArrivalReason('Verslapen', isValid: false),
];

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders the shared list in its own order, never re-sorted',
      (WidgetTester tester) async {
    // Order is load-bearing: `normalizeLateArrivalReasons` preserves it so the
    // reasons an operator reaches for most can be put first in Instellingen.
    // Regrouping the invalid entries to the end here would silently undo that.
    await tester.pumpWidget(_wrap(LateArrivalReasonButtons(
      reasons: _reasons,
      onPick: (_) {},
    )));

    for (int i = 0; i < _reasons.length; i++) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('late-reason-$i')),
          matching: find.text(_reasons[i].label),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('marks the entries that record an unexcused absence',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(LateArrivalReasonButtons(
      reasons: _reasons,
      onPick: (_) {},
    )));

    // The same badge Instellingen puts on the same entries, so the two surfaces
    // mark the same fact the same way.
    expect(find.text('ZONDER GELDIGE REDEN'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('late-reason-2')),
        matching: find.text('ZONDER GELDIGE REDEN'),
      ),
      findsOneWidget,
    );
    // Outlined rather than filled: the row separates at a glance across a desk.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('late-reason-2')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('hands back the reason that was pressed, flag and all',
      (WidgetTester tester) async {
    final List<LateArrivalReason> picked = <LateArrivalReason>[];
    await tester.pumpWidget(_wrap(LateArrivalReasonButtons(
      reasons: _reasons,
      onPick: picked.add,
    )));

    await tester.tap(find.byKey(const ValueKey<String>('late-reason-2')));
    await tester.pump();

    expect(picked, <LateArrivalReason>[_reasons[2]]);
    expect(picked.single.withoutValidReason, isTrue);
  });

  testWidgets(
      'a disabled row keeps its shape so nothing jumps between students',
      (WidgetTester tester) async {
    final List<LateArrivalReason> picked = <LateArrivalReason>[];
    await tester.pumpWidget(_wrap(LateArrivalReasonButtons(
      reasons: _reasons,
      onPick: picked.add,
      enabled: false,
    )));

    // Still on screen — a row that disappeared between one student and the next
    // would move the buttons under the operator's hand.
    expect(find.text('Verkeer'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-1')));
    await tester.pump();
    expect(picked, isEmpty);
  });
}
