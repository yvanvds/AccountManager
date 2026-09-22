// BuildContext lookups after `pumpAndSettle` are safe in tests: the tree is
// still mounted and the tester drives the frames synchronously.
// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemException, Platform;

import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/late_arrivals/file_journal_store.dart';
import 'package:account_manager/src/late_arrivals/late_arrival_desk.dart';
import 'package:account_manager/src/late_arrivals/late_arrival_printer.dart'
    show TicketTransport;
import 'package:account_manager/src/late_arrivals/operator_credentials.dart';
import 'package:account_manager/src/late_arrivals/refusal_beep.dart'
    show RefusalBeep;
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
        ScanRegisterable,
        ScannedStudent,
        TicketPrinter,
        composeMotivation,
        defaultLateArrivalReasons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

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
      addTearDown(() async {
        // Windows refuses to delete a directory while any handle into it is
        // still open, and the app under test is only torn down *after* this
        // callback runs — the journal write of the last registration can still
        // be settling. A few short retries cover that gap; a temp directory
        // left behind is never worth failing a run over.
        for (var i = 0; i < 20 && dir.existsSync(); i++) {
          try {
            dir.deleteSync(recursive: true);
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });

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
      /// student, from badge to ticket.
      Future<void> register(String code) async {
        await scan(code);
        await tester.tap(find.byKey(const ValueKey<String>('late-reason-0')));
        await tester.pumpAndSettle();
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
      // which is the whole focus criterion.
      expect(indicatorText(), 'KLAAR OM TE SCANNEN');

      await register('123456');
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
      await register('223344');
      expect(
          tickets.hosts, <String>['bon-onthaal.invalid', 'bon-toren.invalid']);
      expect(String.fromCharCodes(tickets.sent.last), contains('SMT'));
      expect(String.fromCharCodes(tickets.sent.last), contains('Lea Janssens'));

      // --- Geen printer: registered, nothing printed, no fault. ---------------
      await pickPrinter('none');
      expect(selectedPrinter(), 'Geen printer');
      await register('123456');
      expect(desk.journal!.records, hasLength(3));
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
      await register('123456');
      expect(tickets.hosts.last, 'bon-toren.invalid');

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
  final List<int> userIds = <int>[];

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required HalfDay part,
    required bool withoutValidReason,
    required String motivation,
  }) async =>
      userIds.add(userId);

  @override
  Future<void> reauthenticate() async {}
}
