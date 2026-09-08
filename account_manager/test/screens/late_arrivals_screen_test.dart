/// The scan tab (#407), driven the way the scanner drives it.
///
/// Every scan here is a real burst of key events into the screen's hidden focus
/// node followed by Enter — not a call into a method — because "the focus is
/// held" is the single claim this screen exists to make, and a test that reached
/// past the keyboard would prove nothing about it.
///
/// Nothing touches Smartschool, a printer or a sound card: the presence writer
/// is absent, the ticket transport is a recorder and the refusal tone is a
/// counter. The repo's live-testing policy keeps writes and live sessions out of
/// CI entirely, and a suite that made the build machine buzz would be its own
/// kind of failure.
library;

import 'dart:convert';

import 'package:account_manager/src/late_arrivals/late_arrival_desk.dart';
import 'package:account_manager/src/late_arrivals/late_arrival_printer.dart';
import 'package:account_manager/src/late_arrivals/operator_credentials.dart';
import 'package:account_manager/src/late_arrivals/refusal_beep.dart';
import 'package:account_manager/src/screens/late_arrivals_screen.dart';
import 'package:account_manager/src/settings/local_preferences.dart';
import 'package:account_manager/src/shell/shell_navigation.dart';
import 'package:account_state/account_state.dart'
    show
        AppSettings,
        CosmosContainerNotProvisioned,
        CosmosException,
        LiveSettings;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';

import '../reconcile/reconcile_fakes.dart';

/// Counts the refusal tone instead of sounding it.
class _CountingBeep implements RefusalBeep {
  int played = 0;

  @override
  void play() => played++;
}

/// Keeps every ticket that reached "the printer".
class _RecordingTransport implements TicketTransport {
  final List<List<int>> sent = <List<int>>[];

  @override
  Future<void> send({
    required String host,
    required int port,
    required List<int> bytes,
    required Duration timeout,
  }) async {
    sent.add(List<int>.of(bytes));
  }
}

/// The session's reconcile stack, seeded with the scan-tab roster.
///
/// `ssInitial` rather than `smartschool` is the load-bearing half: the desk
/// resolves out of the snapshot the launch **seeded** from the shared store, and
/// must never need a pull to answer a scan.
ReconcileHarness _harness({LiveSettings? live}) => ReconcileHarness(
      ssInitial: lateArrivalSnap(),
      smartschool: lateArrivalSnap(),
      liveSettings: live,
    );

/// The one printable character per key the scanner types.
const Map<String, LogicalKeyboardKey> _digits = <String, LogicalKeyboardKey>{
  '0': LogicalKeyboardKey.digit0,
  '1': LogicalKeyboardKey.digit1,
  '2': LogicalKeyboardKey.digit2,
  '3': LogicalKeyboardKey.digit3,
  '4': LogicalKeyboardKey.digit4,
  '5': LogicalKeyboardKey.digit5,
  '6': LogicalKeyboardKey.digit6,
  '7': LogicalKeyboardKey.digit7,
  '8': LogicalKeyboardKey.digit8,
  '9': LogicalKeyboardKey.digit9,
};

