import 'package:account_manager/src/late_arrivals/late_arrival_desk.dart';
import 'package:account_manager/src/late_arrivals/operator_credentials.dart';
import 'package:account_state/account_state.dart'
    show AppSettings, LiveSettings;
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';

/// The one thing the drain does to the outside world, recorded instead of done.
///
/// Every test here binds this. A presence write is a *write* against a live
/// school tenant and the repo's live-testing policy keeps those out of CI
/// entirely, so the wiring — does a recovered journal resume, does a saved login
/// attach a worker, does a missing one leave the desk registering anyway — can
/// only ever be proven against a fake.
class _RecordingWriter implements LatePresenceWriter {
  final List<int> written = <int>[];
  int signIns = 0;

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required bool withoutValidReason,
    required String motivation,
  }) async {
    written.add(userId);
  }

  @override
  Future<void> reauthenticate() async => signIns++;
}

/// A journal store whose day listing fails — a `%APPDATA%` an antivirus has
/// locked, a directory somebody's roaming profile did not sync.
class _BrokenJournalStore implements JournalStore {
  @override
  Future<void> append(SchoolDay day, String line) async {}

  @override
  Future<List<SchoolDay>> days() async =>
      throw const FileSystemExceptionLike('toegang geweigerd');

  @override
  Future<void> delete(SchoolDay day) async {}

  @override
  String locationOf(SchoolDay day) => 'kapot';

  @override
  Future<String> read(SchoolDay day) async => '';
}

class FileSystemExceptionLike implements Exception {
  const FileSystemExceptionLike(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A mirror store that refuses to answer — a Cosmos that is unreachable at
/// launch, which must degrade to a warning and never to a stall.
class _UnreachableMirrorStore implements LateArrivalMirrorStore {
  @override
  Future<void> put(MirroredRegistration entry) async =>
      throw StateError('geen verbinding');

  @override
  Future<List<MirroredRegistration>> readDay(SchoolDay day) async =>
      throw StateError('geen verbinding');
}

const _student = ScannedStudent(
  scanCode: '123456',
  wisaId: '123456',
  smartschoolUid: 'jonas.peeters',
  displayName: 'Jonas Peeters',
  className: '3MTa',
  internalUserId: 4242,
  classGroupId: 77,
);

AppSettings _withSite(String uri) {
  const AppSettings base = AppSettings();
  return base.copyWith(smartschool: base.smartschool.copyWith(uri: uri));
}

/// Lets the fire-and-forget work the desk starts actually run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  const SmartschoolOperatorLogin login = SmartschoolOperatorLogin(
    username: 'ann.peeters',
    password: 'geheim',
  );

  LateArrivalDesk deskWith({
    JournalStore? journalStore,
    OperatorCredentialStore? credentials,
    LateArrivalMirrorStore? mirrorStore,
    LiveSettings? settings,
    LatePresenceWriterFactory? writerFor,
    SmartschoolSignInProbe? signInProbe,
  }) =>
      LateArrivalDesk(
        journalStore: journalStore ?? InMemoryJournalStore(),
        credentials: credentials ?? InMemoryOperatorCredentialStore(),
        deskId: 'onthaal-pc-1',
        mirrorStore: mirrorStore,
        settings: settings,
        writerFor: writerFor,
        signInProbe: signInProbe,
      );

  Future<LateArrivalRecord> register(LateArrivalDesk desk) =>
      desk.journal!.register(
        scan: const ScanRegisterable(_student),
        scannedAt: DateTime(2026, 9, 7, 8, 42),
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );

