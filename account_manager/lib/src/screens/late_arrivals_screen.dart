/// **Te laat** — the reception desk's scan tab (#407).
///
/// The last slice of the late-arrival epic (#399) and the one that consumes all
/// the others: the scan resolver (#401), the journal (#402), the Cosmos mirror
/// (#403), the Smartschool drain (#404), the shared reason list (#405) and the
/// ticket printer (#406) all meet here, in front of a queue of students.
///
/// Everything on this screen is shaped by one measurement: how long a student
/// stands at the desk. That is why:
///
/// - **The keyboard focus is held, and reclaimed, aggressively.** The scanner is
///   a keyboard wedge — it types the WISA id and presses Enter, at whatever
///   window happens to own the focus. A lost focus is a scan that vanishes with
///   no error, no ticket and no record, which is by far the worst failure this
///   screen can have. So a single hidden [Focus] node owns the keyboard, every
///   interactive control on the page is wrapped in [ExcludeFocus] so a reason
///   button cannot take it away, a click anywhere on the page hands it back, and
///   a **klaar om te scannen** indicator says out loud whether it is currently
///   held.
///   (There is no [TextField] behind it: a text field brings a text-input
///   connection, an IME, autocorrect and a caret, none of which a barcode burst
///   wants, and the raw key stream is both simpler and easier to prove.)
/// - **The resolve is local.** [ScanResolver] is a hash lookup over the
///   Smartschool snapshot this session already holds; name and class are on
///   screen in the same frame as the Enter. No network call is on this path, and
///   no photo is shown — the school confirmed one is not needed.
/// - **Nothing is registered without a reason.** A scan waits for a button.
///   There is deliberately no timeout that registers an abandoned scan.
/// - **A scan that arrives while the previous student is still unconfirmed is
///   refused.** The student on screen stays; the second student rescans. Not
///   queued, not swapped, not auto-registered — because every one of those
///   alternatives can silently write one student's reason onto another
///   student's record. The refusal sounds a low, long square wave
///   ([RefusalBeep]) chosen to be unmistakable next to the scanner's own chirp,
///   which the operator hears all morning.
/// - **The order of the confirmation is fixed.** `journal.register` flushes to
///   disk and only then is the ticket printed and the screen cleared. A student
///   holding a ticket is therefore always a student on disk; the reverse — a
///   record whose ticket never came out — is the harmless direction, and it is
///   the one this is deliberately biased towards.
///
/// Two outcomes are reported apart on purpose. An **unknown** code (#401's
/// `ScanUnknown`) means the desk cannot help: the operator enters the absence in
/// Smartschool by hand and it is reviewed afterwards. A student who resolves by
/// name but carries no internal id or no class group (`ScanIncomplete`) is a
/// *data* problem — the operator sees a name on screen, so a refusal with no
/// explanation would read as a bug rather than as the repair request it is.
library;

import 'dart:async';

import 'package:account_state/account_state.dart' show AppSettings;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:late_arrivals/late_arrivals.dart';
import 'package:plink_design_system/plink_design_system.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;

import '../late_arrivals/late_arrival_desk.dart';
import '../late_arrivals/late_arrival_printer.dart';
import '../late_arrivals/reason_button_row.dart';
import '../late_arrivals/refusal_beep.dart';
import '../reconcile/reconcile_bootstrap.dart';
import '../settings/local_preferences.dart';
import '../shell/shell_navigation.dart';

/// How long a pause between two keystrokes starts a fresh code.
///
/// A handheld scanner types its whole burst in a few milliseconds. A gap wider
/// than this is a human, or a burst that never ended in Enter (the operator
/// clicked away mid-scan) — either way the characters already buffered are not
/// the front of the code now being typed, and silently prefixing them onto it
/// would turn a good scan into an unknown one.
const Duration lateArrivalScanBurstGap = Duration(seconds: 2);

/// The longest code accepted into the buffer.
///
/// A WISA id is six digits. This is only a guard against a stuck key filling
/// memory between one Enter and the next.
const int lateArrivalMaxScanLength = 64;

