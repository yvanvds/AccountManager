/// The reception desk, assembled once per launch (#409).
///
/// #402 built the journal, #403 the Cosmos mirror, #404 the Smartschool drain —
/// and nothing in the app constructed any of them. This is that wiring, and it
/// is deliberately one object rather than three loose ones in `main()`, because
/// the three are not independent: the drain reads the journal, both the drain
/// and the mirror hang off the journal's single sink, and the whole assembly has
/// an ordering that has to be got right exactly once.
///
/// **The order, and why it is that order.**
///
/// 1. **Open the journal**, which replays the day files this machine already
///    holds. Everything a previous run did not finish is `pending` the moment
///    this returns — that is what "draining resumes after a restart" *is*, and
///    it is why the drain must be built after the journal rather than alongside
///    it.
/// 2. **Build the fan-out sink.** The journal takes one sink; the mirror and the
///    drain both want to be it, so [FanOutRecordSink] carries both — over a
///    growable list, because the drain is attached later than the journal is
///    opened (see below) and a sink that could not be added afterwards would
///    force the login to be known before the journal could be read.
/// 3. **Reconcile the mirror** for today, in the background. This is where a
///    colleague's machine learns what the dead laptop never drained, and where
///    this machine re-mirrors anything it wrote to disk but not to Cosmos.
/// 4. **Start draining.**
///
/// **Nothing here may block the desk.** Every step degrades to a line in
/// [warnings] rather than to a stall or a throw: no login configured, a journal
/// directory that cannot be read, a Cosmos that will not answer, a Smartschool
/// site that is not configured yet. A desk that cannot drain must still
/// register, print, and say plainly why the queue is not moving — the
/// registration is the thing that must never be lost, and it is safe on disk
/// before any of this is consulted.
///
/// **Why the drain is attached late rather than at start.** It needs two things
/// that are not known when the process starts: the operator's login (read from
/// disk, and editable in Instellingen without a relaunch) and the school's
/// Smartschool host, which lives in the *shared* settings document and is
/// therefore not loaded until something has signed in and read Cosmos. So the
/// desk watches [LiveSettings] and attaches the drain the moment both are
/// available — on nearly every launch that is a fraction of a second after the
/// Synchronisatie screen bootstraps, long before anybody is late, and it needs
/// no relaunch when an operator fixes a typo in either.
library;

import 'dart:async';

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart' show LiveSettings;
import 'package:flutter/widgets.dart';
import 'package:late_arrivals/late_arrivals.dart';

import 'operator_credentials.dart';

/// Builds the thing that actually writes a presence, for one login against one
/// Smartschool host.
///
/// A seam, and the single most important one in this file: a presence write is a
/// *write* against a live school tenant, so the repo's live-testing policy keeps
/// it out of CI entirely. Production passes a closure over
/// `SmartschoolPresenceWriter.forOperator`; every test passes a fake and proves
/// the wiring — that a recovered journal resumes, that a saved login attaches a
/// drain, that a missing one does not — without a school on the network.
typedef LatePresenceWriterFactory = LatePresenceWriter Function(
  SmartschoolOperatorLogin login,
  String host,
);