  group('start (#409)', () {
    test('opens the journal and reports what it recovered', () async {
      final desk = deskWith();
      await desk.start();

      expect(desk.ready, isTrue);
      expect(desk.recovery, isNotNull);
      expect(desk.journal!.pending, isEmpty);
      desk.dispose();
    });

    test('is idempotent — a second call does not re-open anything', () async {
      final desk = deskWith();
      await desk.start();
      final LateArrivalJournal first = desk.journal!;
      await desk.start();
      expect(identical(desk.journal, first), isTrue);
      desk.dispose();
    });

    test('a journal directory that cannot be read still opens a desk',
        () async {
      // The whole "never a stall" rule in one case: a reception desk that will
      // not open because of its own cache directory is the worst failure on
      // offer. It degrades to a session-only journal and says so.
      final desk = deskWith(journalStore: _BrokenJournalStore());
      await desk.start();

      expect(desk.ready, isTrue, reason: 'the desk still opens');
      expect(
        desk.warnings.join(' '),
        allOf(contains('in het geheugen'), contains('toegang geweigerd')),
      );
      // And it still registers.
      final record = await register(desk);
      expect(desk.journal!.pending.map((r) => r.id), <String>[record.id]);
      desk.dispose();
    });
  });

  group('the drain (#409)', () {
    test('does not run without a login, and says so in the operator\'s words',
        () async {
      final writer = _RecordingWriter();
      final settings =
          LiveSettings(_withSite('https://arcadia.smartschool.be'));
      final desk = deskWith(
        settings: settings,
        writerFor: (_, __) => writer,
      );
      await desk.start();

      expect(desk.draining, isFalse);
      expect(
        desk.warnings.join(' '),
        allOf(
          contains('geen Smartschool-aanmelding'),
          contains('Instellingen'),
        ),
      );

      // The half that matters most: an unconfigured desk still registers.
      final record = await register(desk);
      await _settle();
      expect(writer.written, isEmpty);
      expect(desk.journal!.byId(record.id)!.status, LateArrivalStatus.pending);
      desk.dispose();
    });

    test('does not run before the shared settings name a Smartschool site',
        () async {
      final writer = _RecordingWriter();
      final desk = deskWith(
        credentials: InMemoryOperatorCredentialStore(login),
        // No document published yet — which is every launch, because the
        // settings live in Cosmos behind the sign-in.
        settings: LiveSettings(),
        writerFor: (_, __) => writer,
      );
      await desk.start();

      expect(desk.draining, isFalse);
      expect(desk.warnings.join(' '), contains('Smartschool-adres'));
      desk.dispose();
    });

    test(
        'attaches itself the moment the settings document arrives, with no '
        'relaunch', () async {
      final writer = _RecordingWriter();
      final settings = LiveSettings();
      final desk = deskWith(
        credentials: InMemoryOperatorCredentialStore(login),
        mirrorStore: InMemoryLateArrivalMirrorStore(),
        settings: settings,
        writerFor: (_, __) => writer,
      );
      await desk.start();
      expect(desk.draining, isFalse);

      settings.publish(_withSite('https://arcadia.smartschool.be'));
      await _settle();

      expect(desk.draining, isTrue);
      // A fully configured desk has nothing to tell the operator.
      expect(desk.warnings, isEmpty);
      desk.dispose();
    });

    test('signs in with the operator\'s own login against the configured host',
        () async {
      SmartschoolOperatorLogin? seen;
      String? seenHost;
      final writer = _RecordingWriter();
      final desk = deskWith(
        credentials: InMemoryOperatorCredentialStore(login),
        settings: LiveSettings(_withSite('https://arcadia.smartschool.be')),
        writerFor: (l, h) {
          seen = l;
          seenHost = h;
          return writer;
        },
      );
      await desk.start();

      expect(seen?.username, 'ann.peeters');
      expect(seen?.password, 'geheim');
      expect(seenHost, 'arcadia.smartschool.be');
      desk.dispose();
    });

    test('a registration reaches Smartschool', () async {
      final writer = _RecordingWriter();
      final desk = deskWith(
        credentials: InMemoryOperatorCredentialStore(login),
        settings: LiveSettings(_withSite('arcadia.smartschool.be')),
        writerFor: (_, __) => writer,
      );
      await desk.start();

      final record = await register(desk);
      await desk.drain!.settle();

      expect(writer.written, <int>[4242]);
      expect(
          desk.journal!.byId(record.id)!.status, LateArrivalStatus.confirmed);
      desk.dispose();
    });

    test('a recovered journal resumes draining at start, with nobody wiring it',
        () async {
      // The claim the issue is about. A previous run journalled a registration
      // and died before Smartschool took it; this run must send it without the
      // operator scanning anything.
      final store = InMemoryJournalStore();
      final crashed = await LateArrivalJournal.open(store);
      await crashed.register(
        scan: const ScanRegisterable(_student),
        scannedAt: DateTime(2026, 9, 7, 8, 42),
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );

      final writer = _RecordingWriter();
      final desk = deskWith(
        journalStore: store,
        credentials: InMemoryOperatorCredentialStore(login),
        settings: LiveSettings(_withSite('arcadia.smartschool.be')),
        writerFor: (_, __) => writer,
      );
      await desk.start();
      expect(desk.recovery!.pendingCount, 1);

      await desk.drain!.settle();
      expect(writer.written, <int>[4242]);
      desk.dispose();
    });
  });

