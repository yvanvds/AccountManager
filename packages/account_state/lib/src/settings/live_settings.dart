import 'dart:async';

import 'app_settings.dart';
import 'work_date.dart';

/// A mutable holder for the operator's [AppSettings], shared between the
/// Settings view — which publishes the document it just loaded or saved — and
/// the reconcile stack, which reads it back at pull time.
///
/// ## Why this exists (#238)
///
/// `bootstrapReconcile` reads the settings document exactly once and is
/// memoized for the life of the process, while the Settings view writes through
/// its own separately-memoized store. So a saved werkdatum reached the WISA
/// connector only after a relaunch: the syncer had closed over an immutable
/// `AppSettings` captured at bootstrap. This is the same seam
/// `WisaImportRules` already provides for the `DontImportFromWisa` rules —
/// build it once, wire the readers to consult it *live*, and hand the same
/// instance to whoever writes it:
///
/// ```dart
/// final live = LiveSettings();                  // in main(), one per process
/// bootstrapReconcile(liveSettings: live, ...);  // reads it at pull time
/// bootstrapSettings(liveSettings: live);        // publishes on load/save
/// ```
///
/// [changes] lets a listener repaint on a save it did not make itself — the
/// reconcile screen keeps its widget alive across tab switches, so nothing else
/// would tell it the WISA pull inputs moved under it.
class LiveSettings {
  LiveSettings([AppSettings initial = const AppSettings()])
      : _current = initial;

  AppSettings _current;

  final StreamController<AppSettings> _changes =
      StreamController<AppSettings>.broadcast();

  /// The settings as last published. Read this at the moment a value is needed
  /// (pull time), never once at wiring time — that is the whole point.
  AppSettings get current => _current;

  /// Emits every published document, so a live view can react to a save made
  /// elsewhere in the app.
  Stream<AppSettings> get changes => _changes.stream;

  /// Adopts [next] as the current settings and notifies [changes].
  void publish(AppSettings next) {
    _current = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  /// Closes [changes]. Optional — the holder normally lives as long as the
  /// process does.
  Future<void> close() => _changes.close();
}

/// A stable identity for the settings a WISA pull depends on: the werkdatum
/// pair and the operator's virtual-school marks (#238).
///
/// Fingerprints the **settings**, not the resolved dates: `isNow: true`
/// resolves to a different instant on every pull and would make two identical
/// configurations compare unequal, which would leave "Check for drift"
/// permanently blocked. Two settings documents with the same fingerprint
/// therefore produce the same WISA query for the same instant.
String wisaPullFingerprint(AppSettings settings) {
  final virtualSchools = settings.virtualWisaSchoolIds.toList()..sort();
  return 'werkdatum=${_workDateKey(settings.wisa.workDate)};'
      'virtueleWerkdatum=${_workDateKey(settings.wisa.virtualWorkDate)};'
      'virtueleScholen=${virtualSchools.join(',')}';
}

String _workDateKey(WorkDateSetting setting) =>
    setting.isNow ? 'now' : (setting.date?.toIso8601String() ?? 'unset');

/// A stable identity for the settings a running session **cannot** adopt: the
/// endpoints and credential refs the three connectors were constructed from
/// (#246).
///
/// #246 made every *derived* settings value live — the managed-school set, the
/// school prefix, the Azure domain, the Smartschool class tree and import
/// rules — by routing each reader through [LiveSettings] at use time. The
/// connection profiles are the residue that cannot follow. A WISA host, port,
/// database or login is baked into a live SQL connection; a Smartschool site
/// into a SOAP endpoint; either password ref into a Key Vault secret the
/// bootstrap already resolved (an async read that cannot happen inside a
/// syncer). Re-reading them mid-session would mean tearing down and rebuilding
/// the connectors under whatever pass is in flight.
///
/// So they stay frozen, and the reconcile screen says so instead: a document
/// whose fingerprint has moved since bootstrap means the connectors in hand are
/// talking to the *previous* endpoints, which is exactly the silent-stale-input
/// failure #238 set out to end. Fingerprinting only the secret **ref** (never a
/// value) keeps this free of anything sensitive — rotating the secret behind an
/// unchanged ref is a Key Vault event this cannot and need not see.
String connectionFingerprint(AppSettings settings) {
  final wisa = settings.wisa;
  final smartschool = settings.smartschool;
  return 'wisa=${wisa.server.trim()}:${wisa.port.trim()}/'
      '${wisa.database.trim()}@${wisa.username.trim()}'
      '#${wisa.passwordRef.name};'
      'smartschool=${smartschool.uri.trim()}#${smartschool.passphraseRef.name}';
}