/// One launch's late-arrival stack: the journal, the mirror, the drain, and the
/// reasons any of them is not running.
class LateArrivalDesk extends ChangeNotifier {
  LateArrivalDesk({
    required this.journalStore,
    required this.credentials,
    required this.deskId,
    this.mirrorStore,
    this.settings,
    this.writerFor,
    this.signInProbe,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// A desk that remembers only for this session: an in-memory journal, an
  /// in-memory credential store, no mirror and no drain.
  ///
  /// The default [AccountManagerApp] binds when none is wired, for the same
  /// reason `LocalPreferences.inMemory()` is: a widget test then gets the
  /// *behaviour* — a real journal, real registration, real ordering — and only
  /// loses it at exit, so nothing downstream has to special-case "there is no
  /// desk".
  factory LateArrivalDesk.inMemory() => LateArrivalDesk(
        journalStore: InMemoryJournalStore(),
        credentials: InMemoryOperatorCredentialStore(),
        deskId: 'deze-computer',
      );

  /// Where this machine's day files live.
  final JournalStore journalStore;

  /// Where this operator's own Smartschool login is kept, encrypted (#409).
  final OperatorCredentialStore credentials;

  /// How this machine identifies itself in the shared mirror — the hostname in
  /// production.
  ///
  /// Human-meaningful on purpose: a colleague picking up a dead desk's queue
  /// reads "onthaal-pc-2" and knows which room to walk to. A generated id would
  /// be unique and useless.
  final String deskId;

  /// The shared store the day is mirrored to, or `null` on a build with no
  /// Cosmos configured — the desk then keeps its local journal and says the
  /// shared copy is not being kept.
  final LateArrivalMirrorStore? mirrorStore;

  /// The live settings document, which is where the Smartschool site comes from.
  ///
  /// Watched rather than read once: at process start the document has not been
  /// loaded yet (it lives in Cosmos, behind the sign-in), so reading it once here
  /// would mean no desk ever drained without a relaunch.
  final LiveSettings? settings;

  /// Builds the presence writer, or `null` on a build that cannot write
  /// presences at all.
  final LatePresenceWriterFactory? writerFor;

  /// The **Aanmelding testen** probe, or `null` when this build offers no test.
  final SmartschoolSignInProbe? signInProbe;

  /// Where the mirror and the drain report a persistent failure.
  final core.ILog? log;

  final DateTime Function() _now;

  /// The journal's single sink, over a growable list so the drain can join after
  /// the journal is already open. See the library doc.
  final List<LateArrivalRecordSink> _sinks = <LateArrivalRecordSink>[];

  final List<String> _startupWarnings = <String>[];

  LateArrivalJournal? _journal;
  LateArrivalMirror? _mirror;
  LateArrivalDrain? _drain;
  LateArrivalReconciliation? _reconciliation;
  SmartschoolOperatorLogin? _login;
  StreamSubscription<Object?>? _settingsSub;

  /// The login and host the current [_drain] was built for, so a settings change
  /// that touches neither does not tear down a working worker mid-queue.
  SmartschoolOperatorLogin? _drainLogin;
  String _drainHost = '';

  String _drainWarning = '';
  bool _started = false;
  bool _closed = false;

  /// This machine's journal, once [start] has opened it.
  LateArrivalJournal? get journal => _journal;

  /// The Smartschool drain, or `null` while there is no login (or no site) to
  /// build one from. Its [LateArrivalDrain.status] is what #407 puts on screen.
  LateArrivalDrain? get drain => _drain;

  /// The Cosmos mirror, or `null` on a build with no shared store.
  LateArrivalMirror? get mirror => _mirror;

  /// What opening the journal found and had to discard.
  JournalRecovery? get recovery => _journal?.recovery;

  /// What the startup reconciliation against the shared store found — including
  /// [LateArrivalReconciliation.outstanding], the queue a stand-in operator has
  /// to pick up. `null` until it has run, or on a build with no mirror.
  LateArrivalReconciliation? get reconciliation => _reconciliation;

  /// The login stored on this machine, or `null` when none is.
  ///
  /// Instellingen reads it to prefill the username and to merge a blank password
  /// field with what is already stored; nothing else should.
  SmartschoolOperatorLogin? get login => _login;

  /// Whether [start] has finished opening the journal.
  bool get ready => _journal != null;

  /// Whether registrations are currently being written to Smartschool.
  bool get draining => _drain != null;

  /// The Smartschool host the drain signs in against, from the shared document.
  /// Empty until that document has been loaded.
  String get smartschoolHost =>
      smartschoolHostFrom(settings?.current.smartschool.uri ?? '');

  /// Everything the operator has to be told, in the operator's words.
  ///
  /// Empty is the healthy state. Non-empty never means a registration was lost —
  /// it means something downstream of the journal is not running, which is
  /// exactly the class of failure that is invisible until somebody's absence
  /// turns up in a report weeks later.
  List<String> get warnings => <String>[
        ..._startupWarnings,
        if (_drainWarning.isNotEmpty) _drainWarning,
      ];

  /// Opens the journal, wires the sinks, reconciles the shared copy and starts
  /// draining. Idempotent, and it never throws.
  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;

    _login = await credentials.read();

    LateArrivalJournal? opened;
    try {
      opened = await LateArrivalJournal.open(
        journalStore,
        now: _now(),
        sink: FanOutRecordSink(_sinks),
      );
    } on Object catch (error) {
      // The one failure that would otherwise take the desk down with it. Fall
      // back to a session-only journal: registrations are still ordered, still
      // printed and still drained, they just do not survive a restart — which is
      // strictly better than a reception desk that will not open, and the
      // warning says so in as many words.
      _startupWarnings.add(
        'De bewaarde te-laatregistraties op deze computer konden niet gelezen '
        'worden ($error). Er wordt voor deze sessie in het geheugen '
        'bijgehouden: registreren en afdrukken werken gewoon, maar sluit de app '
        'niet af zolang er nog iets niet naar Smartschool verstuurd is.',
      );
      opened = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: _now(),
        sink: FanOutRecordSink(_sinks),
      );
    }
    if (_closed) return;
    _journal = opened;

    final LateArrivalMirrorStore? store = mirrorStore;
    if (store == null) {
      _startupWarnings.add(
        'Er is geen gedeelde opslag ingesteld, dus de registraties van deze '
        'balie staan alleen op deze computer. Een collega kan de wachtrij niet '
        'overnemen als deze machine uitvalt.',
      );
    } else {
      final LateArrivalMirror mirror = LateArrivalMirror(
        store: store,
        deskId: deskId,
        log: log,
      );
      _mirror = mirror;
      _sinks.add(mirror);
    }

    // The Smartschool site arrives with the settings document, which is loaded
    // after this runs. Watching it is what lets the drain start by itself.
    _settingsSub = settings?.changes.listen((Object? _) => _syncDrain());
    _syncDrain();
    notifyListeners();

    unawaited(_reconcile());
  }