  group('the login, from Instellingen (#409)', () {
    test('saving one persists it and starts draining without a relaunch',
        () async {
      final writer = _RecordingWriter();
      final credentials = InMemoryOperatorCredentialStore();
      final desk = deskWith(
        credentials: credentials,
        mirrorStore: InMemoryLateArrivalMirrorStore(),
        settings: LiveSettings(_withSite('arcadia.smartschool.be')),
        writerFor: (_, __) => writer,
      );
      await desk.start();

      // A registration made before the desk was configured.
      final record = await register(desk);
      await _settle();
      expect(writer.written, isEmpty);

      await desk.saveLogin(login);
      expect(await credentials.read(), isNotNull);
      expect(desk.draining, isTrue);
      expect(desk.warnings, isEmpty);

      // …and the queue that was waiting goes out.
      await desk.drain!.settle();
      expect(writer.written, <int>[4242]);
      expect(
          desk.journal!.byId(record.id)!.status, LateArrivalStatus.confirmed);
      desk.dispose();
    });

    test('clearing one stops the drain and says the desk no longer sends',
        () async {
      final writer = _RecordingWriter();
      final desk = deskWith(
        credentials: InMemoryOperatorCredentialStore(login),
        settings: LiveSettings(_withSite('arcadia.smartschool.be')),
        writerFor: (_, __) => writer,
      );
      await desk.start();
      expect(desk.draining, isTrue);

      await desk.clearLogin();
      expect(desk.draining, isFalse);
      expect(desk.login, isNull);
      expect(desk.warnings.join(' '), contains('geen Smartschool-aanmelding'));

      // Still a working desk.
      final record = await register(desk);
      await _settle();
      expect(desk.journal!.byId(record.id), isNotNull);
      desk.dispose();
    });

    test('an unrelated settings change does not tear down a working drain',
        () async {
      var built = 0;
      final settings = LiveSettings(_withSite('arcadia.smartschool.be'));
      final desk = deskWith(
        credentials: InMemoryOperatorCredentialStore(login),
        settings: settings,
        writerFor: (_, __) {
          built++;
          return _RecordingWriter();
        },
      );
      await desk.start();
      expect(built, 1);

      settings.publish(
        _withSite('arcadia.smartschool.be').copyWith(schoolPrefix: 'SMA'),
      );
      await _settle();
      expect(built, 1, reason: 'the same login against the same host');

      // A site correction *does* rebuild it — that is a different session.
      settings.publish(_withSite('sma.smartschool.be'));
      await _settle();
      expect(built, 2);
      desk.dispose();
    });
  });