/// The scan tab.
class LateArrivalsScreen extends StatefulWidget {
  const LateArrivalsScreen({
    super.key,
    required this.bootstrap,
    this.beep,
    this.ticketTransport,
    this.now,
  });

  /// Assembles (or returns the already-assembled) reconcile stack, or `null`
  /// when Azure AD is not configured for this build.
  ///
  /// This screen wants two things out of it and nothing else: the Smartschool
  /// snapshot the scan index is built from, and the live settings document the
  /// reason buttons are read from. It deliberately does **not** open a session
  /// or pull anything — the desk resolves out of the snapshot the launch already
  /// seeded from the shared store.
  final Future<ReconcileServices> Function()? bootstrap;

  /// What a refused scan sounds like. `null` binds the real square wave; every
  /// test binds a recorder, because a test suite must not make the build machine
  /// buzz.
  final RefusalBeep? beep;

  /// How a ticket reaches the printer. `null` is the real TCP socket; a test
  /// binds a recorder so the print can be asserted without a device on the
  /// network.
  final TicketTransport? ticketTransport;

  /// The clock the scan time is read from. Injected only so a test can pin the
  /// minute that lands on the ticket and in the motivation.
  final DateTime Function()? now;

  @override
  State<LateArrivalsScreen> createState() => _LateArrivalsScreenState();
}

class _LateArrivalsScreenState extends State<LateArrivalsScreen> {
  /// The hidden input. Everything the scanner types arrives here.
  final FocusNode _scanner = FocusNode(debugLabel: 'te-laat-scanner');

  late final RefusalBeep _beep = widget.beep ?? SquareWaveRefusalBeep();
  late final DateTime Function() _now = widget.now ?? DateTime.now;

  /// The characters typed since the last Enter, and when the last one arrived.
  String _buffer = '';
  DateTime? _lastKeyAt;

  /// The scan on screen, and the moment it arrived — which is the time that
  /// reaches the ticket and the motivation, never the moment the reason was
  /// pressed.
  ScanResult? _held;
  DateTime? _heldAt;

  /// Why the last scan was refused, or empty. Cleared by the next accepted scan.
  String _refusal = '';

  /// Why the last confirmation could not be written, or empty.
  String _registerError = '';

  bool _confirming = false;

  ReconcileServices? _services;
  Object? _error;
  bool _busy = false;

  ss.SmartschoolSnapshot? _indexed;
  ScanResolver? _resolver;

  StreamSubscription<AppSettings>? _settingsSub;
  List<LateArrivalReason> _reasons = defaultLateArrivalReasons;

  LateArrivalDesk? _desk;
  LateArrivalDrain? _watchedDrain;
  StreamSubscription<LateArrivalDrainStatus>? _drainSub;
  LateArrivalDrainStatus? _drainStatus;

  LateArrivalPrinter? _printer;
  String _printerHost = '';
  bool _printerBound = false;

  /// Whether this is the destination the operator is looking at.
  ///
  /// The shell keeps visited screens mounted, so without this the scan tab would
  /// go on grabbing the keyboard while somebody types in Instellingen. Absent
  /// shell (a widget test pumping this screen alone) reads as visible.
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _scanner.addListener(_onFocusChanged);
    unawaited(_bootstrap());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Depending on the desk's scope is also how this screen learns that the
    // drain attached (it can only do so once the settings document has loaded)
    // and that a registration was written.
    _desk = LateArrivalDeskScope.maybeOf(context);
    _watchDrain(_desk?.drain);
    _bindPrinter(
      LocalPreferencesScope.maybeOf(context)?.lateArrivalPrinterHost ?? '',
    );