  /// Persists [next] as this machine's login and rewires the drain around it.
  ///
  /// Throws when the credential could not be written — Instellingen reports
  /// that in place, because a save that silently did nothing would leave the
  /// operator believing the desk is configured when it is not.
  Future<void> saveLogin(SmartschoolOperatorLogin next) async {
    await credentials.write(next);
    _login = next;
    _syncDrain();
    notifyListeners();
  }

  /// Forgets this machine's login: nothing is drained afterwards, and the desk
  /// says so. Registrations keep being journalled and printed.
  Future<void> clearLogin() async {
    await credentials.clear();
    _login = null;
    _syncDrain();
    notifyListeners();
  }

  /// Signs in with [candidate] and reports the result in the operator's words.
  ///
  /// Returns `null` when the login worked, and the failure text otherwise —
  /// including for a build with no probe wired, which is a state to report
  /// rather than an exception to throw.
  ///
  /// [host] defaults to the configured site; Instellingen passes the URI *as
  /// typed*, so an operator can check a corrected address before committing it.
  Future<String?> testSignIn(
    SmartschoolOperatorLogin candidate, {
    String? host,
  }) async {
    final SmartschoolSignInProbe? probe = signInProbe;
    if (probe == null) {
      return 'Deze build kan de aanmelding niet testen.';
    }
    if (!candidate.isComplete) {
      return 'Vul eerst een gebruikersnaam en een wachtwoord in.';
    }
    final String against = (host ?? smartschoolHost).trim();
    if (against.isEmpty) {
      return 'Het Smartschool-adres is nog niet ingevuld. Vul het in op het '
          'tabblad Smartschool en probeer opnieuw.';
    }
    try {
      await probe(candidate, against);
      return null;
    } on Object catch (error) {
      return '$error';
    }
  }

