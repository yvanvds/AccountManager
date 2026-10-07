// BuildContext lookups after `pumpAndSettle` are safe in tests: the tree is
// still mounted and the tester drives the frames synchronously.
// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Directory, File, FileSystemException, HandshakeException, Platform;

import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/late_arrivals/file_journal_store.dart';
import 'package:account_manager/src/late_arrivals/late_arrival_desk.dart';
import 'package:account_manager/src/late_arrivals/late_arrival_printer.dart'
    show TicketTransport;
import 'package:account_manager/src/late_arrivals/operator_credentials.dart';
import 'package:account_manager/src/late_arrivals/refusal_beep.dart'
    show RefusalBeep;
import 'package:account_manager/src/late_arrivals/smartschool_presence_writer.dart'
    show SmartschoolPresenceSession, SmartschoolPresenceWriter;
import 'package:account_manager/src/reconcile/log_buffer.dart'
    show LogBuffer, LogEntry;
import 'package:account_manager/src/settings/connection_config.dart';
import 'package:account_manager/src/settings/local_preferences.dart';
import 'package:account_manager/src/settings/settings_bootstrap.dart'
    show SettingsServices;
import 'package:account_state/account_state.dart'
    show
        AppSettings,
        CosmosContainerNotProvisioned,
        InMemorySecretProvider,
        InMemorySettingsStore,
        LiveSettings;
import 'package:late_arrivals/late_arrivals.dart'
    show
        HalfDay,
        InMemoryJournalStore,
        LateArrivalJournal,
        LateArrivalReason,
        LateArrivalRecord,
        LateArrivalStatus,
        LatePresenceWriter,
        PresenceRejected,
        RetryBackoff,
        ScanRegisterable,
        ScannedStudent,
        TicketPrinter,
        composeMotivation,
        defaultLateArrivalReasons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/reconcile/reconcile_fakes.dart';
import 'support/e2e_support.dart';