  group('Aanmelding testen (#409)', () {
    test('reports a successful sign-in', () async {
      final desk = deskWith(
        settings: LiveSettings(_withSite('arcadia.smartschool.be')),
        signInProbe: (_, __) async {},
      );
      await desk.start();
      expect(await desk.testSignIn(login), isNull);
      desk.dispose();
    });

    test('keeps Smartschool\'s own wording for a failure', () async {
      final desk = deskWith(
        settings: LiveSettings(_withSite('arcadia.smartschool.be')),
        signInProbe: (_, __) async =>
            throw StateError('Foutieve gebruikersnaam of wachtwoord.'),
      );
      await desk.start();
      expect(
        await desk.testSignIn(login),
        contains('Foutieve gebruikersnaam of wachtwoord.'),
      );
      desk.dispose();
    });

    test('refuses a half-filled login before touching the network', () async {
      var probed = false;
      final desk = deskWith(
        settings: LiveSettings(_withSite('arcadia.smartschool.be')),
        signInProbe: (_, __) async => probed = true,
      );
      await desk.start();
      expect(
        await desk.testSignIn(
          const SmartschoolOperatorLogin(username: 'ann', password: ''),
        ),
        contains('wachtwoord'),
      );
      expect(probed, isFalse);
      desk.dispose();
    });

    test('says so when the site is not configured yet', () async {
      final desk = deskWith(
        settings: LiveSettings(),
        signInProbe: (_, __) async {},
      );
      await desk.start();
      expect(await desk.testSignIn(login), contains('Smartschool-adres'));
      desk.dispose();
    });

    test(
        'honours the host as typed, so a corrected address can be checked '
        'before it is saved', () async {
      String? against;
      final desk = deskWith(
        settings: LiveSettings(_withSite('oud.smartschool.be')),
        signInProbe: (_, String host) async => against = host,
      );
      await desk.start();
      await desk.testSignIn(login, host: 'nieuw.smartschool.be');
      expect(against, 'nieuw.smartschool.be');
      desk.dispose();
    });
  });

  group('the mirror (#409)', () {
    test('an unreachable shared store degrades to a warning, not a stall',
        () async {
      final desk = deskWith(mirrorStore: _UnreachableMirrorStore());
      await desk.start();
      // The reconciliation is fired and forgotten; give it a turn.
      await _settle();

      expect(desk.ready, isTrue);
      expect(desk.reconciliation?.available, isFalse);
      expect(desk.warnings.join(' '), contains('gedeelde kopie'));

      final record = await register(desk);
      expect(desk.journal!.byId(record.id), isNotNull);
      desk.dispose();
    });

    test('reconciles the day and hands back what another desk left behind',
        () async {
      final store = InMemoryLateArrivalMirrorStore();
      await store.put(
        MirroredRegistration(
          deskId: 'onthaal-pc-2',
          record: LateArrivalRecord(
            id: '2026-09-07-0001',
            day: SchoolDay.of(DateTime.now()),
            sequence: 1,
            scannedAt: DateTime.now(),
            smartschoolUid: 'lotte.claes',
            wisaId: '999',
            displayName: 'Lotte Claes',
            className: '4WEa',
            internalUserId: 1,
            classGroupId: 2,
            reasonLabel: 'Bus te laat',
            reasonIsValid: true,
            motivation: '08:40 – Bus te laat',
            status: LateArrivalStatus.pending,
          ),
          mirroredAt: DateTime.now(),
        ),
      );

      final desk = deskWith(mirrorStore: store);
      await desk.start();
      await _settle();

      expect(desk.reconciliation?.available, isTrue);
      expect(desk.reconciliation!.outstanding.single.deskId, 'onthaal-pc-2');
      expect(desk.warnings.join(' '), isNot(contains('gedeelde kopie')));
      desk.dispose();
    });

    test('a build with no shared store says the queue lives here only',
        () async {
      final desk = deskWith();
      await desk.start();
      expect(desk.warnings.join(' '), contains('geen gedeelde opslag'));
      desk.dispose();
    });
  });
}