  /// Picks the queue back up after the drain stood down — the operator's
  /// "opnieuw proberen", and also what a re-reconciliation is worth.
  void retryNow() {
    _drain?.retryNow();
    _mirror?.retryNow();
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_shutdown());
    super.dispose();
  }

  /// Releases the two workers. Fire-and-forget from [dispose] because closing a
  /// worker *settles* it — it waits out an in-flight write — and a widget tree
  /// tearing down must not block on a Smartschool round trip. Nothing is lost by
  /// not waiting: everything either worker was carrying is on disk.
  Future<void> _shutdown() async {
    await _settingsSub?.cancel();
    _settingsSub = null;
    final LateArrivalDrain? drain = _drain;
    final LateArrivalMirror? mirror = _mirror;
    _drain = null;
    _mirror = null;
    _sinks.clear();
    await drain?.close();
    await mirror?.close();
  }

  /// Reconciles the day against the shared store, once, in the background.
  ///
  /// Never awaited by [start] and never allowed to fail: an unreachable Cosmos
  /// at launch means the desk works off its own journal, exactly as it did
  /// before the mirror existed.
  Future<void> _reconcile() async {
    final LateArrivalMirror? mirror = _mirror;
    final LateArrivalJournal? journal = _journal;
    if (mirror == null || journal == null) return;
    LateArrivalReconciliation result;
    try {
      result = await mirror.reconcile(
        day: SchoolDay.of(_now()),
        local: journal.records,
      );
    } on Object catch (error) {
      // `reconcile` documents that it never throws; this is the belt to that
      // braces, because the one thing it must not do is take the launch down.
      result = LateArrivalReconciliation(
        day: SchoolDay.of(_now()),
        missingLocally: const <MirroredRegistration>[],
        requeued: 0,
        error: '$error',
      );
    }
    if (_closed) return;
    _reconciliation = result;
    if (!result.available) {
      _startupWarnings.add(
        'De gedeelde kopie van de te-laatregistraties kon niet gelezen worden '
        '(${result.error}). Deze balie werkt gewoon door met haar eigen lijst, '
        'maar een collega ziet de wachtrij van deze computer niet.',
      );
    }
    notifyListeners();
  }

  /// Builds, rebuilds or tears down the drain to match the login and the site.
  ///
  /// Called at start, on every settings publication and on every credential
  /// change. It is careful not to churn: a settings document that changed
  /// something else entirely leaves a working drain alone, mid-queue.
  void _syncDrain() {
    final LateArrivalJournal? journal = _journal;
    final LatePresenceWriterFactory? build = writerFor;
    if (journal == null || _closed) return;

    final SmartschoolOperatorLogin? login = _login;
    final String host = smartschoolHost;

    if (build == null) {
      _drainWarning = 'Deze build schrijft geen aanwezigheden naar '
          'Smartschool. De registraties worden wel bewaard en afgedrukt.';
      _detachDrain();
      return;
    }
    if (login == null || !login.isComplete) {
      _drainWarning =
          'Er is op deze computer geen Smartschool-aanmelding ingesteld, dus '
          'er wordt niets naar Smartschool geschreven. Registreren en '
          'afdrukken werken gewoon; de registraties blijven in de wachtrij '
          'staan. Stel de aanmelding in bij Instellingen → Te laat, onder '
          '"Te laat — Smartschool-aanmelding".';
      _detachDrain();
      return;
    }
    if (host.isEmpty) {
      _drainWarning =
          'Het Smartschool-adres is nog niet bekend, dus er wordt voorlopig '
          'niets naar Smartschool geschreven. De registraties blijven bewaard '
          'en worden verstuurd zodra de instellingen geladen zijn.';
      _detachDrain();
      return;
    }

    _drainWarning = '';
    // Same login, same host, worker already running: leave it be. Rebuilding
    // here would drop a session mid-queue every time anybody saved anything.
    if (_drain != null && identical(_drainLogin, login) && _drainHost == host) {
      return;
    }

    _detachDrain();
    _drainLogin = login;
    _drainHost = host;
    final LateArrivalDrain drain = LateArrivalDrain(
      journal: journal,
      writer: build(login, host),
      log: log,
    );
    _drain = drain;
    _sinks.add(drain);
    // Whatever the journal still owes, including everything a previous run left
    // behind — this is the resume.
    drain.start();
  }

  void _detachDrain() {
    final LateArrivalDrain? drain = _drain;
    if (drain == null) return;
    _drain = null;
    _drainLogin = null;
    _drainHost = '';
    _sinks.remove(drain);
    unawaited(drain.close());
  }
}

/// Hands the launch's [LateArrivalDesk] to whatever needs it, and starts it.
///
/// Mounted **inside** the sign-in gate, which is load-bearing rather than
/// incidental: the startup reconciliation reads Cosmos with the operator's own
/// AAD token, and starting it above the gate would race a second interactive
/// sign-in against the one the gate is already running — two browser windows for
/// one launch.
class LateArrivalDeskScope extends StatefulWidget {
  const LateArrivalDeskScope({
    super.key,
    required this.desk,
    required this.child,
  });

  final LateArrivalDesk desk;
  final Widget child;

  /// The enclosing scope's desk, or `null` when there is none — which is what a
  /// widget test pumping one screen gets, and which every reader has to tolerate
  /// exactly as they tolerate an absent [LocalPreferencesScope].
  static LateArrivalDesk? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LateArrivalDeskScope>()?.desk;

  @override
  State<LateArrivalDeskScope> createState() => _LateArrivalDeskScopeState();
}

class _LateArrivalDeskScopeState extends State<LateArrivalDeskScope> {
  @override
  void initState() {
    super.initState();
    // Fired and forgotten: the first frame is built from this same `initState`,
    // so nothing on screen waits on a journal read, a Cosmos round trip or a
    // Smartschool session.
    unawaited(widget.desk.start());
  }

  @override
  Widget build(BuildContext context) => _LateArrivalDeskScope(
        desk: widget.desk,
        notifier: widget.desk,
        child: widget.child,
      );
}

class _LateArrivalDeskScope extends InheritedNotifier<LateArrivalDesk> {
  const _LateArrivalDeskScope({
    required this.desk,
    required super.notifier,
    required super.child,
  });

  final LateArrivalDesk desk;
}
