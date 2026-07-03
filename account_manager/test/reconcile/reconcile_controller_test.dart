import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/reconcile/log_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

void main() {
  group('first sync', () {
    test('pulls all three systems and derives the linked view + actions',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      expect(h.wisaSyncs, 1);
      expect(h.ssSyncs, 1);
      expect(h.azSyncs, 1);
      expect(h.controller.error, isNull);
      expect(h.controller.noChangesNeeded, isFalse);
      expect(h.controller.linked, isNotNull);
      // The fixture's one deterministic action: WISA says 3C, Smartschool 2B.
      expect(
        h.controller.linked!.studentActions
            .whereType<actions.MoveToSmartschoolClassGroup>(),
        hasLength(1),
      );
      expect(h.controller.pendingViews, isNotEmpty);
      expect(h.log.entries.where((e) => e.isError), isEmpty);
    });
  });

  group('smart WISA diff', () {
    test('an unchanged WISA re-sync reports "no changes needed" and stops',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      // Fresh pull, identical content (a new fetchedAt must not count).
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(h.wisaSyncs, 2, reason: 'WISA itself is re-pulled to diff');
      expect(h.ssSyncs, 1, reason: 'Smartschool is not re-read by default');
      expect(h.azSyncs, 1, reason: 'Azure is not re-read by default');
      expect(identical(h.controller.linked, linkedBefore), isTrue,
          reason: 'the existing linked view is kept, no re-link');
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('no account changes needed')),
      );
    });

    test('a changed WISA pull re-links without re-reading the other systems',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      h.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isFalse);
      expect(h.wisaSyncs, 2);
      expect(h.ssSyncs, 1);
      expect(h.azSyncs, 1);
      expect(identical(h.controller.linked, linkedBefore), isFalse,
          reason: 'a WISA change re-derives the linked view');
    });
  });

  group('check for drift', () {
    test('re-reads Smartschool and Azure and re-links', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      await h.controller.checkDrift();

      expect(h.ssSyncs, 2);
      expect(h.azSyncs, 2);
      expect(h.wisaSyncs, 1, reason: 'drift check does not re-pull WISA');
      expect(h.controller.linked, isNotNull);
    });
  });

  group('failures', () {
    test('a failing WISA sync surfaces the error and keeps the old view',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      h.wisaError = StateError('WISA host unreachable');
      await h.controller.sync();

      expect(h.controller.error, contains('WISA host unreachable'));
      expect(h.controller.busy, isFalse);
      expect(identical(h.controller.linked, linkedBefore), isTrue);
      expect(h.log.hasErrors, isTrue);
    });
  });

  group('dry-run', () {
    test('walks every applyable action with zero writes', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      await h.controller.dryRun();

      final results = h.controller.dryRunResults;
      expect(results, isNotNull);
      expect(results, isNotEmpty);
      expect(
        results!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.dryRun),
      );
      expect(
        results.map((r) => r.changes.summary),
        contains('Wijzig de klas in Smartschool'),
      );
      expect(h.soap.soapActions, isEmpty, reason: 'a dry run writes nothing');
      expect(h.graph.requests, isEmpty, reason: 'a dry run writes nothing');
      expect(h.controller.applyResults, isNull);
    });
  });

  group('apply', () {
    test('writes the pending actions and refreshes the linked view', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      await h.controller.applyAll();

      final results = h.controller.applyResults;
      expect(results, isNotNull);
      expect(
        results!
            .where((r) => r.changes.summary == 'Wijzig de klas in Smartschool')
            .single
            .outcome,
        actions.ActionOutcome.applied,
      );
      expect(h.soap.soapActions, isNotEmpty,
          reason: 'the class move is a real Smartschool write');
      expect(identical(h.controller.linked, linkedBefore), isFalse,
          reason: 'a real write re-links from the patched snapshot');
    });

    test('informational group actions are listed but never applied', () async {
      // An orphan Smartschool class (no WISA counterpart) surfaces the
      // informational DoNotImportFromSmartschool — visible in the pending
      // list, skipped by the apply pass (its apply() throws by contract).
      final h = ReconcileHarness(
        smartschool: ssSnap(
          groups: [
            ssGroup('2B', code: '2B_ss'),
            ssGroup('3C', code: '3C_ss'),
            ssGroup('9Z', code: '9Z_ss'),
          ],
        ),
      );
      await h.controller.sync();

      final informational = h.controller.pendingViews.where((v) => !v.canApply);
      expect(informational, isNotEmpty);
      expect(h.controller.applyableCount,
          lessThan(h.controller.pendingActions.length));

      await h.controller.applyAll();

      expect(h.controller.error, isNull);
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        isNot(contains(actions.ActionOutcome.failed)),
      );
    });
  });

  group('LogBuffer', () {
    test('caps its entries and reports errors', () {
      final log = LogBuffer(capacity: 3, clock: () => kFixtureDate);
      for (var i = 0; i < 5; i++) {
        log.addMessage(core.Origin.wisa, 'message $i');
      }
      expect(log.entries, hasLength(3));
      expect(log.entries.first.message, 'message 2');
      expect(log.hasErrors, isFalse);

      log.addError(core.Origin.azure, 'boom');
      expect(log.hasErrors, isTrue);

      log.clear();
      expect(log.entries, isEmpty);
    });
  });
}
