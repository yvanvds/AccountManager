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

import 'dart:async';
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

/// Keeps every ticket that reached "the printer", and the address it was
/// addressed to — which is what a desk's printer selection (#436) decides.
///
/// [gate], when set, holds every send until it is completed: that is how a
/// printer switch can be made while a ticket is still queued behind one.
class _RecordingTransport implements TicketTransport {
  _RecordingTransport({this.gate});

  final Completer<void>? gate;

  final List<List<int>> sent = <List<int>>[];
  final List<String> hosts = <String>[];

  @override
  Future<void> send({
    required String host,
    required int port,
    required List<int> bytes,
    required Duration timeout,
  }) async {
    if (gate != null) await gate!.future;
    hosts.add(host);
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
///
/// [store] replaces the in-memory journal store — the gated one below, for a
/// test that has to look at the screen while a registration is being written.
Future<LateArrivalDesk> _openDesk(
  WidgetTester tester, {
  JournalStore? store,
}) async {
  final LateArrivalDesk desk = LateArrivalDesk(
    journalStore: store ?? InMemoryJournalStore(),
    credentials: InMemoryOperatorCredentialStore(),
    deskId: 'test-balie',
  );
  await desk.start();
  addTearDown(desk.dispose);
  return desk;
}

/// A shared settings document holding one ticket printer (#435) — what the
/// screen binds its printer to, address and ticket header (#429) both.
///
/// Shared rather than machine-local since #435: the printer a desk prints on
/// comes out of the document every desk reads, not out of `preferences.json`.
LiveSettings _liveWithPrinter(String host, {String header = ''}) =>
    LiveSettings(AppSettings(ticketPrinters: <TicketPrinter>[
      TicketPrinter(
        id: 'balie-printer',
        label: 'Balie',
        host: host,
        header: header,
      ),
    ]));

/// This machine's preferences with [id] already chosen as the printer this desk
/// prints on (#436) — a desk that was configured on some earlier day, which is
/// what every desk in use is.
///
/// Passing no id is a machine nobody has pointed at a printer yet: the honest
/// state of a fresh install, and the one where no ticket comes out.
Future<LocalPreferences> _prefsWithPrinter([String? id]) async {
  final LocalPreferences preferences = LocalPreferences(
    InMemoryLocalPreferenceStore(<String, Object?>{
      if (id != null) 'lateArrivalPrinterId': id,
    }),
  );
  await preferences.load();
  return preferences;
}

/// Opens the printer menu and picks the entry keyed [option] — the whole
/// gesture, including the frame the menu route needs to settle.
Future<void> _pickPrinter(WidgetTester tester, String option) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey<String>('late-printer-select')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('late-printer-select')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey<String>('late-printer-option-$option')));
  await tester.pumpAndSettle();
}

/// What the selector currently shows as this desk's printer.
String _selectedPrinter(WidgetTester tester) =>
    tester
        .widget<Text>(
          find.byKey(const ValueKey<String>('late-printer-selected')),
        )
        .data ??
    '';

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
final Finder _cancel = find.byKey(const ValueKey<String>('late-scan-cancel'));

String _textOf(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).data ?? '';

/// What the **klaar om te scannen** badge says.
String _indicatorText(WidgetTester tester) =>
    tester
        .widget<Text>(
            find.descendant(of: _indicator, matching: find.byType(Text)))
        .data ??
    '';

/// The student the queue tests journal directly — Jonas Peeters of the
/// scan-tab roster, with the identifiers a Presence write addresses.
const ScannedStudent _jonas = ScannedStudent(
  scanCode: '123456',
  wisaId: '123456',
  smartschoolUid: 'jonas.peeters',
  displayName: 'Jonas Peeters',
  className: '3MTa',
  internalUserId: 12016,
  classGroupId: 77,
);