    final ShellTab? tab = ShellNavigation.maybeOf(context)?.current;
    final bool visible = tab == null || tab == ShellTab.teLaat;
    if (visible != _visible) {
      _visible = visible;
      if (visible) {
        _reclaimFocus();
      } else {
        // Hand the keyboard back rather than merely stopping the reclaim: the
        // operator switched tabs to type somewhere else.
        _scanner.unfocus();
      }
    } else if (visible) {
      _reclaimFocus();
    }
  }

  @override
  void dispose() {
    _services?.controller.removeListener(_adoptSnapshot);
    unawaited(_settingsSub?.cancel());
    unawaited(_drainSub?.cancel());
    _scanner.removeListener(_onFocusChanged);
    _scanner.dispose();
    _printer?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------------

  /// Resolves the shared stack, indexes its Smartschool snapshot and adopts the
  /// shared reason list.
  Future<void> _bootstrap() async {
    final Future<ReconcileServices> Function()? make = widget.bootstrap;
    if (make == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ReconcileServices services = await make();
      if (!mounted) return;
      _services?.controller.removeListener(_adoptSnapshot);
      _services = services;
      // A sync, a drift check or an apply on another tab replaces the snapshot;
      // a student enrolled this morning has to be scannable without a relaunch.
      services.controller.addListener(_adoptSnapshot);
      await _settingsSub?.cancel();
      _settingsSub = services.liveSettings.changes.listen(_adoptReasons);
      if (!mounted) return;
      setState(() {
        _adoptReasonList(services.liveSettings.current.lateArrivalReasons);
        _index(services.app.smartschool.snapshot);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _adoptSnapshot() {
    if (!mounted) return;
    final ss.SmartschoolSnapshot? next = _services?.app.smartschool.snapshot;
    if (identical(next, _indexed)) return;
    setState(() => _index(next));
  }

  /// Rebuilds the scan index. Construction walks the snapshot once; [resolve] is
  /// a constant-time lookup afterwards.
  void _index(ss.SmartschoolSnapshot? snapshot) {
    _indexed = snapshot;
    _resolver =
        snapshot == null ? null : ScanResolver.fromSmartschool(snapshot);
  }

  void _adoptReasons(AppSettings settings) {
    if (!mounted) return;
    setState(() => _adoptReasonList(settings.lateArrivalReasons));
  }

  /// Adopts the shared list, falling back to the shipped one when the document
  /// holds nothing usable — the desk must never be left with no button to press
  /// while a student is standing in front of it.
  void _adoptReasonList(List<LateArrivalReason> reasons) {
    final List<LateArrivalReason> usable = normalizeLateArrivalReasons(reasons);
    _reasons = usable.isEmpty ? defaultLateArrivalReasons : usable;
  }

  /// Follows the desk's drain, which is built (and rebuilt) after this screen
  /// exists — see [LateArrivalDesk].
  void _watchDrain(LateArrivalDrain? drain) {
    if (identical(drain, _watchedDrain)) return;
    unawaited(_drainSub?.cancel());
    _drainSub = null;
    _watchedDrain = drain;
    _drainStatus = drain?.status;
    if (drain == null) return;
    _drainSub = drain.statuses.listen((LateArrivalDrainStatus status) {
      if (mounted) setState(() => _drainStatus = status);
    });
  }

  /// Binds the printer standing at *this* desk. Machine-local (#406), so it
  /// comes out of `preferences.json` and not out of the shared document, and it
  /// is rebuilt when an operator changes the address in Instellingen.
  void _bindPrinter(String host) {
    if (_printerBound && _printerHost == host) return;
    _printerBound = true;
    _printerHost = host;
    _printer?.dispose();
    _printer = LateArrivalPrinter(
      host: host,
      logo: defaultTicketLogo,
      transport: widget.ticketTransport ?? const TcpTicketTransport(),
    );
  }

  // ---------------------------------------------------------------------------
  // Focus
  // ---------------------------------------------------------------------------

  void _onFocusChanged() {
    if (mounted) setState(() {});
    _reclaimFocus();
  }

  /// Takes the keyboard back on the next frame.
  ///
  /// Deferred rather than immediate because this runs from a focus notification
  /// and from [didChangeDependencies], neither of which may re-enter the focus
  /// manager mid-walk.
  void _reclaimFocus() {
    if (!mounted || !_visible || _scanner.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_visible || _scanner.hasFocus) return;
      _scanner.requestFocus();
    });
  }

  // ---------------------------------------------------------------------------
  // The scan
  // ---------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    final String? character = event.character;
    if (character == null || character.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (character == '\r' || character == '\n') {
      _submit();
      return KeyEventResult.handled;
    }
    // Anything else in the control range is scanner framing, not code.
    if (character.runes.first < 0x20) return KeyEventResult.ignored;
    _append(character);
    return KeyEventResult.handled;
  }

  void _append(String character) {
    final DateTime at = _now();
    final DateTime? last = _lastKeyAt;
    if (last == null || at.difference(last) > lateArrivalScanBurstGap) {
      _buffer = '';
    }
    _lastKeyAt = at;
    if (_buffer.length >= lateArrivalMaxScanLength) return;
    _buffer += character;
  }

  /// The scanner pressed Enter.
  void _submit() {
    final String raw = _buffer;
    _buffer = '';
    _lastKeyAt = null;

    final ScanResolver? resolver = _resolver;
    if (resolver == null) {
      setState(() => _refusal =
          'De leerlingenlijst is nog niet geladen, dus deze scan kon niet '
              'opgezocht worden. Registreer deze leerling voorlopig zelf in '
              'Smartschool.');
      return;
    }

    // Resolved *before* the guard below, deliberately: a stray Enter (scanner
    // noise, an empty burst) resolves to `ScanEmpty` and must stay silent rather
    // than beep at an operator who did nothing wrong.
    final ScanResult result = resolver.resolve(raw);
    if (result is ScanEmpty) return;

    if (_held is ScanRegisterable) {
      _beep.play();
      setState(() => _refusal =
          'Deze scan is geweigerd: er staat nog een leerling te wachten op een '
              'reden. Kies eerst een reden voor de leerling hieronder en laat de '
              'volgende leerling daarna opnieuw scannen.');
      return;
    }

    setState(() {
      _held = result;
      _heldAt = _now();
      _refusal = '';
      _registerError = '';
    });
  }

  /// Registers the student on screen with [reason], prints the ticket and frees
  /// the input.
  ///
  /// The order is the durability guarantee and is not an implementation detail:
  /// the journal line is flushed to disk before anything is printed, so a ticket
  /// can never exist for a registration that was not durably written.
  Future<void> _confirm(LateArrivalReason reason) async {
    final ScanResult? held = _held;
    if (held is! ScanRegisterable || _confirming) return;

    final LateArrivalJournal? journal = _desk?.journal;
    if (journal == null) {
      setState(() => _registerError =
          'De te-laatregistraties konden niet geopend worden op deze computer, '
              'dus er is niets bewaard. Registreer deze leerling zelf in '
              'Smartschool.');
      return;
    }

    setState(() {
      _confirming = true;
      _registerError = '';
    });
    try {
      final LateArrivalRecord record = await journal.register(
        scan: held,
        scannedAt: _heldAt ?? _now(),
        reasonLabel: reason.label,
        reasonIsValid: reason.isValid,
      );
      // Only now. See the doc above.
      _printer?.printRecord(record);
      if (!mounted) return;
      setState(() {
        _held = null;
        _heldAt = null;
        _confirming = false;
        _refusal = '';
        _drainStatus = _desk?.drain?.status;
      });
      _reclaimFocus();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _registerError =
            'De registratie kon niet bewaard worden ($e), dus er is niets '
            'geregistreerd en er is geen ticket afgedrukt. Registreer deze '
            'leerling zelf in Smartschool.';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _scanner,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        // A click anywhere on the page hands the keyboard straight back — the
        // cheapest recovery there is from "the operator clicked something".
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _reclaimFocus(),
        // Nothing below may take the focus: a reason button that stole it would
        // swallow the next scan, which is the failure this whole screen is built
        // to prevent. The buttons stay fully clickable.
        child: ExcludeFocus(
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(PlinkSpacing.s5),
              child: _body(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · te laat', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: Text('Te laat', style: text.headlineMedium)),
            _scannerIndicator(context),
          ],
        ),
        const SizedBox(height: PlinkSpacing.s2),
        Text(
          'Scan de kaart van de leerling. Naam en klas verschijnen meteen; kies '
          'daarna een reden. Pas dan is de leerling geregistreerd en komt het '
          'ticket uit de printer.',
          key: const ValueKey<String>('late-intro'),
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s5),
        _scanPanel(context),
        const SizedBox(height: PlinkSpacing.s5),
        Text('Reden', style: text.titleSmall),
        const SizedBox(height: PlinkSpacing.s3),
        LateArrivalReasonButtons(
          reasons: _reasons,
          onPick: (LateArrivalReason r) => unawaited(_confirm(r)),
          enabled: _held is ScanRegisterable && !_confirming,
        ),
        const SizedBox(height: PlinkSpacing.s6),
        const Divider(height: 1, thickness: 1),
        const SizedBox(height: PlinkSpacing.s4),
        _queuePanel(context),
        ..._notes(context),
      ],
    );
  }

  /// Whether a scan would currently land — the single most useful thing on the
  /// page when something is wrong.
  ///
  /// This says nothing about the hardware: a barcode scanner is a keyboard, and
  /// nothing here can see whether one is plugged in. What it does know is
  /// whether the hidden input holds the keyboard on the tab in view, which is
  /// exactly what decides if the next scan arrives — so the badge names that
  /// and only that (#413).
  Widget _scannerIndicator(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool active = _scanner.hasFocus && _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        PlinkBadge(
          active ? 'klaar om te scannen' : 'scannen gepauzeerd',
          key: const ValueKey<String>('late-scanner-indicator'),
          variant: active ? BadgeVariant.accent : BadgeVariant.outline,
          dot: true,
        ),
        if (!active) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s2),
          SizedBox(
            width: 260,
            child: Text(
              'Klik op dit scherm om verder te kunnen scannen.',
              key: const ValueKey<String>('late-scanner-hint'),
              textAlign: TextAlign.end,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  /// The one thing the operator looks at between two students.
  Widget _scanPanel(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey<String>('late-scan-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(PlinkSpacing.s5),
      decoration: BoxDecoration(
        border: Border.all(
          color: colors.outlineVariant,
          width: PlinkBorders.width,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_refusal.isNotEmpty) ...<Widget>[
            _alert(context, const ValueKey<String>('late-refusal'), _refusal),
            const SizedBox(height: PlinkSpacing.s4),
          ],
          if (_registerError.isNotEmpty) ...<Widget>[
            _alert(
              context,
              const ValueKey<String>('late-register-error'),
              _registerError,
            ),
            const SizedBox(height: PlinkSpacing.s4),
          ],
          ..._scanState(context, text, colors),
        ],
      ),
    );
  }

  List<Widget> _scanState(
    BuildContext context,
    TextTheme text,
    ColorScheme colors,
  ) {
    return switch (_held) {
      null => <Widget>[
          Text(
            'Klaar voor de volgende scan.',
            key: const ValueKey<String>('late-scan-idle'),
            style: text.headlineSmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      final ScanRegisterable hit => <Widget>[
          Text(
            hit.student.displayName,
            key: const ValueKey<String>('late-scan-name'),
            style: text.displaySmall,
          ),
          const SizedBox(height: PlinkSpacing.s2),
          Text(
            hit.student.className,
            key: const ValueKey<String>('late-scan-class'),
            style: text.headlineSmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: PlinkSpacing.s3),
          Text(
            'Kies hieronder een reden om deze leerling te registreren.',
            style: text.bodyMedium,
          ),
        ],
      final ScanIncomplete blocked => <Widget>[
          Text(
            blocked.student.displayName,
            key: const ValueKey<String>('late-scan-name'),
            style: text.displaySmall,
          ),
          const SizedBox(height: PlinkSpacing.s2),
          Text(
            blocked.student.className.isEmpty
                ? 'Geen klas'
                : blocked.student.className,
            key: const ValueKey<String>('late-scan-class'),
            style: text.headlineSmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: PlinkSpacing.s4),
          _alert(
            context,
            const ValueKey<String>('late-scan-incomplete'),
            'Deze leerling kan niet met de scanner geregistreerd worden: '
            '${_blockersInWords(blocked.blockers)} Registreer deze leerling in '
            'Smartschool en laat de gegevens nakijken.',
          ),
        ],
      ScanUnknown(:final String code) => <Widget>[
          Text(
            'Leerling onbekend',
            key: const ValueKey<String>('late-scan-unknown'),
            style: text.displaySmall,
          ),
          const SizedBox(height: PlinkSpacing.s2),
          Text(
            'Nummer $code hoort bij geen enkele leerling in het overzicht. Er '
            'is niets geregistreerd. Registreer deze leerling zelf in '
            'Smartschool.',
            style: text.bodyLarge,
          ),
        ],
      ScanAmbiguous(:final String code, :final List<String> smartschoolUids) =>
        <Widget>[
          Text(
            'Meerdere leerlingen',
            key: const ValueKey<String>('late-scan-ambiguous'),
            style: text.displaySmall,
          ),
          const SizedBox(height: PlinkSpacing.s2),
          Text(
            'Nummer $code staat bij meer dan één leerling '
            '(${smartschoolUids.join(', ')}), dus er is niets geregistreerd. '
            'Registreer deze leerling zelf in Smartschool en laat de '
            'internnummers nakijken.',
            style: text.bodyLarge,
          ),
        ],
      // `ScanEmpty` never reaches the screen — see [_submit].
      _ => const <Widget>[],
    };
  }

  /// The queue behind the desk: what is still owed to Smartschool, and what was
  /// given up on.
  Widget _queuePanel(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    final List<LateArrivalRecord> records =
        _desk?.journal?.records ?? const <LateArrivalRecord>[];
    final int outstanding =
        records.where((LateArrivalRecord r) => r.status.needsDraining).length;
    final List<LateArrivalRecord> failed = <LateArrivalRecord>[
      for (final LateArrivalRecord r in records)
        if (r.status == LateArrivalStatus.failed) r,
    ];
    final bool degraded = _drainStatus?.degraded ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Nog te versturen', style: text.titleSmall),
        const SizedBox(height: PlinkSpacing.s2),
        Row(
          children: <Widget>[
            PlinkBadge(
              '$outstanding in wachtrij',
              key: const ValueKey<String>('late-queue-outstanding'),
              variant:
                  outstanding == 0 ? BadgeVariant.outline : BadgeVariant.ink,
            ),
            if (failed.isNotEmpty) ...<Widget>[
              const SizedBox(width: PlinkSpacing.s2),
              PlinkBadge(
                '${failed.length} mislukt',
                key: const ValueKey<String>('late-queue-failed'),
                variant: BadgeVariant.accent,
              ),
            ],
          ],
        ),
        const SizedBox(height: PlinkSpacing.s2),
        Text(
          switch ((outstanding, failed.length, degraded)) {
            (0, 0, _) => 'Alles is naar Smartschool verstuurd.',
            (_, _, true) =>
              'Het versturen naar Smartschool is gestopt na een reeks fouten. '
                  'Niets is verloren — alles staat bewaard op deze computer.',
            (_, 0, _) => 'Deze registraties worden op de achtergrond naar '
                'Smartschool verstuurd.',
            _ => 'De mislukte registraties worden niet vanzelf opnieuw '
                'geprobeerd.',
          },
          key: const ValueKey<String>('late-queue-line'),
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        for (final LateArrivalRecord r in failed) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s2),
          Text(
            '${r.displayName}, ${r.className} — ${r.error ?? 'onbekende fout'}',
            key: ValueKey<String>('late-queue-failure-${r.id}'),
            style: text.bodySmall,
          ),
        ],
        if (degraded || failed.isNotEmpty) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          OutlinedButton.icon(
            key: const ValueKey<String>('late-queue-retry'),
            onPressed: _desk?.retryNow,
            icon: const Icon(Icons.refresh_outlined),
            label: const Text('Opnieuw proberen'),
          ),
        ],
      ],
    );
  }

  /// The things that are not wrong with *this* scan but are wrong with the desk:
  /// no student list, no printer, no drain. Each is a sentence rather than a
  /// silent degradation — a queue that is not moving is invisible until
  /// somebody's absence turns up in a report weeks later.
  List<Widget> _notes(BuildContext context) {
    final List<Widget> notes = <Widget>[];

    if (widget.bootstrap == null) {
      notes.add(_note(
        context,
        const ValueKey<String>('late-no-bootstrap'),
        'Deze installatie is nog niet met Azure AD verbonden, dus de '
        'leerlingenlijst kan niet geladen worden en er kan niet gescand '
        'worden. Vul de verbinding in bij Instellingen → Verbinding.',
      ));
    } else if (_error != null) {
      notes.add(_note(
        context,
        const ValueKey<String>('late-list-error'),
        'De leerlingenlijst kon niet geladen worden (${_error!}). Er kan '
        'voorlopig niet gescand worden.',
        onRetry: _busy ? null : () => unawaited(_bootstrap()),
      ));
    } else if (_busy) {
      notes.add(_note(
        context,
        const ValueKey<String>('late-list-loading'),
        'De leerlingenlijst wordt geladen…',
      ));
    } else if (_resolver == null) {
      notes.add(_note(
        context,
        const ValueKey<String>('late-list-missing'),
        'Er is nog geen Smartschool-overzicht op deze computer, dus een scan '
        'kan niet opgezocht worden. Haal het overzicht op bij '
        'Synchronisatie.',
        onRetry: _busy ? null : () => unawaited(_bootstrap()),
      ));
    }

    final LateArrivalPrinter? printer = _printer;
    if (printer != null) {
      notes.add(
        ValueListenableBuilder<LateArrivalPrintStatus>(
          valueListenable: printer.status,
          builder: (BuildContext context, LateArrivalPrintStatus status, _) =>
              status.message.isEmpty
                  ? const SizedBox.shrink()
                  : _note(
                      context,
                      const ValueKey<String>('late-printer-note'),
                      status.message,
                    ),
        ),
      );
    }

    for (final (int i, String warning)
        in (_desk?.warnings ?? const <String>[]).indexed) {
      notes.add(_note(context, ValueKey<String>('late-warning-$i'), warning));
    }

    if (notes.isEmpty) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: PlinkSpacing.s5),
      ...notes,
    ];
  }

  Widget _note(
    BuildContext context,
    Key key,
    String message, {
    VoidCallback? onRetry,
  }) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.info_outline,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            child: Text(
              message,
              key: key,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(width: PlinkSpacing.s3),
            TextButton(
              key: const ValueKey<String>('late-list-retry'),
              onPressed: onRetry,
              child: const Text('Opnieuw'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _alert(BuildContext context, Key key, String message) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(PlinkSpacing.s3),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_outlined, color: colors.onErrorContainer),
          const SizedBox(width: PlinkSpacing.s3),
          Expanded(
            child: Text(
              message,
              key: key,
              style: text.bodyLarge?.copyWith(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// The blockers on a [ScanIncomplete], as a sentence the operator can act on.
///
/// Named rather than counted: "twee problemen" sends somebody hunting, "deze
/// leerling zit in geen enkele officiële klas" is a repair.
String _blockersInWords(Set<ScanBlocker> blockers) {
  final List<String> parts = <String>[
    for (final ScanBlocker blocker in ScanBlocker.values)
      if (blockers.contains(blocker))
        switch (blocker) {
          ScanBlocker.noInternalUserId =>
            'het Smartschool-account heeft geen intern gebruikersnummer',
          ScanBlocker.noOfficialClass =>
            'deze leerling zit in geen enkele officiële klas',
          ScanBlocker.noClassGroupId =>
            'de klas van deze leerling is nog niet gekend in Smartschool',
        },
  ];
  return '${parts.join(', ')}.';
}