/// End-to-end runs of the *real* app for **Te laat** — late-arrival
/// registration at the reception desk.
///
/// Split out of `app_launch_test.dart` in #421: this is the one feature area
/// with fakes of its own (the DPAPI credential store, the ticket printer
/// transport, the scanner keystrokes and the Presence writer), used by nothing
/// else, so it costs one extra app launch and buys a fake boundary that cannot
/// be disturbed from the other suites. Helpers it shares with the other
/// end-to-end files live in `support/e2e_support.dart`; the ones below are
/// used only here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Opens Settings' **Te laat** tab, which since #411 is where the reason list,
  /// the ticket printer and the operator's Smartschool login live (they used to
  /// sit at the bottom of Algemeen, the tab the screen opens on).
  Future<void> openLateArrivalSettingsTab(WidgetTester tester) =>
      openSettingsTab(tester, 'settings-tab-telaat');

  /// Pumps real frames until [ready] holds, and fails after [timeout] rather
  /// than hanging.
  ///
  /// `pumpAndSettle` is *not* a substitute (#425). The integration binding runs
  /// on the real clock, so it returns as soon as no frame is scheduled — it
  /// never awaits the `async` work a button press kicked off. Where that work
  /// ends in a disk write that changes nothing in the tree, there is no frame to
  /// settle on at all, and a test that reads the file straight after the pump is
  /// racing the write on whatever timing the machine happens to give it. Wait on
  /// a signal that the write actually landed instead — never on a frame count,
  /// and never on a fixed delay.
  Future<void> pumpUntil(
    WidgetTester tester,
    String what,
    bool Function() ready, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (!ready()) {
      if (!DateTime.now().isBefore(deadline)) {
        fail('timed out after $timeout waiting for $what');
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  /// Deletes the temp directory [dir], retrying while Windows still holds a
  /// handle into it.
  ///
  /// Windows refuses to delete a directory while any handle into it is open,
  /// and the app under test is only torn down *after* a test's own tear-downs
  /// run — so the journal write of the last registration can still be
  /// settling, and in a test that failed mid-write it is still open for
  /// certain (#453). A few short retries cover that gap. A temp directory left
  /// behind is never worth failing a run over, and a second error in the
  /// teardown would only bury the first.
  Future<void> deleteTempDir(Directory dir) async {
    for (var i = 0; i < 20 && dir.existsSync(); i++) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  group('Te laat', () {
    testWidgets(
        'the late-arrival settings have a tab of their own, between Azure and '
        'Verbinding, and Algemeen is back to app-wide options (#411)',
        (WidgetTester tester) async {
      // A placement claim is only true in the laid-out app: which tabs the real
      // scrolling TabBar renders and in what left-to-right order, what the real
      // Algemeen ListView still contains, and whether the three sections really
      // are one page apart rather than one scroll apart. A widget test renders the
      // sections; it cannot say where in the app an operator finds them.
      useTallWindow(tester);

      final InMemorySettingsStore shared = InMemorySettingsStore();
      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: () async => SettingsServices(
          store: shared,
          secrets: InMemorySecretProvider(const {}),
        ),
        connection: ConnectionServices(store: InMemoryConnectionStore()),
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();

      // The tab the screen opens on is app-wide options again: the school prefix
      // is there, and none of the three desk sections is.
      expect(
          find.byKey(const ValueKey('settings-school-prefix')), findsOneWidget);
      expect(find.text('Te laat — redenen'), findsNothing);
      expect(find.text('Te laat — ticketprinters'), findsNothing);
      expect(find.text('Te laat — Smartschool-aanmelding'), findsNothing);

      // Where it sits in the real, laid-out tab strip: after the three connectors,
      // before the one tab that does not need the settings document (#370).
      double tabX(String key) =>
          tester.getTopLeft(find.byKey(ValueKey(key))).dx;
      expect(tabX('settings-tab-azure'), lessThan(tabX('settings-tab-telaat')));
      expect(tabX('settings-tab-telaat'),
          lessThan(tabX('settings-tab-verbinding')));

      // Opening it puts all three there, in the order a desk is set up in:
      // the shared buttons, the shared printers (#435), this person's login.
      await openLateArrivalSettingsTab(tester);
      double sectionY(String title) => tester.getTopLeft(find.text(title)).dy;
      expect(sectionY('Te laat — redenen'),
          lessThan(sectionY('Te laat — ticketprinters')));
      expect(sectionY('Te laat — ticketprinters'),
          lessThan(sectionY('Te laat — Smartschool-aanmelding')));
      // …and the app-wide options are not dragged along with them.
      expect(
          find.byKey(const ValueKey('settings-school-prefix')), findsNothing);

      // Verbinding is still reachable behind it — the tab that has to work when
      // nothing else does did not get pushed off the end.
      await openSettingsTab(tester, 'settings-tab-verbinding');
      expect(
        find.byKey(const ValueKey('settings-connection-cosmos-endpoint')),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Instellingen maintains the shared late-arrival reason list, and the '
        'edit reaches the other desk and a running session without a restart '
        '(#405)', (WidgetTester tester) async {
      // Every acceptance criterion of #405 in one real run, and each half needs
      // this level. The editor is a section inside the real scrolling Te laat
      // tab (#411), in the real Plink faces, with a real dialog pushed onto the
      // real navigator — a widget test renders the section, not the page it has to
      // share a column and a scroll context with. And "shared, not per-machine"
      // is a claim about a *second* app instance reading the same document, which
      // only a full launch can make.
      useTallWindow(tester);

      // One shared settings document — Cosmos in production — with the two desks
      // bootstrapping their own sessions over it. `live` is what an already-open
      // scan tab (#407) reads its buttons from, so publishing into it is what
      // "takes effect without a restart" means.
      final InMemorySettingsStore shared = InMemorySettingsStore();
      final InMemorySecretProvider vault = InMemorySecretProvider(const {});
      final LiveSettings live = LiveSettings();
      final List<List<String>> published = <List<String>>[];
      final StreamSubscription<AppSettings> watching = live.changes.listen(
        (AppSettings s) => published.add(<String>[
          for (final LateArrivalReason r in s.lateArrivalReasons) r.label,
        ]),
      );
      addTearDown(watching.cancel);

      Future<void> openDesk({LiveSettings? holder}) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(AccountManagerApp(
          session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
          graph: graph,
          settingsBootstrap: () async => SettingsServices(
            store: shared,
            secrets: vault,
            liveSettings: holder,
          ),
          connection: ConnectionServices(store: InMemoryConnectionStore()),
        ));
        await tester.pumpAndSettle();
        await tester.tap(railTab('Instellingen'));
        await tester.pumpAndSettle();
        await openLateArrivalSettingsTab(tester);
      }

      /// The reason labels the editor lists, top to bottom — the order the desk's
      /// button row will render them in (#407).
      List<String> listedReasons() {
        final List<String> out = <String>[];
        for (var i = 0;; i++) {
          final Finder row = find.byKey(ValueKey('settings-reason-$i'));
          if (row.evaluate().isEmpty) return out;
          out.add(tester.widget<Text>(row).data!);
        }
      }

      Future<void> scrollToReasons() async {
        await tester
            .ensureVisible(find.byKey(const ValueKey('settings-reasons-note')));
        await tester.pumpAndSettle();
      }

      // --- Desk one, on an install nobody has configured. ----------------------
      await openDesk(holder: live);
      // The desk's configuration has a tab of its own now (#411), and `openDesk`
      // went to it: the section is there, and not on the Algemeen tab the screen
      // opens on.
      expect(find.text('Te laat — redenen'), findsOneWidget);
      await scrollToReasons();

      // The shipped list is already there, so the desk works before anybody
      // configures anything.
      expect(
        listedReasons(),
        defaultLateArrivalReasons
            .map((LateArrivalReason r) => r.label)
            .toList(),
      );
      // The "zonder geldige reden" entries are marked in place — visually
      // distinguishable, but in the same single list, which is the shape the
      // desk's flat button row has to have.
      expect(find.text('ZONDER GELDIGE REDEN'), findsNWidgets(2));

      // --- Add one that does not count as a valid reason. ----------------------
      final Finder add = find.byKey(const ValueKey('settings-reason-add'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('settings-reason-label')),
        'Te lang gepraat',
      );
      await tester.pump();
      // One switch on the reason itself — never a second click at the desk.
      await tester.tap(find.byKey(const ValueKey('settings-reason-valid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-reason-confirm')));
      await tester.pumpAndSettle();

      await scrollToReasons();
      expect(listedReasons().last, 'Te lang gepraat');
      expect(find.text('ZONDER GELDIGE REDEN'), findsNWidgets(3));

      // --- Reorder: put the reason this school hears most at the front. --------
      // "Verkeer" is second in the shipped list; one press up makes it first.
      await tester.tap(find.byKey(const ValueKey('settings-reason-1-up')));
      await tester.pumpAndSettle();
      await scrollToReasons();
      expect(listedReasons().first, 'Verkeer');

      // --- Remove one the school does not use. ---------------------------------
      final int doctor = listedReasons().indexOf('Doktersbezoek');
      await tester.tap(find.byKey(ValueKey('settings-reason-$doctor-remove')));
      await tester.pumpAndSettle();
      await scrollToReasons();
      expect(listedReasons(), isNot(contains('Doktersbezoek')));

      final List<String> intended = listedReasons();
      await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      // It landed in the shared document, in the operator's order.
      final AppSettings saved = await shared.load();
      expect(
        <String>[
          for (final LateArrivalReason r in saved.lateArrivalReasons) r.label,
        ],
        intended,
      );
      // …carrying the flag with the reason, which is what #404's presence write
      // reads and what the fixed motivation format quotes (#402).
      final LateArrivalReason added = saved.lateArrivalReasons
          .firstWhere((LateArrivalReason r) => r.label == 'Te lang gepraat');
      expect(added.isValid, isFalse);
      expect(added.withoutValidReason, isTrue);
      expect(
        composeMotivation(DateTime(2026, 9, 7, 8, 14), added.label),
        '08:14 – Te lang gepraat',
      );

      // No restart: the save was published into the holder a running scan tab
      // reads its buttons from, so an open tab picks the edit up live.
      expect(published, isNotEmpty);
      expect(published.last, intended);
      expect(
        <String>[
          for (final LateArrivalReason r in live.current.lateArrivalReasons)
            r.label,
        ],
        intended,
      );

      // --- Desk two: a different machine, the same list. -----------------------
      // The whole reason this lives in shared state. If each desk kept its own,
      // Smartschool would end up holding "bus", "de bus" and "vertraging bus" as
      // three different reasons and the data would be worthless afterwards.
      await openDesk();
      await scrollToReasons();
      expect(listedReasons(), intended);
      expect(find.text('Doktersbezoek'), findsNothing);

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Instellingen collects the operator\'s own Smartschool login, encrypts it '
        'on this machine with DPAPI, and the desk drains a recovered journal with '
        'nobody wiring it (#409)', (WidgetTester tester) async {
      // Everything #409 claims, in one real run, and each half needs this level.
      //
      // "The password is encrypted at rest with the same cipher the token cache
      // uses" is a claim about **real DPAPI** — `crypt32.dll` over `dart:ffi`,
      // which exists only on Windows and therefore only in this suite. A unit test
      // can prove the store honours whatever cipher it is handed; only this run
      // proves the cipher the app actually ships works, and that the plaintext
      // never reaches the file.
      //
      // "A recovered journal resumes draining at start" is a claim about
      // `main()`-shaped wiring across an app *restart*: a real journal file on a
      // real filesystem, written by one widget tree and picked up by the next, and
      // the drain attaching itself only once the shared settings document has been
      // loaded. There is no widget to pump for that.
      //
      // Nothing here touches Smartschool. The presence writer is a fake, and so is
      // the sign-in probe: writing a presence and signing in are live interactions
      // with the school's tenant, and the repo's live-testing policy keeps both out
      // of CI entirely.
      useTallWindow(tester);

      final Directory dir = Directory.systemTemp.createTempSync('am-ss-login-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File credentialFileFor(String desk) => File(
            '${dir.path}${Platform.pathSeparator}$desk-'
            '$smartschoolOperatorCredentialFileName',
          );
      Directory journalDirFor(String desk) =>
          Directory('${dir.path}${Platform.pathSeparator}$desk-journaal');

      // The real cipher the app ships — the same pair `main()` hands the store.
      OperatorCredentialStore credentialsFor(String desk) =>
          EncryptedFileCredentialStore(
            credentialFileFor(desk),
            encrypt: Dpapi.protect,
            decrypt: Dpapi.unprotect,
          );

      // One shared settings document naming the school's Smartschool site, the way
      // every desk really reads it — and the reason the drain cannot attach until
      // the document has been loaded.
      const AppSettings base = AppSettings();
      final InMemorySettingsStore shared = InMemorySettingsStore(
        base.copyWith(
          smartschool:
              base.smartschool.copyWith(uri: 'https://arcadia.smartschool.be'),
        ),
      );
      final InMemorySecretProvider vault = InMemorySecretProvider(const {});
      final LiveSettings live = LiveSettings();

      final _RecordingPresenceWriter written = _RecordingPresenceWriter();
      LateArrivalDesk? current;

      /// Launches (or relaunches) one desk over its own credential file and its
      /// own journal directory — which is what both a restart and a second
      /// machine look like from here.
      Future<LateArrivalDesk> openDesk(String desk) async {
        final LateArrivalDesk built = LateArrivalDesk(
          journalStore: FileJournalStore(journalDirFor(desk)),
          credentials: credentialsFor(desk),
          deskId: desk,
          settings: live,
          writerFor: (_, __) => written,
          signInProbe: (SmartschoolOperatorLogin login, String host) async {
            if (login.password != 'zeergeheim') {
              throw StateError('Foutieve gebruikersnaam of wachtwoord.');
            }
          },
        );
        // Unmount the previous tree before letting go of its desk, so the scope
        // is not listening to a disposed notifier.
        await tester.pumpWidget(const SizedBox.shrink());
        current?.dispose();
        current = built;
        await tester.pumpWidget(AccountManagerApp(
          session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
          graph: graph,
          settingsBootstrap: () async => SettingsServices(
            store: shared,
            secrets: vault,
            liveSettings: live,
          ),
          connection: ConnectionServices(store: InMemoryConnectionStore()),
          desk: built,
        ));
        await tester.pumpAndSettle();
        await tester.tap(railTab('Instellingen'));
        await tester.pumpAndSettle();
        await openLateArrivalSettingsTab(tester);
        return built;
      }

      Future<void> scrollToLogin() async {
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-smartschool-operator-note')),
        );
        await tester.pumpAndSettle();
      }

      Future<void> type(String key, String value) async {
        final Finder field = find.byKey(ValueKey(key));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        // The tap is not decoration: pressing **Opslaan** takes focus off the
        // field, and `enterText` alone would then go to a dead text connection.
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.enterText(field, value);
        await tester.pumpAndSettle();
      }

      /// Presses **Opslaan** and waits for the credential to be on disk.
      ///
      /// `_SettingsScreenState._save` is `async` and awaits two disk writes
      /// before the DPAPI file exists, so pumping alone leaves the read below
      /// racing the write — which is exactly how this test lost on a cold
      /// filesystem (#425). The desk's own `draining` flag is the settled signal
      /// to wait on: `saveLogin` flips it only *after* `credentials.write` has
      /// completed, so once it is true the ciphertext is whole on disk, the
      /// store can hand it back, and the drain is attached.
      Future<void> save() async {
        await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
        await tester.tap(find.byKey(const ValueKey('settings-save')));
        await tester.pumpAndSettle();
        await pumpUntil(
          tester,
          "the operator login to be written to this machine's disk",
          () => current!.draining,
        );
      }

      String stateLine() => tester
          .widget<Text>(
              find.byKey(const ValueKey('settings-smartschool-operator-state')))
          .data!;

      // --- Desk one, on an install nobody has configured. ----------------------
      await openDesk('balie-1');
      expect(find.text('Te laat — Smartschool-aanmelding'), findsOneWidget);
      await scrollToLogin();
      expect(stateLine(), contains('nog geen aanmelding'));
      // A desk that cannot drain must still register — and it has to say so,
      // because the operator has a student standing in front of them.
      expect(stateLine(), contains('bewaard en afgedrukt'));
      expect(current!.draining, isFalse);
      expect(
        current!.warnings.join(' '),
        contains('geen Smartschool-aanmelding'),
      );

      // --- A typo is caught before a student is late. --------------------------
      await type('settings-smartschool-operator-username', 'ann.peeters');
      await type('settings-smartschool-operator-password', 'fout');
      final Finder testButton =
          find.byKey(const ValueKey('settings-smartschool-operator-test'));
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      final Finder statusLine =
          find.byKey(const ValueKey('settings-smartschool-operator-status'));
      final Text refused = tester.widget<Text>(statusLine);
      expect(refused.data, contains('Foutieve gebruikersnaam of wachtwoord.'));
      expect(
        refused.style?.color,
        Theme.of(tester.element(statusLine)).colorScheme.error,
      );
      // A test is not a save: a wrong password must not have been written.
      expect(credentialFileFor('balie-1').existsSync(), isFalse);

      // --- The right one, tested and then saved. -------------------------------
      await type('settings-smartschool-operator-password', 'zeergeheim');
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(statusLine).data, contains('is gelukt'));

      await save();

      // The bytes on disk are real DPAPI ciphertext: nothing readable in them.
      final String onDisk = credentialFileFor('balie-1').readAsStringSync();
      expect(onDisk, isNotEmpty);
      expect(onDisk, isNot(contains('zeergeheim')));
      expect(onDisk, isNot(contains('ann.peeters')));
      // …and Windows hands it back to this same user, on this same machine.
      final SmartschoolOperatorLogin? readBack =
          await credentialsFor('balie-1').read();
      expect(readBack?.username, 'ann.peeters');
      expect(readBack?.password, 'zeergeheim');

      // Nowhere near the document every operator in the group reads.
      expect(
        jsonEncode((await shared.load()).toJson()),
        allOf(isNot(contains('zeergeheim')), isNot(contains('ann.peeters'))),
      );

      // The desk started draining without a relaunch, and stopped complaining.
      expect(current!.draining, isTrue);
      expect(current!.warnings.join(' '), isNot(contains('aanmelding')));

      // --- A registration this desk journals reaches Smartschool. --------------
      await current!.journal!.register(
        scan: const ScanRegisterable(_lateStudent),
        scannedAt: DateTime(2026, 9, 7, 8, 42),
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );
      await current!.drain!.settle();
      expect(written.userIds, <int>[4242]);

      // --- The desk dies with a registration still in the queue. ---------------
      // Appended straight to this desk's journal *file* by a bare journal, with
      // no sink and no worker behind it: a line that is durably on disk and that
      // nothing has ever tried to send. That is precisely the state a killed
      // process leaves behind, and the only state from which "draining resumes
      // after a restart" means anything.
      final LateArrivalJournal crashed = await LateArrivalJournal.open(
          FileJournalStore(journalDirFor('balie-1')));
      final record = await crashed.register(
        scan: const ScanRegisterable(_lateStudent),
        scannedAt: DateTime(2026, 9, 7, 9, 15),
        reasonLabel: 'Verslapen',
        reasonIsValid: false,
      );
      expect(record.status, LateArrivalStatus.pending);

      // --- Restart. ------------------------------------------------------------
      written.userIds.clear();
      await openDesk('balie-1');
      await scrollToLogin();
      // The login came back out of the ciphertext, without the operator retyping.
      expect(stateLine(), contains('ann.peeters'));
      expect(
        tester
            .widget<TextField>(find.byKey(
                const ValueKey('settings-smartschool-operator-password')))
            .controller!
            .text,
        '',
        reason: 'write-only: the stored password is never echoed back',
      );

      // And the queue the dead run left behind went out by itself.
      expect(current!.recovery!.pendingCount, 1);
      await current!.drain!.settle();
      expect(written.userIds, <int>[4242]);
      expect(
        current!.journal!.byId(record.id)!.status,
        LateArrivalStatus.confirmed,
      );

      // --- Desk two: another machine, the same shared document. ----------------
      // A personal credential must not travel the way the shared reason list
      // deliberately does.
      await openDesk('balie-2');
      await scrollToLogin();
      expect(stateLine(), contains('nog geen aanmelding'));
      expect(find.text('ann.peeters'), findsNothing);
      expect(current!.draining, isFalse);
      // Desk one's file is untouched by desk two opening.
      expect(credentialFileFor('balie-1').readAsStringSync(), onDisk);

      // --- Wissen puts a desk back to unconfigured. ----------------------------
      await openDesk('balie-1');
      await scrollToLogin();
      final Finder clear =
          find.byKey(const ValueKey('settings-smartschool-operator-clear'));
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      // Wissen deletes the file from an `async` handler too, so the same rule
      // applies as for the save above (#425): wait for the desk to stop
      // draining, which happens only once `credentials.clear()` has returned.
      await pumpUntil(
        tester,
        'the stored login to be wiped from this machine',
        () => !current!.draining,
      );

      expect(credentialFileFor('balie-1').existsSync(), isFalse);
      expect(stateLine(), contains('nog geen aanmelding'));
      expect(current!.draining, isFalse);

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a settings document holding only the school\'s subdomain still signs in '
        '— the host is completed before Smartschool ever sees it (#412)',
        (WidgetTester tester) async {
      // The Smartschool tab asks for the school's *short name*, because that is
      // what the SOAP connector wants — so `sanctamaria-aarschot` is what the
      // shared document really holds. The reception desk read that same field for
      // the Presence login, and **Aanmelding testen** died with
      // `Failed host lookup: 'sanctamaria-aarschot'`, taking every drained
      // presence with it.
      //
      // This needs the whole app: the value travels from the Smartschool tab's
      // saved document, through the desk, into both the sign-in the operator
      // presses on the Te laat tab *and* the writer the drain builds for itself.
      // A unit test on the completion cannot show that the two places that sign in
      // are the two places that got it.
      //
      // The probe and the presence writer are fakes, permanently: a real
      // Smartschool sign-in is a live interaction with the school's tenant and the
      // repo's live-testing policy keeps those out of CI entirely. The probe here
      // fails the way the real one did, on a host that cannot resolve.
      useTallWindow(tester);

      final List<String> probedHosts = <String>[];
      final List<String> writerHosts = <String>[];
      final _RecordingPresenceWriter written = _RecordingPresenceWriter();

      const AppSettings base = AppSettings();
      final InMemorySettingsStore shared = InMemorySettingsStore(
        base.copyWith(
          smartschool: base.smartschool.copyWith(uri: 'sanctamaria-aarschot'),
        ),
      );
      final LiveSettings live = LiveSettings();

      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: InMemoryJournalStore(),
        credentials: InMemoryOperatorCredentialStore(
          const SmartschoolOperatorLogin(
            username: 'ann.peeters',
            password: 'zeergeheim',
          ),
        ),
        deskId: 'balie-412',
        settings: live,
        writerFor: (_, String host) {
          writerHosts.add(host);
          return written;
        },
        signInProbe: (SmartschoolOperatorLogin login, String host) async {
          probedHosts.add(host);
          if (!host.endsWith('.smartschool.be')) {
            throw StateError("Failed host lookup: '$host'");
          }
        },
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: () async => SettingsServices(
          store: shared,
          secrets: InMemorySecretProvider(const {}),
          liveSettings: live,
        ),
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await openLateArrivalSettingsTab(tester);

      // The drain attached itself once the document arrived — against the host,
      // not against the short name it is stored as.
      expect(desk.draining, isTrue);
      expect(desk.smartschoolHost, 'sanctamaria-aarschot.smartschool.be');
      expect(writerHosts, <String>['sanctamaria-aarschot.smartschool.be']);

      // And the button the operator presses before the first student is late.
      final Finder testButton =
          find.byKey(const ValueKey('settings-smartschool-operator-test'));
      await tester.ensureVisible(testButton);
      await tester.pumpAndSettle();
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      expect(probedHosts, <String>['sanctamaria-aarschot.smartschool.be']);
      expect(
        tester
            .widget<Text>(find
                .byKey(const ValueKey('settings-smartschool-operator-status')))
            .data,
        contains('is gelukt'),
      );

      // A registration made on this desk goes out over that same completed host.
      await desk.journal!.register(
        scan: const ScanRegisterable(_lateStudent),
        scannedAt: DateTime(2026, 9, 7, 8, 42),
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );
      await desk.drain!.settle();
      expect(written.userIds, <int>[4242]);

      // Unmount before letting go of the desk, so the scope is not listening to a
      // disposed notifier.
      await tester.pumpWidget(const SizedBox.shrink());
      desk.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Aanmelding testen tells a Smartschool it could not reach apart from a '
        'login it refused: the operator reads which to fix, in Dutch, and the '
        'library\'s own words stay on the line below (#455)',
        (WidgetTester tester) async {
      // The secretariat PC of #454: the TLS handshake with Smartschool failed
      // (`CERTIFICATE_VERIFY_FAILED`), and the status line under **Aanmelding
      // testen** showed the raw `toString()` of an *authentication* error,
      // BoringSSL source path included. The technician went looking at the MFA
      // secret and the password, neither of which had left the machine.
      //
      // The status line is what the person at the desk reads, so this is proven
      // where they read it: the real settings screen inside the real shell,
      // through the real desk. The probe is a fake, permanently — a Smartschool
      // sign-in is a live interaction with the school's tenant, and the repo's
      // live-testing policy keeps those out of CI entirely. It fails the way
      // the library has failed since dartschool#21: a `SmartschoolConnectionError`
      // whose cause is the handshake, deliberately not an authentication error.
      useTallWindow(tester);

      const String handshake =
          'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: '
          'unable to get local issuer certificate(handshake.cc:393))';
      final List<String> probedHosts = <String>[];

      const AppSettings base = AppSettings();
      final InMemorySettingsStore shared = InMemorySettingsStore(
        base.copyWith(
          smartschool: base.smartschool.copyWith(uri: 'arcadia'),
        ),
      );
      final LiveSettings live = LiveSettings();

      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: InMemoryJournalStore(),
        credentials: InMemoryOperatorCredentialStore(
          const SmartschoolOperatorLogin(
            username: 'ann.peeters',
            password: 'zeergeheim',
          ),
        ),
        deskId: 'balie-455',
        settings: live,
        writerFor: (_, __) => _RecordingPresenceWriter(),
        signInProbe: (SmartschoolOperatorLogin login, String host) async {
          probedHosts.add(host);
          throw ss.SmartschoolConnectionError(
            'Unable to reach Smartschool at $host: the connection failed '
            '(HandshakeException: $handshake)',
            cause: const HandshakeException(handshake),
          );
        },
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: () async => SettingsServices(
          store: shared,
          secrets: InMemorySecretProvider(const {}),
          liveSettings: live,
        ),
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await openLateArrivalSettingsTab(tester);

      final Finder testButton =
          find.byKey(const ValueKey('settings-smartschool-operator-test'));
      await tester.ensureVisible(testButton);
      await tester.pumpAndSettle();
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      expect(probedHosts, <String>['arcadia.smartschool.be']);
      final Finder status =
          find.byKey(const ValueKey('settings-smartschool-operator-status'));
      final Text line = tester.widget<Text>(status);
      final List<String> lines = line.data!.split('\n');
      // The operator's line: the host, that nothing was sent, what to look at
      // — and not one byte of BoringSSL.
      expect(
        lines.first,
        allOf(
          contains('arcadia.smartschool.be'),
          contains('niet vertrouwd'),
          contains('gebruikersnaam, wachtwoord en MFA zijn niet verstuurd'),
          contains('firewall, proxy of antivirus'),
          isNot(contains('handshake.cc')),
          isNot(contains('SmartschoolConnectionError')),
          isNot(contains('authentic')),
        ),
      );
      // The library's own sentence, for whoever is asked to fix it, below.
      expect(
        lines.skip(1).join('\n'),
        allOf(
          contains('SmartschoolConnectionError'),
          contains('CERTIFICATE_VERIFY_FAILED'),
        ),
      );
      // Reported as the failure it is, in the error colour.
      expect(
        line.style?.color,
        Theme.of(tester.element(status)).colorScheme.error,
      );

      // Unmount before letting go of the desk, so the scope is not listening to a
      // disposed notifier.
      await tester.pumpWidget(const SizedBox.shrink());
      desk.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Aanmelding testen names a login Smartschool refused in Dutch — the '
        'password, the second factor, the MFA key, the account verification — '
        'with no Dart type name, and the library\'s own words on the line '
        'below (#467)', (WidgetTester tester) async {
      // **Aanmelding testen** is where the operator is sent to check the login:
      // the desk's queue panel says so while the drain is stood down over a
      // refused one (#466). It used to answer a refusal with the library's
      // `toString()` — `SmartschoolInvalidCredentialsError: Login failed. …`,
      // a Dart type name and English — while the queue panel said the same
      // thing in Dutch. Now both say it in the one wording
      // (`describeRefusedSmartschoolSignIn`, #464).
      //
      // Proven where the operator reads it: the real settings screen inside the
      // real shell, through the real desk, one press of the real button per
      // refusal. The probe is a fake, permanently — a Smartschool sign-in is a
      // live interaction with the school's tenant, and the repo's live-testing
      // policy keeps those out of CI entirely. It throws the library's own
      // typed refusals, one per press, and lets the last press through.
      useTallWindow(tester);

      const List<ss.SmartschoolAuthenticationError> refusals =
          <ss.SmartschoolAuthenticationError>[
        ss.SmartschoolInvalidCredentialsError(),
        ss.SmartschoolTwoFactorRequiredError(),
        ss.SmartschoolTwoFactorRejectedError(),
        ss.SmartschoolInvalidTotpSecretError(),
        ss.SmartschoolUnsupportedTwoFactorMethodError(<String>['sms']),
        ss.SmartschoolAccountVerificationRequiredError(),
        ss.SmartschoolAccountVerificationRejectedError(),
      ];
      final List<Object?> answers = <Object?>[...refusals, null];
      final List<String> probedHosts = <String>[];

      const AppSettings base = AppSettings();
      final InMemorySettingsStore shared = InMemorySettingsStore(
        base.copyWith(
          smartschool: base.smartschool.copyWith(uri: 'arcadia'),
        ),
      );
      final LiveSettings live = LiveSettings();

      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: InMemoryJournalStore(),
        credentials: InMemoryOperatorCredentialStore(
          const SmartschoolOperatorLogin(
            username: 'ann.peeters',
            password: 'zeergeheim',
          ),
        ),
        deskId: 'balie-467',
        settings: live,
        writerFor: (_, __) => _RecordingPresenceWriter(),
        signInProbe: (SmartschoolOperatorLogin login, String host) async {
          probedHosts.add(host);
          final Object? refused = answers.removeAt(0);
          if (refused != null) throw refused;
        },
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: () async => SettingsServices(
          store: shared,
          secrets: InMemorySecretProvider(const {}),
          liveSettings: live,
        ),
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await openLateArrivalSettingsTab(tester);

      final Finder testButton =
          find.byKey(const ValueKey('settings-smartschool-operator-test'));
      final Finder status =
          find.byKey(const ValueKey('settings-smartschool-operator-status'));
      Future<Text> press() async {
        await tester.ensureVisible(testButton);
        await tester.pumpAndSettle();
        await tester.tap(testButton);
        await tester.pumpAndSettle();
        return tester.widget<Text>(status);
      }

      final List<String> operatorLines = <String>[];
      for (final ss.SmartschoolAuthenticationError refused in refusals) {
        final String type = '${refused.runtimeType}';
        final Text line = await press();
        final List<String> lines = line.data!.split('\n');
        operatorLines.add(lines.first);
        // The operator's line: the cause, in the words the queue panel uses —
        // not the type name, and none of the library's English.
        expect(lines.first, describeRefusedSmartschoolSignIn(refused),
            reason: type);
        expect(lines.first, isNot(contains(type)));
        expect(lines.first, isNot(contains(refused.message)));
        // Still not a connection failure: the #455 wording is for a
        // Smartschool that was never reached, and this one answered.
        expect(lines.first, isNot(contains('niet verstuurd')), reason: type);
        // The library's own words, for whoever is asked to fix it, below.
        expect(lines.skip(1).join('\n'), '$refused', reason: type);
        // Reported as the failure it is, in the error colour.
        expect(
          line.style?.color,
          Theme.of(tester.element(status)).colorScheme.error,
          reason: type,
        );
      }

      // The wrong password, word for word, as the operator at the desk reads
      // it — and seven causes, seven different sentences.
      expect(
        operatorLines.first,
        'Smartschool aanvaardde de gebruikersnaam of het wachtwoord niet.',
      );
      expect(operatorLines.toSet(), hasLength(refusals.length));

      // Once the login is right, the refusal is gone from the line.
      final Text fixed = await press();
      expect(fixed.data, contains('is gelukt'));
      expect(fixed.data, isNot(contains('aanvaardde')));
      expect(
        fixed.style?.color,
        isNot(Theme.of(tester.element(status)).colorScheme.error),
      );
      expect(probedHosts, hasLength(refusals.length + 1));
      expect(probedHosts.toSet(), <String>{'arcadia.smartschool.be'});

      // Unmount before letting go of the desk, so the scope is not listening to a
      // disposed notifier.
      await tester.pumpWidget(const SizedBox.shrink());
      desk.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the Te laat tab scans a card, refuses a second scan while the first '
        'student is unconfirmed, and registers on a reason button — journal on '
        'disk before ticket on paper (#407)', (WidgetTester tester) async {
      // The scan flow, end to end, in the real app: the real shell, the real
      // navigation rail, the real Plink fonts, the real focus manager, and a real
      // journal file on a real filesystem.
      //
      // Every claim on this screen needs that level. "A hidden input holds the
      // keyboard focus and reclaims it" is a statement about the *engine's* focus
      // manager inside a shell that keeps every visited destination mounted — a
      // widget test pumping this screen alone has no other tab to lose the focus
      // to, and so cannot fail the way the app can. "The registration is on disk
      // before the ticket prints" is a statement about a file. And the refusal
      // guard is the one rule that stops one student's reason being written onto
      // another student's record, which is precisely the bug an operator would
      // never see happen.
      //
      // Nothing here reaches Smartschool, a printer or a sound card: the desk has
      // no presence writer, the ticket transport is a recorder and the refusal
      // tone is a counter. The repo's live-testing policy keeps writes out of CI,
      // and a suite that buzzed the build machine would be its own kind of
      // failure.
      useTallWindow(tester);

      final Directory dir = Directory.systemTemp.createTempSync('am-te-laat-');
      addTearDown(() => deleteTempDir(dir));

      final _CountingRefusalBeep beep = _CountingRefusalBeep();
      final _RecordingTicketTransport tickets = _RecordingTicketTransport();

      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: FileJournalStore(dir),
        credentials: InMemoryOperatorCredentialStore(),
        deskId: 'onthaal-e2e',
      );
      addTearDown(desk.dispose);

      // The printer this desk prints on comes out of the *shared* settings
      // document since #435 — one list of named printers every desk reads,
      // rather than an address in each machine's `preferences.json`. What the
      // machine still keeps is *which* of them it prints on (#436), so this
      // desk is one that was pointed at the balie printer on some earlier day.
      final LocalPreferences preferences = LocalPreferences(
        InMemoryLocalPreferenceStore(
          <String, Object?>{'lateArrivalPrinterId': 'balie-printer'},
        ),
      );
      await preferences.load();

      final harness = ReconcileHarness(
        // Seeded, not pulled: the desk answers a scan out of the snapshot the
        // launch already holds, because a student is standing at the counter.
        ssInitial: lateArrivalSnap(),
        smartschool: lateArrivalSnap(),
        liveSettings: LiveSettings(const AppSettings(
          ticketPrinters: <TicketPrinter>[
            TicketPrinter(
              id: 'balie-printer',
              label: 'Balie',
              host: 'bonprinter-balie.invalid',
            ),
          ],
        )),
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
        refusalBeep: beep,
        ticketTransport: tickets,
        preferences: preferences,
      ));
      await tester.pumpAndSettle();

      /// Scans [code] the way the wedge does: the digits, then Enter.
      Future<void> scan(String code) async {
        for (final String character in code.split('')) {
          await tester.sendKeyEvent(
            _scannerKeys[character]!,
            character: character,
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }

      String textOf(String key) =>
          tester.widget<Text>(find.byKey(ValueKey<String>(key))).data ?? '';

      /// What the **klaar om te scannen** badge says — the badge carries the key,
      /// the text it renders sits inside it.
      String indicatorText() =>
          tester
              .widget<Text>(find.descendant(
                of: find
                    .byKey(const ValueKey<String>('late-scanner-indicator')),
                matching: find.byType(Text),
              ))
              .data ??
          '';

      // --- The tab exists beside the rest of the app. --------------------------
      expect(railTab('Te laat'), findsOneWidget);
      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();
      expect(
        indicatorText(),
        'KLAAR OM TE SCANNEN',
        reason: 'the hidden input takes the keyboard as soon as the tab opens',
      );
      // This machine has no barcode scanner attached, and the app could not see
      // one if it had — so the badge must not claim anything about hardware
      // (#413); it only ever reports whether the next scan would land.
      expect(
        indicatorText(),
        isNot(contains('SCANNER ')),
        reason: 'the badge may not assert a scanner it cannot detect',
      );

      // --- One scan, resolved locally. -----------------------------------------
      await scan('123456');
      expect(textOf('late-scan-name'), 'Jonas Peeters');
      expect(textOf('late-scan-class'), '3MTa');
      expect(harness.ssSyncs, 0, reason: 'no pull answers a scan');
      expect(desk.journal!.records, isEmpty, reason: 'no reason pressed yet');

      // --- The second student scans too early and is refused. ------------------
      await scan('223344');
      expect(
        textOf('late-scan-name'),
        'Jonas Peeters',
        reason: 'the refused scan must not replace the student on screen',
      );
      expect(beep.played, 1);
      expect(
          find.byKey(const ValueKey<String>('late-refusal')), findsOneWidget);
      expect(desk.journal!.records, isEmpty);

      // --- A reason registers, prints and frees the input. ---------------------
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      // **Never `pumpAndSettle` alone** (#425, #453). `_confirm` awaits the
      // journal's flushed append — real file I/O — and only then holds the
      // record in memory, prints and frees the screen. The integration
      // binding's `pumpAndSettle` gives that one 100 ms pump of wall time and
      // returns, which a slow CI disk does not always fit in. Wait on what
      // actually happened instead.
      await pumpUntil(
        tester,
        'the registration to be flushed to the journal',
        () => desk.journal!.records.isNotEmpty,
      );
      await pumpUntil(
        tester,
        'the ticket to reach its printer',
        () => tickets.sent.isNotEmpty,
      );

      expect(desk.journal!.records, hasLength(1));
      final LateArrivalRecord written = desk.journal!.records.single;
      expect(written.displayName, 'Jonas Peeters');
      expect(written.internalUserId, 12016);
      expect(written.classGroupId, 77);
      expect(written.reasonLabel, defaultLateArrivalReasons.first.label);

      // On disk, in the day file this desk owns — the whole point of the journal.
      final List<File> dayFiles =
          dir.listSync().whereType<File>().toList(growable: false);
      expect(dayFiles, hasLength(1));
      expect(dayFiles.single.readAsStringSync(), contains('Jonas Peeters'));

      // …and only then the ticket.
      expect(tickets.sent, hasLength(1));
      expect(
        String.fromCharCodes(tickets.sent.single),
        contains('Jonas Peeters'),
      );

      expect(
        find.byKey(const ValueKey<String>('late-scan-idle')),
        findsOneWidget,
        reason: 'the screen is free for the next student',
      );
      expect(find.text('1 IN WACHTRIJ'), findsOneWidget);

      // --- The second student rescans, and is taken. ---------------------------
      await scan('223344');
      expect(textOf('late-scan-name'), 'Lea Janssens');
      expect(beep.played, 1);

      // --- The keyboard survives a trip to another tab. ------------------------
      // The shell keeps this screen mounted, so a scan tab that went on grabbing
      // the focus would make Instellingen untypeable for the rest of the session
      // — and one that never took it back would silently swallow every scan after
      // the operator's first detour.
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();
      expect(indicatorText(), 'KLAAR OM TE SCANNEN');
      expect(
        textOf('late-scan-name'),
        'Lea Janssens',
        reason: 'the unconfirmed student survives a trip to another tab',
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a wrong scan is cancelled with Annuleren or Escape before a reason is '
        'picked: nothing is journalled or printed for it, and the right student '
        'scans straight after without a refusal (#457)',
        (WidgetTester tester) async {
      // The cancel, end to end, in the real app. A widget test proves the
      // button clears the student; only the real shell can prove the *focus*
      // half — that pressing a real button in the real page, inside a shell
      // that keeps every destination mounted, leaves the keyboard with the
      // hidden scanner input so the very next card lands. A cancel that took
      // the keyboard would turn the next scan into one that vanishes without a
      // trace, the worst failure this screen has. And "nothing reached the
      // journal" is a claim about a real day file on a real filesystem.
      useTallWindow(tester);

      final Directory dir =
          Directory.systemTemp.createTempSync('am-te-laat-annuleren-');
      addTearDown(() => deleteTempDir(dir));

      final _CountingRefusalBeep beep = _CountingRefusalBeep();
      final _RecordingTicketTransport tickets = _RecordingTicketTransport();

      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: FileJournalStore(dir),
        credentials: InMemoryOperatorCredentialStore(),
        deskId: 'onthaal-annuleren',
      );
      addTearDown(desk.dispose);

      // A desk with a printer, so a ticket for the wrong student would show.
      final LocalPreferences preferences = LocalPreferences(
        InMemoryLocalPreferenceStore(
          <String, Object?>{'lateArrivalPrinterId': 'balie-printer'},
        ),
      );
      await preferences.load();

      final harness = ReconcileHarness(
        ssInitial: lateArrivalSnap(),
        smartschool: lateArrivalSnap(),
        liveSettings: LiveSettings(const AppSettings(
          ticketPrinters: <TicketPrinter>[
            TicketPrinter(
              id: 'balie-printer',
              label: 'Balie',
              host: 'bonprinter-balie.invalid',
            ),
          ],
        )),
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
        refusalBeep: beep,
        ticketTransport: tickets,
        preferences: preferences,
      ));
      await tester.pumpAndSettle();

      /// Scans [code] the way the wedge does: the digits, then Enter.
      Future<void> scan(String code) async {
        for (final String character in code.split('')) {
          await tester.sendKeyEvent(
            _scannerKeys[character]!,
            character: character,
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }

      String textOf(String key) =>
          tester.widget<Text>(find.byKey(ValueKey<String>(key))).data ?? '';

      String indicatorText() =>
          tester
              .widget<Text>(find.descendant(
                of: find
                    .byKey(const ValueKey<String>('late-scanner-indicator')),
                matching: find.byType(Text),
              ))
              .data ??
          '';

      final Finder cancel =
          find.byKey(const ValueKey<String>('late-scan-cancel'));
      final Finder idle = find.byKey(const ValueKey<String>('late-scan-idle'));

      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();
      expect(indicatorText(), 'KLAAR OM TE SCANNEN');
      expect(cancel, findsNothing, reason: 'nothing on screen to cancel');

      // --- The wrong card, let go of with the button. --------------------------
      await scan('123456');
      expect(textOf('late-scan-name'), 'Jonas Peeters');
      expect(cancel, findsOneWidget);

      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(idle, findsOneWidget);
      expect(
          find.byKey(const ValueKey<String>('late-scan-name')), findsNothing);
      expect(
        indicatorText(),
        'KLAAR OM TE SCANNEN',
        reason: 'the button must not keep the keyboard from the scanner',
      );

      // --- The right card lands at once — no click, no refusal. ----------------
      await scan('223344');
      expect(textOf('late-scan-name'), 'Lea Janssens');
      expect(find.byKey(const ValueKey<String>('late-refusal')), findsNothing);

      // --- Escape does the same, without reaching for the mouse. ---------------
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(idle, findsOneWidget);
      expect(indicatorText(), 'KLAAR OM TE SCANNEN');

      // --- The right student, registered. --------------------------------------
      await scan('223344');
      expect(textOf('late-scan-name'), 'Lea Janssens');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();
      // Never `pumpAndSettle` alone for the journal's real file I/O (#425, #453).
      await pumpUntil(
        tester,
        'the registration to be flushed to the journal',
        () => desk.journal!.records.isNotEmpty,
      );
      await pumpUntil(
        tester,
        'the ticket to reach its printer',
        () => tickets.sent.isNotEmpty,
      );

      // Only the right student is on record — in memory and in the day file.
      expect(
        desk.journal!.records.map((LateArrivalRecord r) => r.displayName),
        <String>['Lea Janssens'],
      );
      final List<File> dayFiles =
          dir.listSync().whereType<File>().toList(growable: false);
      expect(dayFiles, hasLength(1));
      final String onDisk = dayFiles.single.readAsStringSync();
      expect(onDisk, contains('Lea Janssens'));
      expect(onDisk, isNot(contains('Jonas Peeters')));

      // Exactly one ticket, and it is hers.
      expect(tickets.sent, hasLength(1));
      expect(
        String.fromCharCodes(tickets.sent.single),
        contains('Lea Janssens'),
      );
      // And the desk never told anybody off along the way.
      expect(beep.played, 0);
      expect(idle, findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a registration Smartschool refused is sent again by Opnieuw proberen, '
        'and one entered by hand is taken off the list after a confirmation — '
        'both still so after a restart (#460)', (WidgetTester tester) async {
      // The bug, end to end. Opnieuw proberen sat right under "de mislukte
      // registraties worden niet vanzelf opnieuw geprobeerd" and did nothing
      // for them, so a refused registration could only reach Smartschool by
      // hand — and then stayed *mislukt* on the desk for the whole retention
      // window, with nothing able to clear it.
      //
      // This needs the real app. The retry is a chain through every layer —
      // the button, the desk, the journal's requeue on a real file, the
      // drain's next write — and its result is a list the drain's status
      // stream redraws on the real tab. "Manueel ingevoerd" pushes a real
      // dialog route over a shell that keeps every destination mounted, and
      // the scan tab must hand the keyboard to it and take it back after, or
      // the next card vanishes. "Still so after a restart" is a claim about a
      // day file on disk, read back by the next launch.
      //
      // The presence writer is a fake, permanently: a presence write is a write
      // against the school's tenant, and the live-testing policy keeps those
      // out of CI.
      useTallWindow(tester);

      final Directory dir =
          Directory.systemTemp.createTempSync('am-te-laat-460-');
      addTearDown(() => deleteTempDir(dir));
      final Directory journalDir =
          Directory('${dir.path}${Platform.pathSeparator}journaal');

      // Smartschool refuses the first two writes — Jonas's, then Lea's — the
      // way v1.4.0 did on 2026-10-07, and accepts everything after.
      final _RecordingPresenceWriter writer = _RecordingPresenceWriter()
        ..failures.addAll(const <Object>[
          PresenceRejected('Empty response from /Presence/Main/getConfig.'),
          PresenceRejected('Empty response from /Presence/Main/getConfig.'),
        ]);

      // One shared settings document naming the Smartschool site, read by the
      // scan tab and by the desk's drain alike.
      const AppSettings base = AppSettings();
      final LiveSettings live = LiveSettings(
        base.copyWith(
          smartschool:
              base.smartschool.copyWith(uri: 'https://arcadia.smartschool.be'),
        ),
      );
      final harness = ReconcileHarness(
        ssInitial: lateArrivalSnap(),
        smartschool: lateArrivalSnap(),
        liveSettings: live,
      );

      LateArrivalDesk? desk;

      /// Launches (or relaunches) the desk over the same journal directory —
      /// which is all a restart changes here.
      Future<LateArrivalDesk> launch() async {
        await tester.pumpWidget(const SizedBox.shrink());
        desk?.dispose();
        final LateArrivalDesk built = LateArrivalDesk(
          journalStore: FileJournalStore(journalDir),
          credentials: InMemoryOperatorCredentialStore(
            const SmartschoolOperatorLogin(
              username: 'ann.peeters',
              password: 'zeergeheim',
            ),
          ),
          deskId: 'onthaal-460',
          settings: live,
          writerFor: (_, __) => writer,
        );
        desk = built;
        await tester.pumpWidget(AccountManagerApp(
          session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
          graph: graph,
          reconcileBootstrap: harness.bootstrap,
          connection: ConnectionServices(store: InMemoryConnectionStore()),
          desk: built,
          // Nothing here should beep or print; both are recorders anyway, so
          // a slip cannot buzz the build machine or reach a printer.
          refusalBeep: _CountingRefusalBeep(),
          ticketTransport: _RecordingTicketTransport(),
          preferences: LocalPreferences.inMemory(),
        ));
        await tester.pumpAndSettle();
        await tester.tap(railTab('Te laat'));
        await tester.pumpAndSettle();
        await pumpUntil(
          tester,
          'the desk to open its journal and attach the drain',
          () => built.ready && built.draining,
        );
        return built;
      }

      Future<void> scan(String code) async {
        for (final String character in code.split('')) {
          await tester.sendKeyEvent(
            _scannerKeys[character]!,
            character: character,
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }

      String textOf(Key key) => tester.widget<Text>(find.byKey(key)).data ?? '';

      String indicatorText() =>
          tester
              .widget<Text>(find.descendant(
                of: find
                    .byKey(const ValueKey<String>('late-scanner-indicator')),
                matching: find.byType(Text),
              ))
              .data ??
          '';

      LateArrivalRecord recordOf(String name) => desk!.journal!.records
          .lastWhere((LateArrivalRecord r) => r.displayName == name);

      /// Scans [code], picks the first reason, and waits until the drain has
      /// given up on it — Smartschool refused it.
      Future<LateArrivalRecord> registerRefused(
          String code, String name) async {
        await scan(code);
        expect(textOf(const ValueKey<String>('late-scan-name')), name);
        await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
        await tester.pumpAndSettle();
        // Real file I/O and a real background drain behind the tap (#425):
        // wait on what happened, never on a frame.
        await pumpUntil(
          tester,
          'the drain to give up on $name',
          () =>
              desk!.journal!.records
                  .any((LateArrivalRecord r) => r.displayName == name) &&
              recordOf(name).status == LateArrivalStatus.failed,
        );
        return recordOf(name);
      }

      final Finder failedBadge =
          find.byKey(const ValueKey<String>('late-queue-failed'));
      final Finder retry =
          find.byKey(const ValueKey<String>('late-queue-retry'));
      final Finder dialog =
          find.byKey(const ValueKey<String>('late-handled-dialog'));
      Finder failureLine(LateArrivalRecord r) =>
          find.byKey(ValueKey<String>('late-queue-failure-${r.id}'));
      Finder handledButton(LateArrivalRecord r) =>
          find.byKey(ValueKey<String>('late-queue-handled-${r.id}'));

      // --- Two students, two registrations Smartschool refused. ---------------
      await launch();
      final LateArrivalRecord jonas =
          await registerRefused('123456', 'Jonas Peeters');
      final LateArrivalRecord lea =
          await registerRefused('223344', 'Lea Janssens');

      expect(find.text('2 MISLUKT'), findsOneWidget);
      expect(
        textOf(ValueKey<String>('late-queue-failure-${jonas.id}')),
        allOf(contains('Jonas Peeters, 3MTa'), contains('getConfig')),
      );
      expect(failureLine(lea), findsOneWidget);
      expect(retry, findsOneWidget);
      expect(
        textOf(const ValueKey<String>('late-queue-line')),
        contains('niet vanzelf opnieuw geprobeerd'),
      );

      // --- Lea was entered in Smartschool by hand. First a change of mind. ----
      await tester.ensureVisible(handledButton(lea));
      await tester.pumpAndSettle();
      await tester.tap(handledButton(lea));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(
        textOf(const ValueKey<String>('late-handled-message')),
        allOf(
          contains('Lea Janssens (3MTa)'),
          contains('niet naar Smartschool verstuurd'),
        ),
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('late-handled-cancel')));
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(desk!.journal!.byId(lea.id)!.status, LateArrivalStatus.failed);
      expect(find.text('2 MISLUKT'), findsOneWidget);
      expect(failureLine(lea), findsOneWidget);

      // --- …then for real. ----------------------------------------------------
      await tester.ensureVisible(handledButton(lea));
      await tester.pumpAndSettle();
      await tester.tap(handledButton(lea));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey<String>('late-handled-confirm')));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        "Lea's registration to be marked as entered by hand, and her line to "
        'leave the list',
        () =>
            desk!.journal!.byId(lea.id)!.status ==
                LateArrivalStatus.handledManually &&
            failureLine(lea).evaluate().isEmpty,
      );

      expect(dialog, findsNothing);
      expect(failureLine(lea), findsNothing);
      expect(handledButton(lea), findsNothing);
      expect(find.text('1 MISLUKT'), findsOneWidget);
      expect(failureLine(jonas), findsOneWidget);
      // The keyboard went to the dialog and came back: the next card lands
      // without a click. The reclaim is a post-frame callback — wait for it.
      await pumpUntil(
        tester,
        'the keyboard to come back to the scanner after the dialog closed',
        () => indicatorText() == 'KLAAR OM TE SCANNEN',
      );

      // --- Opnieuw proberen: Jonas goes out again, Lea does not. --------------
      final int attemptsBefore = writer.attempts.length;
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        "Jonas's registration to be confirmed by Smartschool, and the "
        'mislukt badge to go',
        () =>
            desk!.journal!.byId(jonas.id)!.status ==
                LateArrivalStatus.confirmed &&
            failedBadge.evaluate().isEmpty,
      );

      expect(writer.userIds, <int>[12016]);
      // One more write, Jonas's, and guarded: hours after a scan, a retry may
      // not overwrite an absence recorded since.
      expect(
        writer.attempts.skip(attemptsBefore).toList(),
        <(int, bool)>[(12016, true)],
      );
      expect(failedBadge, findsNothing);
      expect(failureLine(jonas), findsNothing);
      expect(retry, findsNothing);
      expect(find.text('0 IN WACHTRIJ'), findsOneWidget);
      expect(
        textOf(const ValueKey<String>('late-queue-line')),
        'Alles is naar Smartschool verstuurd.',
      );

      // --- Restart: the day file says the same. -------------------------------
      final LateArrivalDesk relaunched = await launch();
      expect(relaunched.journal!.byId(jonas.id)!.status,
          LateArrivalStatus.confirmed);
      expect(relaunched.journal!.byId(lea.id)!.status,
          LateArrivalStatus.handledManually);
      // Lea is not deleted — append-only, and "what happened to this scan" is
      // still answerable — but she is off the list for good.
      expect(relaunched.journal!.records, hasLength(2));
      expect(failedBadge, findsNothing);
      expect(retry, findsNothing);
      expect(writer.userIds, <int>[12016], reason: 'nothing more was sent');
      final String onDisk = journalDir
          .listSync()
          .whereType<File>()
          .map((File f) => f.readAsStringSync())
          .join();
      expect(onDisk, contains('"handled-manually"'));
      expect(onDisk, contains('"requeuedByOperator":true'));

      // Unmount before letting go of the desk, so the scope is not listening to
      // a disposed notifier.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      desk?.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a Presence answer that cannot be read — a gateway\'s error page — is '
        'retried and lands, and the desk never shows the registration as '
        'mislukt (#461)', (WidgetTester tester) async {
      // The bug, end to end. A proxy in front of Smartschool answered one
      // Presence request with its 502 page, and the desk gave the registration
      // up at once: *mislukt*, for a hiccup that was over seconds later.
      //
      // This needs the real app, because the fix is a chain no single layer
      // shows: the library's typed error, the real `SmartschoolPresenceWriter`
      // classifying it, the real drain backing off and sending it again, the
      // journal on a real file, and the queue panel the drain's status redraws
      // on the real tab. Only the Smartschool session underneath the writer is
      // a fake — a presence write is a write against the school's tenant, and
      // the live-testing policy keeps those out of CI.
      useTallWindow(tester);

      final Directory dir =
          Directory.systemTemp.createTempSync('am-te-laat-461-');
      addTearDown(() => deleteTempDir(dir));
      final Directory journalDir =
          Directory('${dir.path}${Platform.pathSeparator}journaal');

      // The first write meets the gateway's page; the second waits at the
      // gate until the test has looked at the desk in between.
      final _ScriptedPresenceSession session = _ScriptedPresenceSession()
        ..failures.add(
          ss.SmartschoolPresenceUnreadableAnswerError.fromPage(
            '<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head>'
            '<body><center><h1>502 Bad Gateway</h1></center></body></html>',
            path: '/Presence/Main/getConfig',
            statusCode: 502,
          ),
        )
        ..gate = Completer<void>();
      addTearDown(() {
        // Never leave the drain hanging on the gate, whatever failed first.
        final Completer<void>? gate = session.gate;
        if (gate != null && !gate.isCompleted) gate.complete();
      });

      const AppSettings base = AppSettings();
      final LiveSettings live = LiveSettings(
        base.copyWith(
          smartschool:
              base.smartschool.copyWith(uri: 'https://arcadia.smartschool.be'),
        ),
      );
      final harness = ReconcileHarness(
        ssInitial: lateArrivalSnap(),
        smartschool: lateArrivalSnap(),
        liveSettings: live,
      );
      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: FileJournalStore(journalDir),
        credentials: InMemoryOperatorCredentialStore(
          const SmartschoolOperatorLogin(
            username: 'ann.peeters',
            password: 'zeergeheim',
          ),
        ),
        deskId: 'onthaal-461',
        settings: live,
        // The production writer, over the fake session: the classification is
        // what is under test.
        writerFor: (_, __) => SmartschoolPresenceWriter(session),
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
        refusalBeep: _CountingRefusalBeep(),
        ticketTransport: _RecordingTicketTransport(),
        preferences: LocalPreferences.inMemory(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        'the desk to open its journal and attach the drain',
        () => desk.ready && desk.draining,
      );

      String textOf(Key key) => tester.widget<Text>(find.byKey(key)).data ?? '';
      final Finder failedBadge =
          find.byKey(const ValueKey<String>('late-queue-failed'));

      // --- Jonas is late; Smartschool's gateway is having a bad second. -------
      for (final String character in '123456'.split('')) {
        await tester.sendKeyEvent(
          _scannerKeys[character]!,
          character: character,
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(textOf(const ValueKey<String>('late-scan-name')), 'Jonas Peeters');
      await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
      await tester.pumpAndSettle();

      // The first write came back unreadable; after its backoff the drain is
      // sending it again. Real file I/O and a real background drain behind the
      // tap (#425): wait on what happened, never on a frame.
      await pumpUntil(
        tester,
        'the drain to send the registration a second time after the 502',
        () => session.calls == 2,
      );
      final LateArrivalRecord jonas = desk.journal!.records.single;

      // In between, the desk says it is still sending — not that it failed.
      expect(jonas.status, isNot(LateArrivalStatus.failed));
      expect(desk.journal!.failures, isEmpty);
      expect(failedBadge, findsNothing);
      expect(find.text('1 IN WACHTRIJ'), findsOneWidget);
      expect(
        textOf(const ValueKey<String>('late-queue-line')),
        'Deze registraties worden op de achtergrond naar Smartschool '
        'verstuurd.',
      );
      expect(
          find.byKey(const ValueKey<String>('late-queue-retry')), findsNothing);

      // --- Smartschool answers again. ------------------------------------------
      session.gate!.complete();
      await pumpUntil(
        tester,
        "Jonas's registration to be confirmed by Smartschool",
        () =>
            desk.journal!.byId(jonas.id)!.status ==
                LateArrivalStatus.confirmed &&
            find.text('0 IN WACHTRIJ').evaluate().isNotEmpty,
      );

      expect(session.accepted, <int>[12016]);
      // An unreadable answer says nothing about the session: no new login.
      expect(session.signIns, 0);
      expect(failedBadge, findsNothing);
      expect(
        textOf(const ValueKey<String>('late-queue-line')),
        'Alles is naar Smartschool verstuurd.',
      );
      // The day file never held a give-up for it, not even for a moment.
      final String onDisk = journalDir
          .listSync()
          .whereType<File>()
          .map((File f) => f.readAsStringSync())
          .join();
      expect(onDisk, contains('"confirmed"'));
      expect(onDisk, isNot(contains('"failed"')));

      // Unmount before letting go of the desk, so the scope is not listening to
      // a disposed notifier.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      desk.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a registration given up on because Smartschool kept answering '
        'unreadably, or could not be reached, reads as a Dutch sentence on its '
        'mislukt line, with the library\'s words behind Details (#463)',
        (WidgetTester tester) async {
      // The bug, end to end. A Smartschool outage that outlasts the drain's
      // backoff leaves a registration *mislukt*, and the line said why in a
      // Dart type name and an English sentence about JSON — to the operator
      // who has to choose between Opnieuw proberen and Manueel ingevoerd.
      //
      // This needs the real app, because the words travel through every
      // layer: the library's typed error, the real `SmartschoolPresenceWriter`
      // passing it on unchanged, the real drain retrying it to the end of its
      // attempts and putting it into words with the describer the desk wires
      // in, the journal on a real file, and the queue panel splitting the
      // sentence from the library's text on the real tab, with real fonts.
      // Only the Smartschool session under the writer is a fake: a presence
      // write is a write against the school's tenant, and the live-testing
      // policy keeps those out of CI.
      useTallWindow(tester);

      final Directory dir =
          Directory.systemTemp.createTempSync('am-te-laat-463-');
      addTearDown(() => deleteTempDir(dir));
      final Directory journalDir =
          Directory('${dir.path}${Platform.pathSeparator}journaal');

      // Every attempt at Jonas meets the gateway's page; every attempt at Lea
      // meets a Smartschool that cannot be reached. After that it answers.
      const ss.SmartschoolConnectionError unreachable =
          ss.SmartschoolConnectionError(
        'Unable to reach Smartschool at https://arcadia.smartschool.be: the '
        'connection failed (SocketException: Connection refused)',
      );
      final _ScriptedPresenceSession session = _ScriptedPresenceSession()
        ..failures.addAll(<Object>[
          for (int i = 0; i < 5; i++)
            ss.SmartschoolPresenceUnreadableAnswerError.fromPage(
              '<!DOCTYPE html><html><head><title>502 Bad Gateway</title>'
              '</head><body><center><h1>502 Bad Gateway</h1></center></body>'
              '</html>',
              path: '/Presence/Main/getConfig',
              statusCode: 502,
            ),
          for (int i = 0; i < 5; i++) unreachable,
        ]);

      const AppSettings base = AppSettings();
      final LiveSettings live = LiveSettings(
        base.copyWith(
          smartschool:
              base.smartschool.copyWith(uri: 'https://arcadia.smartschool.be'),
        ),
      );
      final harness = ReconcileHarness(
        ssInitial: lateArrivalSnap(),
        smartschool: lateArrivalSnap(),
        liveSettings: live,
      );
      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: FileJournalStore(journalDir),
        credentials: InMemoryOperatorCredentialStore(
          const SmartschoolOperatorLogin(
            username: 'ann.peeters',
            password: 'zeergeheim',
          ),
        ),
        deskId: 'onthaal-463',
        settings: live,
        // The production writer, over the fake session.
        writerFor: (_, __) => SmartschoolPresenceWriter(session),
        // The drain's five attempts, without half a minute of real backoff.
        drainBackoff: const RetryBackoff(
          base: Duration(milliseconds: 1),
          max: Duration(milliseconds: 1),
        ),
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
        refusalBeep: _CountingRefusalBeep(),
        ticketTransport: _RecordingTicketTransport(),
        preferences: LocalPreferences.inMemory(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        'the desk to open its journal and attach the drain',
        () => desk.ready && desk.draining,
      );

      String textOf(Key key) => tester.widget<Text>(find.byKey(key)).data ?? '';

      /// Scans [code], picks the first reason, and waits until the drain has
      /// spent its attempts on it and given it up.
      Future<LateArrivalRecord> registerGivenUp(
        String code,
        String name,
      ) async {
        for (final String character in code.split('')) {
          await tester.sendKeyEvent(
            _scannerKeys[character]!,
            character: character,
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(textOf(const ValueKey<String>('late-scan-name')), name);
        await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
        await tester.pumpAndSettle();
        // Real file I/O and a real background drain behind the tap (#425):
        // wait on what happened, never on a frame.
        await pumpUntil(
          tester,
          'the drain to give up on $name',
          () => desk.journal!.failures
              .any((LateArrivalRecord r) => r.displayName == name),
        );
        return desk.journal!.failures
            .singleWhere((LateArrivalRecord r) => r.displayName == name);
      }

      // --- Jonas: the gateway's 502 page, five times over. ---------------------
      final LateArrivalRecord jonas =
          await registerGivenUp('123456', 'Jonas Peeters');
      // --- Lea: Smartschool cannot be reached at all. ---------------------------
      final LateArrivalRecord lea =
          await registerGivenUp('223344', 'Lea Janssens');

      // Retried to the end of the attempts, both of them — only the words
      // changed — and never signed in again for a network that was down.
      expect(session.calls, 10);
      expect(session.failures, isEmpty);
      expect(session.signIns, 0);
      expect(find.text('2 MISLUKT'), findsOneWidget);

      // The lines the operator reads: a Dutch sentence each, with no type name
      // and none of the library's English.
      expect(
        textOf(ValueKey<String>('late-queue-failure-${jonas.id}')),
        'Jonas Peeters, 3MTa — Smartschool gaf een antwoord dat niet gelezen '
        'kon worden (HTTP 502). Meestal is Smartschool dan even niet '
        'bereikbaar; probeer opnieuw zodra het weer werkt.',
      );
      expect(
        textOf(ValueKey<String>('late-queue-failure-${lea.id}')),
        'Lea Janssens, 3MTa — Smartschool was niet bereikbaar vanaf deze '
        'computer. Probeer opnieuw zodra de netwerkverbinding in orde is; lukt '
        'het dan nog niet, test de aanmelding bij Instellingen → Te laat.',
      );

      // The library's words are one click away, for whoever has to fix it.
      Finder details(LateArrivalRecord r) =>
          find.byKey(ValueKey<String>('late-queue-failure-details-${r.id}'));
      Finder detail(LateArrivalRecord r) =>
          find.byKey(ValueKey<String>('late-queue-failure-detail-${r.id}'));
      expect(detail(jonas), findsNothing);
      await tester.ensureVisible(details(jonas));
      await tester.pumpAndSettle();
      await tester.tap(details(jonas));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(detail(jonas)).data,
        allOf(
          startsWith('SmartschoolPresenceUnreadableAnswerError: '),
          contains('/Presence/Main/getConfig'),
          contains('502 Bad Gateway'),
        ),
      );
      expect(detail(lea), findsNothing);
      await tester.ensureVisible(details(lea));
      await tester.pumpAndSettle();
      await tester.tap(details(lea));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(detail(lea)).data,
        '$unreachable',
      );

      // And on disk, under the same record, for whoever reads the journal.
      final String onDisk = journalDir
          .listSync()
          .whereType<File>()
          .map((File f) => f.readAsStringSync())
          .join();
      expect(onDisk, contains('Smartschool gaf een antwoord'));
      expect(onDisk, contains('SmartschoolPresenceUnreadableAnswerError'));
      expect(onDisk, contains('SmartschoolConnectionError'));

      // --- Smartschool is back; the operator does what the line said. ---------
      final Finder retry =
          find.byKey(const ValueKey<String>('late-queue-retry'));
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await pumpUntil(
        tester,
        'both registrations to be confirmed by Smartschool',
        () =>
            desk.journal!.byId(jonas.id)!.status ==
                LateArrivalStatus.confirmed &&
            desk.journal!.byId(lea.id)!.status == LateArrivalStatus.confirmed &&
            find.text('0 IN WACHTRIJ').evaluate().isNotEmpty,
      );
      expect(session.accepted, <int>[12016, 12017]);
      expect(find.byKey(const ValueKey<String>('late-queue-failed')),
          findsNothing);
      expect(
        textOf(const ValueKey<String>('late-queue-line')),
        'Alles is naar Smartschool verstuurd.',
      );

      // Unmount before letting go of the desk, so the scope is not listening to
      // a disposed notifier.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      desk.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a login Smartschool refuses is tried once: the queue stands still with '
        'the cause in Dutch and the library\'s words behind Details, a new scan '
        'logs in for nobody, and a corrected login in Instellingen sends it all '
        '(#466)', (WidgetTester tester) async {
      // The bug, end to end. The operator's Smartschool password changed. Every
      // write made the client log in and Smartschool refused it, and the drain
      // signed in again and wrote again: seven refused logins for the first
      // registration, and as many again for every later scan — a morning of
      // late students was some sixty refused logins against the operator's own
      // account, which Smartschool locks after enough of them.
      //
      // This needs the real app, because the fix is a chain no single layer
      // shows: the library's typed refusal, the real
      // `SmartschoolPresenceWriter` telling the drain to stand down, the real
      // drain not waking for the next scan, the journal on a real file, the
      // log the desk writes to, the queue panel saying why on the real tab with
      // real fonts, and the desk building a new drain when Instellingen saves
      // a corrected login. Only the Smartschool session under each writer is a
      // fake: a presence write is a write against the school's tenant, and the
      // live-testing policy keeps those out of CI.
      useTallWindow(tester);

      final Directory dir =
          Directory.systemTemp.createTempSync('am-te-laat-466-');
      addTearDown(() => deleteTempDir(dir));
      final Directory journalDir =
          Directory('${dir.path}${Platform.pathSeparator}journaal');

      // One session per login, as `SmartschoolPresenceWriter.forOperator`
      // builds one: Smartschool refuses the stored password on every login,
      // and takes the corrected one.
      const ss.SmartschoolInvalidCredentialsError wrongPassword =
          ss.SmartschoolInvalidCredentialsError();
      final Map<String, _ScriptedPresenceSession> sessions =
          <String, _ScriptedPresenceSession>{};

      const AppSettings base = AppSettings();
      final AppSettings withSite = base.copyWith(
        smartschool:
            base.smartschool.copyWith(uri: 'https://arcadia.smartschool.be'),
      );
      final LiveSettings live = LiveSettings(withSite);
      final harness = ReconcileHarness(
        ssInitial: lateArrivalSnap(),
        smartschool: lateArrivalSnap(),
        liveSettings: live,
      );
      final LogBuffer log = LogBuffer();
      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: FileJournalStore(journalDir),
        credentials: InMemoryOperatorCredentialStore(
          const SmartschoolOperatorLogin(
            username: 'ann.peeters',
            password: 'zeergeheim',
          ),
        ),
        deskId: 'onthaal-466',
        settings: live,
        // The production writer, over a fake session for each login.
        writerFor: (SmartschoolOperatorLogin login, _) {
          final _ScriptedPresenceSession session = _ScriptedPresenceSession();
          if (login.password == 'zeergeheim') session.refusal = wrongPassword;
          sessions[login.password] = session;
          return SmartschoolPresenceWriter(session);
        },
        log: log,
        // Should the drain ever retry a refusal again, it gets there in
        // milliseconds and fails the counts below, rather than half a minute.
        drainBackoff: const RetryBackoff(
          base: Duration(milliseconds: 1),
          max: Duration(milliseconds: 1),
        ),
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        // The settings document too: the corrected login is saved through
        // Instellingen, as the operator saves it.
        settingsBootstrap: () async => SettingsServices(
          store: InMemorySettingsStore(withSite),
          secrets: InMemorySecretProvider(const {}),
          liveSettings: live,
        ),
        reconcileBootstrap: harness.bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
        refusalBeep: _CountingRefusalBeep(),
        ticketTransport: _RecordingTicketTransport(),
        preferences: LocalPreferences.inMemory(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        'the desk to open its journal and attach the drain',
        () => desk.ready && desk.draining,
      );
      final _ScriptedPresenceSession refused = sessions['zeergeheim']!;

      String textOf(Key key) => tester.widget<Text>(find.byKey(key)).data ?? '';
      final Finder queueLine =
          find.byKey(const ValueKey<String>('late-queue-line'));
      final Finder retry =
          find.byKey(const ValueKey<String>('late-queue-retry'));

      /// Scans [code] and picks the first reason, and returns once the
      /// registration is on disk, in the journal.
      Future<LateArrivalRecord> registerLate(String code, String name) async {
        final int before = desk.journal!.records.length;
        for (final String character in code.split('')) {
          await tester.sendKeyEvent(
            _scannerKeys[character]!,
            character: character,
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(textOf(const ValueKey<String>('late-scan-name')), name);
        await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
        await tester.pumpAndSettle();
        // Real file I/O behind the tap (#425): wait on what happened, never
        // on a frame.
        await pumpUntil(
          tester,
          'the registration of $name to reach the journal',
          () => desk.journal!.records.length > before,
        );
        return desk.journal!.records
            .lastWhere((LateArrivalRecord r) => r.displayName == name);
      }

      // --- Jonas is late; the stored password no longer works. ----------------
      final LateArrivalRecord jonas =
          await registerLate('123456', 'Jonas Peeters');
      await pumpUntil(
        tester,
        'the drain to stand down over the refused login',
        () =>
            desk.drain!.status.credentialsRefused &&
            !desk.drain!.status.draining,
      );
      await desk.drain!.settle();

      // One refused login — the one the write made — and not one more.
      expect(refused.calls, 1);
      expect(refused.signIns, 0);
      // Nothing is wrong with the registration: queued, not mislukt.
      expect(desk.journal!.byId(jonas.id)!.status, LateArrivalStatus.pending);
      expect(desk.journal!.failures, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('late-queue-failed')),
        findsNothing,
      );
      expect(find.text('1 IN WACHTRIJ'), findsOneWidget);

      // The line the operator reads: why nothing is sent, what Smartschool
      // refused and where to fix it, in Dutch — no type name, no English.
      const String refusedLine =
          'Het versturen naar Smartschool is gestopt tot de aanmelding in orde '
          'is. Smartschool aanvaardde de gebruikersnaam of het wachtwoord niet. '
          'Pas de aanmelding aan bij Instellingen → Te laat, test ze met '
          'Aanmelding testen en probeer daarna opnieuw. Niets is verloren — '
          'alles staat bewaard op deze computer.';
      expect(textOf(const ValueKey<String>('late-queue-line')), refusedLine);
      expect(retry, findsOneWidget);

      // The library's words are one click away, for whoever has to fix it.
      final Finder details =
          find.byKey(const ValueKey<String>('late-queue-line-details'));
      final Finder detail =
          find.byKey(const ValueKey<String>('late-queue-line-detail'));
      expect(detail, findsNothing);
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(tester.widget<SelectableText>(detail).data, '$wrongPassword');

      // And in the log, once, with both.
      List<String> logged() => <String>[
            for (final LogEntry entry in log.entries)
              if (entry.isError) entry.message,
          ];
      expect(
        logged().single,
        allOf(
          contains('tot de aanmelding in orde is'),
          contains('Smartschool aanvaardde de gebruikersnaam of het '
              'wachtwoord niet.'),
          contains('$wrongPassword'),
        ),
      );

      // --- Lea is late too. ---------------------------------------------------
      // Until #466 her scan woke the drain, and it logged in with the refused
      // password all over again. Now she waits in the queue with Jonas.
      final LateArrivalRecord lea =
          await registerLate('223344', 'Lea Janssens');
      await desk.drain!.settle();
      await tester.pumpAndSettle();
      expect(refused.calls, 1);
      expect(refused.signIns, 0);
      expect(desk.journal!.byId(lea.id)!.status, LateArrivalStatus.pending);
      expect(find.text('2 IN WACHTRIJ'), findsOneWidget);
      expect(textOf(const ValueKey<String>('late-queue-line')), refusedLine);
      expect(logged(), hasLength(1));

      // --- Opnieuw proberen: the operator's own call, worth one login. --------
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await pumpUntil(
        tester,
        'the drain to try the login once more and stand down again',
        () =>
            refused.calls == 2 &&
            desk.drain!.status.credentialsRefused &&
            !desk.drain!.status.draining,
      );
      await desk.drain!.settle();
      await tester.pumpAndSettle();
      expect(refused.calls, 2);
      expect(refused.signIns, 0);
      expect(desk.journal!.pending, hasLength(2));
      expect(desk.journal!.failures, isEmpty);
      expect(queueLine, findsOneWidget);
      expect(textOf(const ValueKey<String>('late-queue-line')), refusedLine);

      // The day file holds both registrations, queued, and no give-up.
      final String onDisk = journalDir
          .listSync()
          .whereType<File>()
          .map((File f) => f.readAsStringSync())
          .join();
      expect(onDisk, contains('Jonas Peeters'));
      expect(onDisk, contains('Lea Janssens'));
      expect(onDisk, isNot(contains('"failed"')));

      // --- The operator corrects the password in Instellingen. ----------------
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await openLateArrivalSettingsTab(tester);
      final Finder password =
          find.byKey(const ValueKey('settings-smartschool-operator-password'));
      await tester.ensureVisible(password);
      await tester.pumpAndSettle();
      // The tap is not decoration: `enterText` alone would go to a dead text
      // connection.
      await tester.tap(password);
      await tester.pumpAndSettle();
      await tester.enterText(password, 'nieuwgeheim');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      // A changed login is a new drain, and the queue goes out by itself.
      await pumpUntil(
        tester,
        'both registrations to be confirmed with the corrected login',
        () =>
            desk.journal!.byId(jonas.id)!.status ==
                LateArrivalStatus.confirmed &&
            desk.journal!.byId(lea.id)!.status == LateArrivalStatus.confirmed,
      );
      expect(sessions['nieuwgeheim']!.accepted, <int>[12016, 12017]);
      expect(sessions['nieuwgeheim']!.signIns, 0);
      expect(refused.calls, 2, reason: 'never again with the refused password');

      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        'the queue panel to show an empty queue',
        () => find.text('0 IN WACHTRIJ').evaluate().isNotEmpty,
      );
      expect(
        textOf(const ValueKey<String>('late-queue-line')),
        'Alles is naar Smartschool verstuurd.',
      );
      expect(retry, findsNothing);

      // Unmount before letting go of the desk, so the scope is not listening to
      // a disposed notifier.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      desk.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the desk picks its ticket printer off the shared list, prints on the '
        'one it picked, and is still pointed at it after a restart (#436)',
        (WidgetTester tester) async {
      // Every claim of #436 needs this level, and each for its own reason.
      //
      // "The selection survives a restart" is a statement about a file on disk
      // written by one widget tree and read by the next — there is no widget to
      // pump for that. "The dropdown hands the keyboard back" is a statement
      // about the *engine's* focus manager with a real menu route pushed above
      // a real shell that keeps every visited destination mounted: the menu is
      // the one thing on this page that legitimately takes the keyboard, and a
      // scan tab that failed to take it back would swallow the next badge with
      // no error, no ticket and no record. And "the ticket goes to the printer
      // this desk chose, with that printer's header" is the composition of the
      // shared document, the machine's own preferences and the print path.
      //
      // Nothing here reaches a printer: the transport is a recorder, per the
      // repo's live-testing policy.
      useTallWindow(tester);

      final Directory dir =
          Directory.systemTemp.createTempSync('am-te-laat-436-');
      addTearDown(() => deleteTempDir(dir));

      // This machine's own preference file — the real one, on the real
      // filesystem, so "it is still there after a restart" means what it says.
      final File preferenceFile = File(
        '${dir.path}${Platform.pathSeparator}$localPreferencesFileName',
      );

      final _RecordingTicketTransport tickets = _RecordingTicketTransport();
      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: FileJournalStore(
          Directory('${dir.path}${Platform.pathSeparator}journaal'),
        ),
        credentials: InMemoryOperatorCredentialStore(),
        deskId: 'onthaal-436',
      );
      addTearDown(desk.dispose);

      // Two printers at two desks, with two school codes on their tickets —
      // the shared document every desk reads (#435).
      final LiveSettings live = LiveSettings(const AppSettings(
        ticketPrinters: <TicketPrinter>[
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
        ],
      ));
      final harness = ReconcileHarness(
        ssInitial: lateArrivalSnap(),
        smartschool: lateArrivalSnap(),
        liveSettings: live,
      );

      /// Launches (or relaunches) this machine over its own preference file —
      /// which is the only thing a restart changes here.
      Future<void> launch() async {
        await tester.pumpWidget(const SizedBox.shrink());
        final LocalPreferences preferences = LocalPreferences(
          FileLocalPreferenceStore(preferenceFile),
        );
        await preferences.load();
        await tester.pumpWidget(AccountManagerApp(
          session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
          graph: graph,
          reconcileBootstrap: harness.bootstrap,
          connection: ConnectionServices(store: InMemoryConnectionStore()),
          desk: desk,
          ticketTransport: tickets,
          preferences: preferences,
        ));
        await tester.pumpAndSettle();
        await tester.tap(railTab('Te laat'));
        await tester.pumpAndSettle();
      }

      Future<void> scan(String code) async {
        for (final String character in code.split('')) {
          await tester.sendKeyEvent(
            _scannerKeys[character]!,
            character: character,
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }

      /// Scans [code] and confirms it with the first reason — one whole
      /// student, from badge to ticket — and returns only once that student is
      /// really registered, and printed for when [prints].
      ///
      /// **Never `pumpAndSettle` alone** (#425). `_confirm` flushes the journal
      /// to disk and prints only afterwards, and the integration binding's
      /// `pumpAndSettle` returns the moment no frame is scheduled — which, in
      /// the middle of that `await`, is immediately. It is what lost this test
      /// on the CI runner while passing on a faster disk: the second student's
      /// ticket had simply not been handed to the transport yet. So each step
      /// waits on the thing that actually happened.
      Future<void> register(String code, {required bool prints}) async {
        final int registered = desk.journal!.records.length;
        final int printed = tickets.hosts.length;

        await scan(code);
        // The student is on screen before any reason can be pressed — and a
        // burst the hidden input never received would leave the row disabled,
        // so this is also where a lost keyboard shows up as itself rather than
        // as a missing ticket three lines further down.
        expect(
          find.byKey(const ValueKey<String>('late-scan-name')),
          findsOneWidget,
          reason: 'the scan of $code reached the hidden input',
        );

        await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
        await tester.pumpAndSettle();
        await pumpUntil(
          tester,
          'the registration of $code to be flushed to the journal',
          () => desk.journal!.records.length > registered,
        );
        if (prints) {
          await pumpUntil(
            tester,
            'the ticket for $code to reach its printer',
            () => tickets.hosts.length > printed,
          );
        }
      }

      Future<void> pickPrinter(String option) async {
        final Finder select =
            find.byKey(const ValueKey<String>('late-printer-select'));
        await tester.ensureVisible(select);
        await tester.pumpAndSettle();
        await tester.tap(select);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey<String>('late-printer-option-$option')),
        );
        await tester.pumpAndSettle();
      }

      String selectedPrinter() =>
          tester
              .widget<Text>(
                find.byKey(const ValueKey<String>('late-printer-selected')),
              )
              .data ??
          '';

      String indicatorText() =>
          tester
              .widget<Text>(find.descendant(
                of: find
                    .byKey(const ValueKey<String>('late-scanner-indicator')),
                matching: find.byType(Text),
              ))
              .data ??
          '';

      // --- A desk nobody has pointed at a printer. -----------------------------
      await launch();
      expect(selectedPrinter(), 'Geen printer');

      // --- One printer, one ticket, on that printer. ---------------------------
      await pickPrinter('p-onthaal');
      expect(selectedPrinter(), 'Onthaal');
      // The keyboard came straight back: the next burst lands without a click,
      // which is the whole focus criterion. The reclaim is a post-frame
      // callback, so wait for it rather than assume the pump above ran it —
      // a timeout here is still a failure, and a loud one.
      await pumpUntil(
        tester,
        'the keyboard to come back to the scanner after the menu closed',
        () => indicatorText() == 'KLAAR OM TE SCANNEN',
      );

      await register('123456', prints: true);
      expect(desk.journal!.records, hasLength(1));
      expect(tickets.hosts, <String>['bon-onthaal.invalid']);
      expect(String.fromCharCodes(tickets.sent.single), contains('SMA'));
      expect(
        String.fromCharCodes(tickets.sent.single),
        contains('Jonas Peeters'),
      );

      // --- The operator moves to the other desk. ------------------------------
      await pickPrinter('p-toren');
      expect(selectedPrinter(), 'Toren');
      await register('223344', prints: true);
      expect(
          tickets.hosts, <String>['bon-onthaal.invalid', 'bon-toren.invalid']);
      expect(String.fromCharCodes(tickets.sent.last), contains('SMT'));
      expect(String.fromCharCodes(tickets.sent.last), contains('Lea Janssens'));

      // --- Geen printer: registered, nothing printed, no fault. ---------------
      await pickPrinter('none');
      expect(selectedPrinter(), 'Geen printer');
      await register('123456', prints: false);
      expect(desk.journal!.records, hasLength(3));
      // The registration is on disk, and the journal is flushed *before*
      // anything is printed — so "nothing was sent" is settled here, not a
      // guess about timing. The final list below closes it for good.
      expect(tickets.hosts, hasLength(2), reason: 'nothing was sent');

      // --- The desk is set up for tomorrow, and restarted. --------------------
      await pickPrinter('p-toren');
      // The write is `async` and lands in a file nothing on screen reflects, so
      // wait for the file rather than for a frame (#425).
      await pumpUntil(
        tester,
        "the printer choice to reach this machine's preference file",
        () =>
            preferenceFile.existsSync() &&
            preferenceFile.readAsStringSync().contains('p-toren'),
      );
      // By id, never by address: a DHCP move must not unselect this desk.
      expect(
        preferenceFile.readAsStringSync(),
        isNot(contains('bon-toren.invalid')),
      );

      await launch();
      expect(selectedPrinter(), 'Toren');
      await register('123456', prints: true);
      // Exactly three tickets for four registrations, in this order: the one
      // made under **Geen printer** never produced one, and no late arrival of
      // it can sneak in behind the others.
      expect(desk.journal!.records, hasLength(4));
      expect(
        tickets.hosts,
        <String>[
          'bon-onthaal.invalid',
          'bon-toren.invalid',
          'bon-toren.invalid',
        ],
      );

      // Unmount before the teardown lets go of the desk, so the scope is not
      // listening to a disposed notifier and the journal is closed first.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a Cosmos container that was never provisioned reads as one sentence at '
        'the desk, with the raw error behind Details (#414)',
        (WidgetTester tester) async {
      // The failure this closes, in the real app. `lateArrivals` was added to the
      // container spec (#403) but the provisioning script had not been re-run, so
      // the desk's bootstrap died on a data-plane container create that no
      // data-plane role can ever be granted — and the reception screen printed the
      // whole CosmosException, request headers and replica URI and all, inside a
      // Dutch sentence.
      //
      // Why this needs the real app and not the widget test beside it: the note is
      // a row inside the scan tab's real column, in the real Plink font, at the
      // real window size, reached through the real rail. A multi-line error spliced
      // into that row is exactly the kind of overflow a widget test rendering the
      // screen alone in Ahem cannot see, and "the sentence is short enough to fit"
      // is the whole claim.
      useTallWindow(tester);

      final Directory dir =
          Directory.systemTemp.createTempSync('am-te-laat-403-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final LateArrivalDesk desk = LateArrivalDesk(
        journalStore: FileJournalStore(dir),
        credentials: InMemoryOperatorCredentialStore(),
        deskId: 'onthaal-403',
      );
      addTearDown(desk.dispose);

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        // What an unprovisioned container actually does to the desk's bootstrap.
        reconcileBootstrap: () async => throw CosmosContainerNotProvisioned(
          'lateArrivals',
          403,
          jsonEncode(<String, String>{
            'code': 'Forbidden',
            'message':
                'Request blocked by Auth accountmanager-cosmos-arcadia : The '
                    'given request [POST /dbs/accountmanager/colls] cannot be '
                    'authorized by AAD token in data plane. Learn more: '
                    'https://aka.ms/cosmos-native-rbac. ActivityId: 0000, '
                    'Microsoft.Azure.Documents.Common/2.14.0, '
                    'x-ms-request-charge: 0, x-ms-session-token: 0:-1#42',
          }),
        ),
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        desk: desk,
        preferences: LocalPreferences.inMemory(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Te laat'));
      await tester.pumpAndSettle();

      final Finder note = find.byKey(const ValueKey<String>('late-list-error'));
      expect(note, findsOneWidget);
      final String sentence = tester.widget<Text>(note).data ?? '';
      expect(sentence, contains('De leerlingenlijst kon niet geladen worden.'));
      expect(sentence, contains('niet gescand worden'));
      // None of the machine's words reach the counter.
      expect(sentence, isNot(contains('CosmosException')));
      expect(sentence, isNot(contains('x-ms-')));
      expect(sentence, isNot(contains('Microsoft.Azure.Documents.Common')));
      expect(sentence, isNot(contains('aka.ms')));
      // Two lines of real text at a real window size — not a wall of it.
      expect(sentence.length, lessThan(160));

      // Nothing is hidden that a colleague would need to fix it: it is one tap
      // away, and it names the container and the script rather than the AAD wall.
      final Finder detail =
          find.byKey(const ValueKey<String>('late-note-detail'));
      expect(detail, findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('late-note-details')));
      await tester.pumpAndSettle();
      final String raw = tester.widget<SelectableText>(detail).data ?? '';
      expect(
          raw, contains("Cosmos container 'lateArrivals' is not provisioned"));
      expect(raw, contains('tool/provision-cosmos.ps1'));

      // Real fonts, real layout: an error note may never overflow the scan tab.
      expect(tester.takeException(), isNull);
    });
  });
}

/// Counts the refused-scan tone instead of sounding it (#407).
class _CountingRefusalBeep implements RefusalBeep {
  int played = 0;

  @override
  void play() => played++;
}

/// Keeps every ticket that reached "the printer" (#406), and the address each
/// one was sent to — which is what the desk's printer selection decides (#436).
class _RecordingTicketTransport implements TicketTransport {
  final List<List<int>> sent = <List<int>>[];
  final List<String> hosts = <String>[];

  @override
  Future<void> send({
    required String host,
    required int port,
    required List<int> bytes,
    required Duration timeout,
  }) async {
    hosts.add(host);
    sent.add(List<int>.of(bytes));
  }
}

/// The key the scanner presses for each digit of a WISA id.
const Map<String, LogicalKeyboardKey> _scannerKeys =
    <String, LogicalKeyboardKey>{
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

/// The student the late-arrival cases register, with the two identifiers a
/// Presence write addresses.
const ScannedStudent _lateStudent = ScannedStudent(
  scanCode: '123456',
  wisaId: '123456',
  smartschoolUid: 'jonas.peeters',
  displayName: 'Jonas Peeters',
  className: '3MTa',
  internalUserId: 4242,
  classGroupId: 77,
);

/// Stands in for Smartschool's Presence module.
///
/// A fake and not a live call, deliberately and permanently: `setLate` is a
/// **write** against the school's real tenant, and the repo's live-testing
/// policy forbids CI writing one. What this run proves is the wiring around it.
class _RecordingPresenceWriter implements LatePresenceWriter {
  /// Every write Smartschool accepted, by internal user id.
  final List<int> userIds = <int>[];

  /// Thrown one per call, in order, before a write is accepted — a
  /// Smartschool that refuses the next writes (#460). Empty by default, so a
  /// test that never fills it sees every write accepted.
  final List<Object> failures = <Object>[];

  /// Every attempt, accepted or not, as `userId` and whether it carried the
  /// guard a requeued write must (#460).
  final List<(int, bool)> attempts = <(int, bool)>[];

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
    attempts.add((userId, keepRecordedAbsence));
    if (failures.isNotEmpty) throw failures.removeAt(0);
    userIds.add(userId);
  }

  @override
  Future<void> reauthenticate() async {}
}

/// Stands in for the signed-in Smartschool session *under* the production
/// [SmartschoolPresenceWriter], so a run goes through the writer's own failure
/// classification (#461) rather than around it.
///
/// A fake for the same reason [_RecordingPresenceWriter] is one: `setLate` is
/// a write against the school's real tenant.
class _ScriptedPresenceSession implements SmartschoolPresenceSession {
  /// Every call, accepted or not.
  int calls = 0;

  /// Every write Smartschool accepted, by internal user id.
  final List<int> accepted = <int>[];

  /// How often the writer asked for a fresh sign-in.
  int signIns = 0;

  /// Thrown one per call, in order, as the library throws them.
  final List<Object> failures = <Object>[];

  /// Thrown one per [signIn], in order — a login Smartschool refuses (#464).
  /// Once it runs out, a sign-in succeeds.
  final List<Object> signInFailures = <Object>[];

  /// While set, thrown by every call and every [signIn], before anything else
  /// — a stored login Smartschool refuses for as long as it is not corrected
  /// (#466). Each throw is a refused login against the operator's account.
  Object? refusal;

  /// When set, a write that is not failed waits for it before it is accepted,
  /// so a test can look at the desk while that write is in flight.
  Completer<void>? gate;

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required ss.DayPart part,
    required bool withoutValidReason,
    required String motivation,
    Set<String>? onlyReplacing,
  }) async {
    calls++;
    final Object? refused = refusal;
    if (refused != null) throw refused;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    await gate?.future;
    accepted.add(userId);
  }

  @override
  Future<void> signIn() async {
    signIns++;
    final Object? refused = refusal;
    if (refused != null) throw refused;
    if (signInFailures.isNotEmpty) throw signInFailures.removeAt(0);
  }
}