/// A shared settings document naming the school's Smartschool site — what the
/// desk needs, beside a login, before it attaches a drain.
AppSettings _withSmartschoolSite() {
  const AppSettings base = AppSettings();
  return base.copyWith(
    smartschool: base.smartschool.copyWith(uri: 'arcadia.smartschool.be'),
  );
}

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
      // A desk that picked its printer on some earlier day (#436) — which is
      // what every desk in use is, and the state a ticket comes out of.
      preferences: await _prefsWithPrinter('balie-printer'),
      child: LateArrivalsScreen(
        bootstrap: _harness(
          live: _liveWithPrinter('bonprinter.invalid', header: 'SMA'),
        ).bootstrap,
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
    // …carrying the chosen printer's header (#429, on the printer entry since
    // #435), the scan date and the scan time (#430).
    expect(tickets.sent.single, containsAllInOrder(encodeCp1252('SMA')));
    expect(
      tickets.sent.single,
      containsAllInOrder(encodeCp1252(formatTicketDate(scannedAt))),
    );
    expect(tickets.sent.single, containsAllInOrder(encodeCp1252('08:42')));

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
    // …and it names the way out of a wrong scan (#457).
    expect(_textOf(tester, _refusal), contains('druk op Annuleren'));
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

  group('a wrong scan can be cancelled before a reason is picked (#457)', () {
    /// What the **klaar om te scannen** badge currently says.
    String indicator(WidgetTester tester) =>
        tester
            .widget<Text>(find.descendant(
              of: _indicator,
              matching: find.byType(Text),
            ))
            .data ??
        '';

    testWidgets(
        'Annuleren is offered only while a registerable student is held',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      // Nothing on screen, nothing to cancel.
      expect(_idle, findsOneWidget);
      expect(_cancel, findsNothing);

      // An unknown or incomplete scan is replaced by the next one anyway, so it
      // has no use for a way out.
      await _scan(tester, '424242');
      expect(_unknown, findsOneWidget);
      expect(_cancel, findsNothing);
      await _scan(tester, '999999');
      expect(_incomplete, findsOneWidget);
      expect(_cancel, findsNothing);

      await _scan(tester, '123456');
      expect(_textOf(tester, _name), 'Jonas Peeters');
      expect(_cancel, findsOneWidget);
      expect(
        find.descendant(of: _cancel, matching: find.text('Annuleren')),
        findsOneWidget,
      );
      expect(tester.widget<ButtonStyleButton>(_cancel).enabled, isTrue);
    });

    testWidgets(
        'Annuleren lets go of the student with nothing journalled or printed, '
        'hands the keyboard back, and the next scan is taken without a beep',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final _CountingBeep beep = _CountingBeep();
      final _RecordingTransport tickets = _RecordingTransport();

      await tester.pumpWidget(_wrap(
        desk: desk,
        // A desk with a printer, so a ticket that should not exist would show.
        preferences: await _prefsWithPrinter('balie-printer'),
        child: LateArrivalsScreen(
          bootstrap: _harness(
            live: _liveWithPrinter('bonprinter.invalid'),
          ).bootstrap,
          beep: beep,
          ticketTransport: tickets,
        ),
      ));
      await tester.pumpAndSettle();

      // The wrong card, and then the right one — refused behind it, which is
      // the dead end this closes.
      await _scan(tester, '123456');
      await _scan(tester, '223344');
      expect(_textOf(tester, _name), 'Jonas Peeters');
      expect(beep.played, 1);
      expect(_refusal, findsOneWidget);

      await tester.tap(_cancel);
      await tester.pumpAndSettle();

      // Gone, refusal and all, and nothing was written or printed for him.
      expect(_name, findsNothing);
      expect(_idle, findsOneWidget);
      expect(_refusal, findsNothing);
      expect(_cancel, findsNothing);
      expect(desk.journal!.records, isEmpty);
      expect(tickets.sent, isEmpty);
      // The button did not keep the keyboard: the scanner has it.
      expect(indicator(tester), 'KLAAR OM TE SCANNEN');

      // The right student rescans and is taken, with no second refusal tone.
      await _scan(tester, '223344');
      expect(_textOf(tester, _name), 'Lea Janssens');
      expect(_refusal, findsNothing);
      expect(beep.played, 1);

      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      expect(
        desk.journal!.records.map((LateArrivalRecord r) => r.displayName),
        <String>['Lea Janssens'],
      );
      expect(tickets.sent, hasLength(1));
      expect(String.fromCharCodes(tickets.sent.single), contains('Lea'));
      expect(
        String.fromCharCodes(tickets.sent.single),
        isNot(contains('Jonas')),
      );
    });

    testWidgets(
        'Escape cancels a held student, and is left alone when there is '
        'nothing to cancel', (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final _CountingBeep beep = _CountingBeep();

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap, beep: beep),
      ));
      await tester.pumpAndSettle();

      // Nothing held: the key is not this screen's to take.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse);
      await tester.pumpAndSettle();
      expect(_idle, findsOneWidget);

      // An unknown code is not a student to let go of either.
      await _scan(tester, '424242');
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse);
      await tester.pumpAndSettle();
      expect(_unknown, findsOneWidget);

      await _scan(tester, '123456');
      await _scan(tester, '223344');
      expect(_refusal, findsOneWidget);

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
      await tester.pumpAndSettle();

      expect(_name, findsNothing);
      expect(_idle, findsOneWidget);
      expect(_refusal, findsNothing);
      expect(desk.journal!.records, isEmpty);
      expect(indicator(tester), 'KLAAR OM TE SCANNEN');

      await _scan(tester, '223344');
      expect(_textOf(tester, _name), 'Lea Janssens');
      expect(beep.played, 1);
    });

    testWidgets(
        'neither the button nor Escape lets go while the registration is '
        'being written', (WidgetTester tester) async {
      // By then the journal line may already be on disk and the ticket about
      // to print: a screen that dropped the student would no longer say what
      // is happening to them.
      _useTallWindow(tester);
      final _GatedJournalStore store = _GatedJournalStore();
      final LateArrivalDesk desk = await _openDesk(tester, store: store);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      await _scan(tester, '123456');
      final Completer<void> gate = Completer<void>();
      store.gate = gate;
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pump();

      // The write is in flight.
      expect(tester.widget<ButtonStyleButton>(_cancel).enabled, isFalse);
      await tester.tap(_cancel);
      await tester.pump();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse);
      await tester.pump();
      expect(_textOf(tester, _name), 'Jonas Peeters');

      // …and it lands exactly as it would have with no cancel attempted.
      gate.complete();
      await tester.pumpAndSettle();
      expect(desk.journal!.records.single.displayName, 'Jonas Peeters');
      expect(_idle, findsOneWidget);
    });

    testWidgets(
        'a registration that could not be written can be cancelled once it is '
        'entered in Smartschool by hand', (WidgetTester tester) async {
      // The other dead end the cancel opens: the error tells the operator to
      // register the student in Smartschool themselves, after which the only
      // thing left on screen is a student nobody should press a reason for.
      _useTallWindow(tester);
      final _GatedJournalStore store = _GatedJournalStore();
      final LateArrivalDesk desk = await _openDesk(tester, store: store);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      await _scan(tester, '123456');
      store.failure = const _DiskFull();
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();

      final Finder error =
          find.byKey(const ValueKey<String>('late-register-error'));
      expect(_textOf(tester, error), contains('niet bewaard'));
      expect(_textOf(tester, _name), 'Jonas Peeters');

      await tester.tap(_cancel);
      await tester.pumpAndSettle();

      expect(error, findsNothing);
      expect(_name, findsNothing);
      expect(_idle, findsOneWidget);
      expect(desk.journal!.records, isEmpty);
    });
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

  group('a failed registration can be retried, or settled by hand (#460)', () {
    final Finder failedBadge =
        find.byKey(const ValueKey<String>('late-queue-failed'));
    final Finder retry = find.byKey(const ValueKey<String>('late-queue-retry'));
    final Finder dialog =
        find.byKey(const ValueKey<String>('late-handled-dialog'));

    /// Journals Jonas Peeters and gives him up on with [error] — what the
    /// drain leaves behind after Smartschool refused the write.
    Future<LateArrivalRecord> failOne(
      LateArrivalDesk desk, {
      String error = 'Empty response from /Presence/Main/getConfig.',
    }) async {
      final LateArrivalJournal journal = desk.journal!;
      final LateArrivalRecord record = await journal.register(
        scan: const ScanRegisterable(_jonas),
        scannedAt: DateTime(2026, 9, 7, 8, 42),
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );
      await journal.markSent(record.id);
      return journal.markFailed(record.id, error);
    }

    testWidgets(
        'Opnieuw proberen sends the failed registration again, and the line '
        'goes from mislukt to verstuurd', (WidgetTester tester) async {
      _useTallWindow(tester);
      final _ScriptedWriter writer = _ScriptedWriter()
        ..failures.add(const PresenceRejected(
            'Empty response from /Presence/Main/getConfig.'));
      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: InMemoryJournalStore(),
        credentials: InMemoryOperatorCredentialStore(
          const SmartschoolOperatorLogin(
            username: 'ann.peeters',
            password: 'geheim',
          ),
        ),
        deskId: 'test-balie',
        settings: LiveSettings(_withSmartschoolSite()),
        writerFor: (_, __) => writer,
      );
      await desk.start();
      addTearDown(desk.dispose);
      expect(desk.draining, isTrue);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      await _scan(tester, '123456');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();

      final LateArrivalRecord record = desk.journal!.records.single;
      expect(record.status, LateArrivalStatus.failed);
      expect(find.text('1 MISLUKT'), findsOneWidget);
      expect(
        _textOf(
          tester,
          find.byKey(ValueKey<String>('late-queue-failure-${record.id}')),
        ),
        contains('getConfig'),
      );

      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(writer.written, <int>[12016]);
      expect(
        desk.journal!.byId(record.id)!.status,
        LateArrivalStatus.confirmed,
      );
      expect(failedBadge, findsNothing);
      expect(find.text('0 IN WACHTRIJ'), findsOneWidget);
      expect(
        _textOf(tester, find.byKey(const ValueKey<String>('late-queue-line'))),
        'Alles is naar Smartschool verstuurd.',
      );
      expect(retry, findsNothing);
    });

    testWidgets(
        'Manueel ingevoerd asks first; Annuleren leaves the record exactly as '
        'it was', (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final LateArrivalRecord record = await failOne(desk);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();
      expect(find.text('1 MISLUKT'), findsOneWidget);

      await tester.tap(
        find.byKey(ValueKey<String>('late-queue-handled-${record.id}')),
      );
      await tester.pumpAndSettle();

      expect(dialog, findsOneWidget);
      expect(
        _textOf(
          tester,
          find.byKey(const ValueKey<String>('late-handled-message')),
        ),
        allOf(
          contains('Jonas Peeters (3MTa)'),
          contains('niet naar Smartschool verstuurd'),
          contains('zelf in Smartschool hebt ingevoerd'),
        ),
      );

      await tester
          .tap(find.byKey(const ValueKey<String>('late-handled-cancel')));
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(desk.journal!.byId(record.id)!.status, LateArrivalStatus.failed);
      expect(find.text('1 MISLUKT'), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('late-queue-failure-${record.id}')),
        findsOneWidget,
      );
      // The keyboard is the scanner's again: the next card lands.
      await _scan(tester, '223344');
      expect(_textOf(tester, _name), 'Lea Janssens');
    });

    testWidgets(
        'confirming takes the line off the list for good, and the record stays '
        'in the journal', (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final LateArrivalRecord record = await failOne(desk);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(ValueKey<String>('late-queue-handled-${record.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('late-handled-confirm')),
      );
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(failedBadge, findsNothing);
      expect(
        find.byKey(ValueKey<String>('late-queue-failure-${record.id}')),
        findsNothing,
      );
      expect(retry, findsNothing);
      expect(
        _textOf(tester, find.byKey(const ValueKey<String>('late-queue-line'))),
        'Alles is naar Smartschool verstuurd.',
      );
      expect(
        desk.journal!.records.single.status,
        LateArrivalStatus.handledManually,
      );
      expect(_indicatorText(tester), 'KLAAR OM TE SCANNEN');
      await _scan(tester, '223344');
      expect(_textOf(tester, _name), 'Lea Janssens');
    });

    testWidgets(
        'a confirmation that cannot be written says so, and the record stays '
        'mislukt', (WidgetTester tester) async {
      _useTallWindow(tester);
      final _GatedJournalStore store = _GatedJournalStore();
      final LateArrivalDesk desk = await _openDesk(tester, store: store);
      final LateArrivalRecord record = await failOne(desk);
      store.failure = const _DiskFull();

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(ValueKey<String>('late-queue-handled-${record.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('late-handled-confirm')),
      );
      await tester.pumpAndSettle();

      expect(
        _textOf(tester, find.byKey(const ValueKey<String>('late-queue-error'))),
        allOf(contains('schijf vol'), contains('staat nog als mislukt')),
      );
      expect(desk.journal!.byId(record.id)!.status, LateArrivalStatus.failed);
      expect(find.text('1 MISLUKT'), findsOneWidget);
    });
  });

  group('a failed line keeps the machine words behind Details (#463)', () {
    /// What `describePresenceFailure` leaves on a record the drain gave up on
    /// after a gateway's 502: the operator's sentence, then the library's own.
    const String unreadable =
        'Smartschool gaf een antwoord dat niet gelezen kon worden (HTTP 502). '
        'Meestal is Smartschool dan even niet bereikbaar; probeer opnieuw '
        'zodra het weer werkt.\n'
        'SmartschoolPresenceUnreadableAnswerError: Smartschool answered '
        '/Presence/Main/getConfig with an HTML page instead of JSON (HTTP 502, '
        'title "502 Bad Gateway", heading "502 Bad Gateway").';

    Future<LateArrivalRecord> failJonas(
      LateArrivalDesk desk,
      String error,
    ) async {
      final LateArrivalJournal journal = desk.journal!;
      final LateArrivalRecord record = await journal.register(
        scan: const ScanRegisterable(_jonas),
        scannedAt: DateTime(2026, 9, 7, 8, 42),
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );
      await journal.markSent(record.id);
      return journal.markFailed(record.id, error);
    }

    testWidgets(
        'the line is the sentence alone, and Details opens and folds the '
        'library\'s text', (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final LateArrivalRecord record = await failJonas(desk, unreadable);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      expect(
        _textOf(
          tester,
          find.byKey(ValueKey<String>('late-queue-failure-${record.id}')),
        ),
        'Jonas Peeters, 3MTa — Smartschool gaf een antwoord dat niet gelezen '
        'kon worden (HTTP 502). Meestal is Smartschool dan even niet '
        'bereikbaar; probeer opnieuw zodra het weer werkt.',
      );

      final Finder details = find
          .byKey(ValueKey<String>('late-queue-failure-details-${record.id}'));
      final Finder detail = find
          .byKey(ValueKey<String>('late-queue-failure-detail-${record.id}'));
      expect(detail, findsNothing);

      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(detail).data,
        allOf(
          startsWith('SmartschoolPresenceUnreadableAnswerError: '),
          contains('502 Bad Gateway'),
        ),
      );

      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(detail, findsNothing);

      // The keyboard is the scanner's again after the click.
      await _scan(tester, '223344');
      expect(_textOf(tester, _name), 'Lea Janssens');
    });

    testWidgets('a reason on one line stands whole, with no Details',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final LateArrivalRecord record =
          await failJonas(desk, 'Geen schrijfrechten voor deze klas.');

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      expect(
        _textOf(
          tester,
          find.byKey(ValueKey<String>('late-queue-failure-${record.id}')),
        ),
        'Jonas Peeters, 3MTa — Geen schrijfrechten voor deze klas.',
      );
      expect(
        find.byKey(ValueKey<String>('late-queue-failure-details-${record.id}')),
        findsNothing,
      );
    });
  });

  testWidgets('a desk with no printer says so and still registers',
      (WidgetTester tester) async {
    // An empty shared list (#435) is a configuration, not a gap — no ticket
    // comes out, and the registration is unaffected.
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
      _textOf(tester, find.byKey(const ValueKey<String>('late-printer-note'))),
      contains('geen ticketprinter'),
    );

    await _scan(tester, '123456');
    await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
    await tester.pumpAndSettle();

    expect(desk.journal!.records, hasLength(1));
  });

  group('the printer this desk prints on (#436)', () {
    /// Two named printers in the shared document, at two desks, with two
    /// school codes on their tickets — the configuration this whole slice
    /// exists for.
    LiveSettings twoPrinters() =>
        LiveSettings(const AppSettings(ticketPrinters: <TicketPrinter>[
          TicketPrinter(
            id: 'p-onthaal',
            label: 'Onthaal',
            host: 'bon-onthaal.invalid',
            header: 'SMA',
          ),
          TicketPrinter(
            id: 'p-toren',
            label: 'Toren',
            host: 'bon-toren.invalid',
            header: 'SMT',
          ),
        ]));

    testWidgets(
        'the selector lists every shared printer by label, binds the one the '
        'operator picks and remembers it on this machine',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final _RecordingTransport tickets = _RecordingTransport();
      final LocalPreferences preferences = await _prefsWithPrinter();

      await tester.pumpWidget(_wrap(
        desk: desk,
        preferences: preferences,
        child: LateArrivalsScreen(
          bootstrap: _harness(live: twoPrinters()).bootstrap,
          ticketTransport: tickets,
        ),
      ));
      await tester.pumpAndSettle();

      // Nothing chosen yet: an install nobody has pointed at a printer.
      expect(_selectedPrinter(tester), 'Geen printer');

      await tester.tap(
        find.byKey(const ValueKey<String>('late-printer-select')),
      );
      await tester.pumpAndSettle();
      // Every entry, by label, in the shared list's order — plus the way out.
      expect(
        find.byKey(const ValueKey<String>('late-printer-option-none')),
        findsOneWidget,
      );
      final double onthaalY = tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('late-printer-option-p-onthaal')),
          )
          .dy;
      final double torenY = tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('late-printer-option-p-toren')),
          )
          .dy;
      expect(onthaalY, lessThan(torenY));

      await tester.tap(
        find.byKey(const ValueKey<String>('late-printer-option-p-toren')),
      );
      await tester.pumpAndSettle();
      expect(_selectedPrinter(tester), 'Toren');

      // Bound immediately: the very next ticket goes to that printer, with the
      // header that rides on the entry (#429).
      await _scan(tester, '123456');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      expect(tickets.hosts, <String>['bon-toren.invalid']);
      expect(tickets.sent.single, containsAllInOrder(encodeCp1252('SMT')));

      // …and it is the *id* that was written to this machine, so an
      // administrator moving that printer to a new IP cannot unselect the desk.
      expect(preferences.lateArrivalPrinterId, 'p-toren');
      expect(
        jsonEncode(await preferences.store.read()),
        isNot(contains('bon-toren.invalid')),
      );

      // Switching rebinds, and re-remembers.
      await _pickPrinter(tester, 'p-onthaal');
      await _scan(tester, '223344');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      expect(tickets.hosts.last, 'bon-onthaal.invalid');
      expect(preferences.lateArrivalPrinterId, 'p-onthaal');
    });

    testWidgets(
        'a re-addressed printer is rebound on the next document update, with '
        'the desk still selected', (WidgetTester tester) async {
      // The reason the choice is stored as an id: DHCP moved the box, an
      // administrator corrected the address in Instellingen, and no desk had to
      // be touched.
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final _RecordingTransport tickets = _RecordingTransport();
      final LiveSettings live = twoPrinters();

      await tester.pumpWidget(_wrap(
        desk: desk,
        preferences: await _prefsWithPrinter('p-toren'),
        child: LateArrivalsScreen(
          bootstrap: _harness(live: live).bootstrap,
          ticketTransport: tickets,
        ),
      ));
      await tester.pumpAndSettle();
      expect(_selectedPrinter(tester), 'Toren');

      live.publish(const AppSettings(ticketPrinters: <TicketPrinter>[
        TicketPrinter(
          id: 'p-onthaal',
          label: 'Onthaal',
          host: 'bon-onthaal.invalid',
          header: 'SMA',
        ),
        // Same entry, same id — new address, and a corrected label besides.
        TicketPrinter(
          id: 'p-toren',
          label: 'Toren (gang)',
          host: '10.1.2.9',
          header: 'SMT',
        ),
      ]));
      await tester.pumpAndSettle();

      expect(_selectedPrinter(tester), 'Toren (gang)');
      await _scan(tester, '123456');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      expect(tickets.hosts, <String>['10.1.2.9']);
    });

    testWidgets(
        'a stored printer that was removed falls back to Geen printer, says '
        'so, and the stale id is gone once the operator picks again',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final _RecordingTransport tickets = _RecordingTransport();
      final LocalPreferences preferences = await _prefsWithPrinter('p-weg');

      await tester.pumpWidget(_wrap(
        desk: desk,
        preferences: preferences,
        child: LateArrivalsScreen(
          bootstrap: _harness(live: twoPrinters()).bootstrap,
          ticketTransport: tickets,
        ),
      ));
      await tester.pumpAndSettle();

      // The operator finds out now, not when the first ticket fails to come
      // out.
      expect(_selectedPrinter(tester), 'Geen printer');
      expect(
        _textOf(
          tester,
          find.byKey(const ValueKey<String>('late-printer-note')),
        ),
        contains('De gekozen printer bestaat niet meer'),
      );

      // Registrations are untouched by it — nothing printed, nothing lost.
      await _scan(tester, '123456');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      expect(desk.journal!.records, hasLength(1));
      expect(tickets.sent, isEmpty);

      await _pickPrinter(tester, 'p-onthaal');
      expect(preferences.lateArrivalPrinterId, 'p-onthaal');
      expect(
        find.byKey(const ValueKey<String>('late-printer-note')),
        findsNothing,
        reason: 'the complaint goes away with the thing it complained about',
      );
    });

    testWidgets(
        'switching printers seconds after a confirmation does not take that '
        "student's ticket with it", (WidgetTester tester) async {
      // The desk-side half of the same rule the printer proves on its own: the
      // selector replaces the bound `LateArrivalPrinter`, and a ticket already
      // accepted belongs to a student who was told it was coming. Losing it
      // would be silent — the registration is on disk saying it printed.
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final Completer<void> gate = Completer<void>();
      final _RecordingTransport tickets = _RecordingTransport(gate: gate);

      await tester.pumpWidget(_wrap(
        desk: desk,
        preferences: await _prefsWithPrinter('p-onthaal'),
        child: LateArrivalsScreen(
          bootstrap: _harness(live: twoPrinters()).bootstrap,
          ticketTransport: tickets,
        ),
      ));
      await tester.pumpAndSettle();

      await _scan(tester, '123456');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      expect(desk.journal!.records, hasLength(1));
      // Queued, and stuck behind the gate — the state an operator who switches
      // desks in the same breath would catch it in.
      expect(tickets.sent, isEmpty);

      await _pickPrinter(tester, 'p-toren');
      expect(_selectedPrinter(tester), 'Toren');

      gate.complete();
      await tester.pumpAndSettle();

      expect(tickets.hosts, <String>['bon-onthaal.invalid'],
          reason: "the ticket goes to the printer it was addressed to");
      expect(
        String.fromCharCodes(tickets.sent.single),
        contains('Jonas Peeters'),
      );
    });

    testWidgets(
        'an empty shared list leaves the selector disabled and points at '
        'Instellingen', (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);

      await tester.pumpWidget(_wrap(
        desk: desk,
        child: LateArrivalsScreen(bootstrap: _harness().bootstrap),
      ));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey<String>('late-printer-select')),
            )
            .enabled,
        isFalse,
      );
      expect(
        _textOf(
          tester,
          find.byKey(const ValueKey<String>('late-printer-note')),
        ),
        allOf(
          contains('nog geen ticketprinters ingesteld'),
          contains('Instellingen → Te laat'),
        ),
      );
    });

    testWidgets(
        'Geen printer registers without printing, and the keyboard comes '
        'straight back to the scanner', (WidgetTester tester) async {
      // The focus is the whole reason this control is a menu and not a
      // dropdown: a scan tab that stopped reclaiming swallows the next badge
      // with no error, no ticket and no record.
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);
      final _RecordingTransport tickets = _RecordingTransport();

      await tester.pumpWidget(_wrap(
        desk: desk,
        preferences: await _prefsWithPrinter('p-toren'),
        child: LateArrivalsScreen(
          bootstrap: _harness(live: twoPrinters()).bootstrap,
          ticketTransport: tickets,
        ),
      ));
      await tester.pumpAndSettle();

      await _pickPrinter(tester, 'none');
      expect(_selectedPrinter(tester), 'Geen printer');
      expect(
        tester
                .widget<Text>(find.descendant(
                  of: _indicator,
                  matching: find.byType(Text),
                ))
                .data ??
            '',
        'KLAAR OM TE SCANNEN',
      );

      // And it is really back: the next burst lands without a click.
      await _scan(tester, '123456');
      expect(_textOf(tester, _name), 'Jonas Peeters');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      expect(desk.journal!.records, hasLength(1));
      expect(tickets.sent, isEmpty);
    });

    testWidgets(
        'dismissing the menu without choosing hands the keyboard back too',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final LateArrivalDesk desk = await _openDesk(tester);

      await tester.pumpWidget(_wrap(
        desk: desk,
        preferences: await _prefsWithPrinter('p-toren'),
        child: LateArrivalsScreen(
          bootstrap: _harness(live: twoPrinters()).bootstrap,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('late-printer-select')),
      );
      await tester.pumpAndSettle();
      // Escape, the way an operator who opened it by accident gets out.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_selectedPrinter(tester), 'Toren');
      await _scan(tester, '123456');
      expect(_textOf(tester, _name), 'Jonas Peeters');
    });
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