/// Scans [code] exactly as the wedge does: the digits, then Enter.
Future<void> _scan(WidgetTester tester, String code) async {
  for (final String character in code.split('')) {
    await tester.sendKeyEvent(_digits[character]!, character: character);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

/// The desk under the screen: a session-only journal, no mirror and no drain.
///
/// Registrations are real — appended, ordered, folded back on read — they simply
/// do not outlive the test, which is exactly what a headless run should get.
Future<LateArrivalDesk> _openDesk(WidgetTester tester) async {
  final LateArrivalDesk desk = LateArrivalDesk(
    journalStore: InMemoryJournalStore(),
    credentials: InMemoryOperatorCredentialStore(),
    deskId: 'test-balie',
  );
  await desk.start();
  addTearDown(desk.dispose);
  return desk;
}

/// This machine's remembered answers, already loaded — the printer address the
/// screen binds its printer to.
Future<LocalPreferences> _openPreferences(String host) async {
  final LocalPreferences preferences = LocalPreferences(
    InMemoryLocalPreferenceStore(<String, Object?>{
      if (host.isNotEmpty) 'lateArrivalPrinterHost': host,
    }),
  );
  await preferences.load();
  return preferences;
}

Widget _wrap({
  required LateArrivalDesk desk,
  required Widget child,
  LocalPreferences? preferences,
  ShellTab? tab,
}) =>
    MaterialApp(
      home: LocalPreferencesScope(
        // Nothing remembered by default, which is a machine with no ticket
        // printer configured — the honest state for a headless run.
        preferences: preferences ?? LocalPreferences.inMemory(),
        child: LateArrivalDeskScope(
          desk: desk,
          child: Scaffold(
            body: tab == null
                ? child
                // The shell tells the screen which destination is on show; naming
                // another one is the operator standing in Instellingen with this
                // tab still mounted behind it, keyboard handed back.
                : ShellNavigation(
                    go: (_) {},
                    current: tab,
                    child: child,
                  ),
          ),
        ),
      ),
    );

void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

final Finder _name = find.byKey(const ValueKey<String>('late-scan-name'));
final Finder _klas = find.byKey(const ValueKey<String>('late-scan-class'));
final Finder _idle = find.byKey(const ValueKey<String>('late-scan-idle'));
final Finder _unknown = find.byKey(const ValueKey<String>('late-scan-unknown'));
final Finder _incomplete =
    find.byKey(const ValueKey<String>('late-scan-incomplete'));
final Finder _refusal = find.byKey(const ValueKey<String>('late-refusal'));
final Finder _indicator =
    find.byKey(const ValueKey<String>('late-scanner-indicator'));

String _textOf(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).data ?? '';

void main() {
  testWidgets(
      'a scan shows the student\'s name and class immediately, with no '
      'network call and no photo (#407)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);
    final ReconcileHarness harness = _harness();

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(bootstrap: harness.bootstrap),
    ));
    await tester.pumpAndSettle();

    expect(_idle, findsOneWidget);

    await _scan(tester, '123456');

    expect(_textOf(tester, _name), 'Jonas Peeters');
    expect(_textOf(tester, _klas), '3MTa');
    // Nothing was pulled to answer that: the desk resolves out of the snapshot
    // the session already held.
    expect(harness.ssSyncs, 0);
    // And nothing is registered until a reason is pressed.
    expect(desk.journal!.records, isEmpty);
  });

  testWidgets('an unknown code says "leerling onbekend" and registers nothing',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    await _scan(tester, '424242');

    expect(_textOf(tester, _unknown), 'Leerling onbekend');
    expect(find.textContaining('424242'), findsWidgets);
    expect(desk.journal!.records, isEmpty);
    // No name is claimed for a code that matched nobody.
    expect(_name, findsNothing);
  });

  testWidgets(
      'a student who resolves by name but cannot be registered is reported '
      'apart from an unknown code, and names the repair',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    await _scan(tester, '999999');

    // The name and the class are on screen — that is the whole difference.
    expect(_textOf(tester, _name), 'Sam Vos');
    expect(_textOf(tester, _klas), '4EW');
    expect(_unknown, findsNothing);
    expect(
      _textOf(tester, _incomplete),
      contains('nog niet gekend in Smartschool'),
    );
    expect(desk.journal!.records, isEmpty);
    // …and no reason can be pressed for a student who cannot be registered.
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('late-reason-0')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
      'confirming with a reason journals the registration, prints the ticket '
      'and clears the screen', (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);
    final _RecordingTransport tickets = _RecordingTransport();
    final DateTime scannedAt = DateTime(2026, 9, 7, 8, 42);

    await tester.pumpWidget(_wrap(
      desk: desk,
      preferences: await _openPreferences('bonprinter.invalid'),
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
        ticketTransport: tickets,
        now: () => scannedAt,
      ),
    ));
    await tester.pumpAndSettle();

    await _scan(tester, '123456');
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
    await tester.pumpAndSettle();

    final List<LateArrivalRecord> records = desk.journal!.records;
    expect(records, hasLength(1));
    expect(records.single.displayName, 'Jonas Peeters');
    expect(records.single.className, '3MTa');
    expect(records.single.internalUserId, 12016);
    expect(records.single.classGroupId, 77);
    expect(records.single.reasonLabel, defaultLateArrivalReasons.first.label);
    expect(records.single.reasonIsValid, isTrue);
    // The pinned `HH:mm – reden` motivation, off the *scan* time.
    expect(
      records.single.motivation,
      composeMotivation(scannedAt, defaultLateArrivalReasons.first.label),
    );

    // The ticket went out — and only *after* the line was on disk, which is the
    // ordering the whole journal exists to guarantee.
    expect(tickets.sent, hasLength(1));

    // …and the screen is free for the next student.
    expect(_idle, findsOneWidget);
    expect(_name, findsNothing);
  });

  testWidgets(
      'an unexcused reason is journalled as such — one button, no second click',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    // The shipped list ends with two "zonder geldige reden" entries.
    final int index = defaultLateArrivalReasons
        .indexWhere((LateArrivalReason r) => !r.isValid);
    expect(index, greaterThan(-1));

    await _scan(tester, '123456');
    await tester.tap(find.byKey(ValueKey<String>('late-reason-$index')));
    await tester.pumpAndSettle();

    expect(desk.journal!.records.single.reasonIsValid, isFalse);
    // The invalid entries are marked as such on the button itself.
    expect(find.text('ZONDER GELDIGE REDEN'), findsWidgets);
  });

  testWidgets(
      'a scan arriving while the previous student is unconfirmed is refused: '
      'the first student stays, the tone sounds, nothing is registered',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);
    final _CountingBeep beep = _CountingBeep();

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
        beep: beep,
      ),
    ));
    await tester.pumpAndSettle();

    await _scan(tester, '123456');
    expect(_textOf(tester, _name), 'Jonas Peeters');

    await _scan(tester, '223344');

    // Not queued, not swapped, not auto-registered.
    expect(_textOf(tester, _name), 'Jonas Peeters');
    expect(beep.played, 1);
    expect(_textOf(tester, _refusal), contains('geweigerd'));
    expect(desk.journal!.records, isEmpty);

    // The first student is confirmed; the second rescans and is taken.
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
    await tester.pumpAndSettle();
    await _scan(tester, '223344');

    expect(_textOf(tester, _name), 'Lea Janssens');
    expect(_refusal, findsNothing);
    expect(beep.played, 1);
  });

  testWidgets('a stray Enter is silent — it neither refuses nor beeps',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);
    final _CountingBeep beep = _CountingBeep();

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
        beep: beep,
      ),
    ));
    await tester.pumpAndSettle();

    await _scan(tester, '123456');
    // Scanner noise: an Enter with nothing in front of it, while a student is
    // still waiting for a reason. Beeping here would be a false alarm.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(beep.played, 0);
    expect(_refusal, findsNothing);
    expect(_textOf(tester, _name), 'Jonas Peeters');
  });

  testWidgets(
      'two scans of the same student are both registered — the later '
      'one wins in Smartschool', (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    await _scan(tester, '123456');
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
    await tester.pumpAndSettle();
    await _scan(tester, '123456');
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-1')));
    await tester.pumpAndSettle();

    final List<LateArrivalRecord> records = desk.journal!.records;
    expect(records, hasLength(2));
    expect(records.first.reasonLabel, defaultLateArrivalReasons[0].label);
    expect(records.last.reasonLabel, defaultLateArrivalReasons[1].label);
    // Scan order is the drain's contract, so the correction must be last.
    expect(records.first.sequence, lessThan(records.last.sequence));
  });

  testWidgets(
      'the reason buttons follow an edit in Instellingen with no '
      'relaunch (#405)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);
    final LiveSettings live = LiveSettings();

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness(live: live).bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Bus of trein te laat'), findsOneWidget);
    expect(find.text('Fietspech'), findsNothing);

    live.publish(live.current.copyWith(
      lateArrivalReasons: const <LateArrivalReason>[
        LateArrivalReason('Fietspech'),
        LateArrivalReason('Verslapen', isValid: false),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Fietspech'), findsOneWidget);
    expect(find.text('Bus of trein te laat'), findsNothing);
  });

  testWidgets(
      'an emptied reason list falls back to the shipped one rather '
      'than to a dead screen', (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);
    final LiveSettings live = LiveSettings(
      const AppSettings(lateArrivalReasons: <LateArrivalReason>[]),
    );

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness(live: live).bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(defaultLateArrivalReasons.first.label), findsOneWidget);
  });

  testWidgets(
      'the indicator says whether the keyboard is held — not whether a '
      'scanner is attached (#413) — and the focus is taken back',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    final String badge = tester
            .widget<Text>(find.descendant(
              of: _indicator,
              matching: find.byType(Text),
            ))
            .data ??
        '';
    expect(badge, 'KLAAR OM TE SCANNEN');
    // No scanner is plugged into the machine running this test, and nothing in
    // the app could see one if it were — so the badge may not name the hardware.
    expect(badge, isNot(contains('SCANNER ')));

    // Something else took the keyboard — the single worst thing that can happen
    // to this screen, because a scan is then swallowed with no error at all.
    final FocusNode thief = FocusNode();
    addTearDown(thief.dispose);
    FocusManager.instance.rootScope.requestFocus(thief);
    await tester.pumpAndSettle();

    // …and the screen took it straight back, so the next scan still lands.
    await _scan(tester, '123456');
    expect(_textOf(tester, _name), 'Jonas Peeters');
  });

  testWidgets(
      'without the keyboard the badge says scanning is paused, not that a '
      'scanner went missing (#413)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      // The operator is typing in Instellingen, so this screen hands the
      // keyboard back and stops reclaiming it.
      tab: ShellTab.instellingen,
    ));
    await tester.pumpAndSettle();

    final String badge = tester
            .widget<Text>(find.descendant(
              of: _indicator,
              matching: find.byType(Text),
            ))
            .data ??
        '';
    expect(badge, 'SCANNEN GEPAUZEERD');
    expect(badge, isNot(contains('SCANNER ')));

    // The half that is actionable stays exactly as it was.
    expect(
      _textOf(tester, find.byKey(const ValueKey<String>('late-scanner-hint'))),
      'Klik op dit scherm om verder te kunnen scannen.',
    );
  });

  testWidgets('the outstanding count is visible and moves with the queue',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('late-queue-outstanding')),
      findsOneWidget,
    );
    expect(find.text('0 IN WACHTRIJ'), findsOneWidget);

    await _scan(tester, '123456');
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
    await tester.pumpAndSettle();

    expect(find.text('1 IN WACHTRIJ'), findsOneWidget);
  });

  testWidgets('a machine with no printer says so and still registers',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      preferences: await _openPreferences(''),
      child: LateArrivalsScreen(
        bootstrap: _harness().bootstrap,
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      _textOf(tester, find.byKey(const ValueKey<String>('late-printer-note'))),
      contains('geen ticketprinter'),
    );

    await _scan(tester, '123456');
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
    await tester.pumpAndSettle();

    expect(desk.journal!.records, hasLength(1));
  });

  testWidgets(
      'an unconfigured build says the list cannot be loaded instead of '
      'pretending to scan', (WidgetTester tester) async {
    _useTallWindow(tester);
    final LateArrivalDesk desk = await _openDesk(tester);

    await tester.pumpWidget(_wrap(
      desk: desk,
      child: const LateArrivalsScreen(bootstrap: null),
    ));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('late-no-bootstrap')),
      findsOneWidget,
    );

    await _scan(tester, '123456');
    expect(desk.journal!.records, isEmpty);
    expect(_textOf(tester, _refusal), contains('nog niet geladen'));
  });

  group('the desk notes keep the machine words out of the sentence (#414)', () {
    testWidgets(
        'a failed bootstrap is one sentence, with the raw Cosmos error behind '
        'Details', (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(
          bootstrap: () async => throw _unprovisionedContainer,
        ),
      ));
      await tester.pumpAndSettle();

      // The line the operator reads: no header lengths, no replica URI, no SDK
      // version — the things that used to run the sentence off the screen.
      final String note = _textOf(
        tester,
        find.byKey(const ValueKey<String>('late-list-error')),
      );
      expect(note, contains('De leerlingenlijst kon niet geladen worden.'));
      expect(note, contains('niet gescand worden'));
      expect(note, isNot(contains('CosmosException')));
      expect(note, isNot(contains('x-ms-')));
      expect(note, isNot(contains('Microsoft.Azure.Documents.Common')));

      // Folded away, not thrown away.
      final Finder detail =
          find.byKey(const ValueKey<String>('late-note-detail'));
      expect(detail, findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('late-note-details')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<SelectableText>(detail).data,
        contains('lateArrivals'),
      );
      expect(
        tester.widget<SelectableText>(detail).data,
        contains('tool/provision-cosmos.ps1'),
      );

      // And it folds back.
      await tester.tap(find.byKey(const ValueKey<String>('late-note-details')));
      await tester.pumpAndSettle();
      expect(detail, findsNothing);
    });

    testWidgets('a note with nothing beneath it offers no Details at all',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: const LateArrivalsScreen(bootstrap: null),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('late-no-bootstrap')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('late-note-details')),
        findsNothing,
      );
    });
  });
}

/// What an unprovisioned `lateArrivals` container actually threw at the desk:
/// a legible sentence naming the container and the script that creates it,
/// carrying Cosmos's own AAD wall of text underneath (#414).
final CosmosException _unprovisionedContainer = CosmosContainerNotProvisioned(
  'lateArrivals',
  403,
  jsonEncode(<String, String>{
    'code': 'Forbidden',
    'message': 'Request blocked by Auth accountmanager-cosmos-arcadia : The '
        'given request [POST /dbs/accountmanager/colls] cannot be authorized by '
        'AAD token in data plane. Learn more: https://aka.ms/cosmos-native-rbac. '
        'ActivityId: 0000, Microsoft.Azure.Documents.Common/2.14.0, '
        'x-ms-request-charge: 0, x-ms-session-token: 0:-1#42',
  }),
);
