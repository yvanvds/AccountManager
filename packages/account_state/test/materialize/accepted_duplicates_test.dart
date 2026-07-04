import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Unit coverage for the accepted duplicate-mail decisions (#109): building and
/// matching the decision, the exact-set semantics that make a *changed* colliding
/// set re-warn, and the store round-trip (put / read / delete) through the
/// [InMemoryLinkedStore] seam. The Cosmos wire shape is covered separately by
/// `cosmos_linked_store_test`.
void main() {
  final t0 = DateTime.utc(2026, 7, 4, 9, 0);
  const id = core.LinkedAccountId('acc-1');

  AccountDecision accept({
    String mail = 'Dup@School.Example',
    List<String> uids = const ['user', 'admin'],
  }) =>
      acceptedDuplicateDecision(
        accountId: id,
        mail: mail,
        uids: uids,
        decidedBy: 'jan@school',
        decidedAt: t0,
      );

  group('acceptedDuplicateDecision', () {
    test('normalizes the mail and sorts+dedups the uids into the payload', () {
      final d = accept(
          mail: '  Dup@School.Example ', uids: ['user', 'admin', 'user']);
      expect(d.kind, DecisionKind.acceptedDuplicate);
      expect(d.targetKind, 'dup@school.example');
      expect(d.payload[acceptedDuplicateMailKey], 'dup@school.example');
      expect(d.payload[acceptedDuplicateUidsKey], ['admin', 'user']);
      expect(acceptedUidsOf(d), ['admin', 'user']);
    });

    test('round-trips through JSON', () {
      final d = accept();
      final back = AccountDecision.fromJson(d.toJson());
      expect(back.kind, DecisionKind.acceptedDuplicate);
      expect(back.accountId.value, 'acc-1');
      expect(acceptedUidsOf(back), ['admin', 'user']);
    });
  });

  group('matching', () {
    test('accepts the exact colliding set, case/space/order-insensitive', () {
      final decisions = [
        accept(uids: ['user', 'admin'])
      ];
      expect(
        duplicateAccepted(decisions,
            mail: 'dup@school.example ', uids: ['admin', 'user']),
        isTrue,
      );
      expect(
        findAcceptedDuplicate(decisions,
            mail: 'DUP@school.example', uids: ['user', 'admin']),
        isNotNull,
      );
    });

    test('a changed colliding set re-warns (not accepted)', () {
      final decisions = [
        accept(uids: ['user', 'admin'])
      ];
      // A third account joins the same mail — the stored set no longer matches.
      expect(
        duplicateAccepted(decisions,
            mail: 'dup@school.example', uids: ['admin', 'user', 'intruder']),
        isFalse,
      );
    });

    test('a different mail is not accepted', () {
      final decisions = [accept()];
      expect(
        duplicateAccepted(decisions,
            mail: 'other@school.example', uids: ['admin', 'user']),
        isFalse,
      );
    });

    test('a non-duplicate decision never matches', () {
      final other = AccountDecision(
        accountId: id,
        kind: DecisionKind.chosenAlternative,
        targetKind: 'SomeAction',
        decidedBy: 'jan@school',
        decidedAt: t0,
      );
      expect(
        duplicateAccepted([other], mail: 'x@y', uids: ['a', 'b']),
        isFalse,
      );
    });
  });

  group('store round-trip', () {
    test('put → read → delete through the LinkedStore seam', () async {
      final store = InMemoryLinkedStore();
      final d = accept();

      await store.putDecision(d);
      var read = await store.readDecisions();
      expect(read, hasLength(1));
      expect(
        duplicateAccepted(read,
            mail: 'dup@school.example', uids: ['admin', 'user']),
        isTrue,
      );

      await store.deleteDecision(d);
      read = await store.readDecisions();
      expect(read, isEmpty);
    });

    test('deleting an absent decision is a no-op', () async {
      final store = InMemoryLinkedStore();
      await store.deleteDecision(accept());
      expect(await store.readDecisions(), isEmpty);
    });
  });
}