/// An [InMemoryJournalStore] whose [append] can be held open or made to fail,
/// so a test can look at the screen *while* a registration is being written
/// (#457) — or after it could not be.
class _GatedJournalStore implements JournalStore {
  final InMemoryJournalStore _inner = InMemoryJournalStore();

  /// When set, [append] waits on it before doing anything.
  Completer<void>? gate;

  /// When set, [append] throws it instead of writing.
  Object? failure;

  @override
  Future<void> append(SchoolDay day, String line) async {
    final Completer<void>? held = gate;
    if (held != null) await held.future;
    final Object? fail = failure;
    if (fail != null) throw fail;
    await _inner.append(day, line);
  }

  @override
  Future<List<SchoolDay>> days() => _inner.days();

  @override
  Future<void> delete(SchoolDay day) => _inner.delete(day);

  @override
  Future<String> read(SchoolDay day) => _inner.read(day);

  @override
  String locationOf(SchoolDay day) => _inner.locationOf(day);
}

/// Stands in for Smartschool's Presence module: records each accepted write,
/// and throws [failures] first, one per call (#460). Never a live call — a
/// presence write is a write against the school's tenant.
class _ScriptedWriter implements LatePresenceWriter {
  final List<Object> failures = <Object>[];
  final List<int> written = <int>[];

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required HalfDay part,
    required bool withoutValidReason,
    required String motivation,
    bool keepRecordedAbsence = false,
  }) async {
    if (failures.isNotEmpty) throw failures.removeAt(0);
    written.add(userId);
  }

  @override
  Future<void> reauthenticate() async {}
}

/// What a journal write that could not land throws.
class _DiskFull implements Exception {
  const _DiskFull();

  @override
  String toString() => 'schijf vol';
}
