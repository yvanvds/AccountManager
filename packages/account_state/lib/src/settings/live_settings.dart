import 'dart:async';
import 'dart:convert';

import 'app_settings.dart';
import 'import_rule_codec.dart';
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
/// pair, the operator's virtual-school marks (#238), and the persisted WISA
/// import rules (#263).
///
/// Fingerprints the **settings**, not the resolved dates: `isNow: true`
/// resolves to a different instant on every pull and would make two identical
/// configurations compare unequal, which would leave "Check for drift"
/// permanently blocked. Two settings documents with the same fingerprint
/// therefore produce the same WISA query for the same instant.
///
/// The import rules belong here for the same reason the werkdatum does: since
/// #263 the pull reads them from the live document, so a saved rule changes
/// what the roster contains — and a drift pass, which never re-pulls WISA,
/// would otherwise relink against the roster the rule never reached. Only the
/// *persisted* rules count; the ones a `DontImportFromWisa` apply accumulates
/// in the session's `WisaImportRules` holder trigger their own re-sync and are
/// not part of any settings document.
///
/// Order-sensitive, like [smartschoolPullFingerprint]: the connector applies
/// the rules in sequence.
String wisaPullFingerprint(AppSettings settings) {
  final virtualSchools = settings.virtualWisaSchoolIds.toList()..sort();
  return 'werkdatum=${_workDateKey(settings.wisa.workDate)};'
      'virtueleWerkdatum=${_workDateKey(settings.wisa.virtualWorkDate)};'
      'virtueleScholen=${virtualSchools.join(',')};'
      'regels=${jsonEncode(<Map<String, dynamic>>[
        for (final rule in settings.wisaRules) encodeWisaRule(rule),
      ])}';
}

String _workDateKey(WorkDateSetting setting) =>
    setting.isNow ? 'now' : (setting.date?.toIso8601String() ?? 'unset');

/// A stable identity for the settings a **Smartschool** pull depends on: the
/// operator's import rules (#259).
///
/// The counterpart of [wisaPullFingerprint] for the second connector. #99's
/// smart sync re-pulls Smartschool only when this session does not hold a
/// snapshot yet, so a `DiscardSmartschoolGroup` authored in Instellingen used
/// to be adopted by **Check for drift** and not by the Synchroniseer the
/// operator reaches for — which meanwhile reported "geen accountwijzigingen
/// nodig" over the save it had not applied. A moved fingerprint is what tells
/// the smart sync that leaving the held snapshot alone is no longer valid.
///
/// Order-sensitive on purpose: the rules are applied in sequence, so two
/// permutations of the same set are two different pulls.
String smartschoolPullFingerprint(AppSettings settings) =>
    'regels=${jsonEncode(<Map<String, dynamic>>[
          for (final rule in settings.smartschoolRules)
            encodeSmartschoolRule(rule),
        ])}';

/// A stable identity for the settings an **Azure** pull depends on: the school
/// prefix the whole read is scoped by, and the managed-school set the
/// transferred-account back-fill derives its expected `employeeId`s from
/// (#259).
///
/// Both are genuine inputs to the pull rather than to the link that follows it.
/// The prefix scopes the `/users` `$filter` and — since #246 — drops the delta
/// token when it moves, because `/users/delta` filters client-side and an
/// incremental pass would keep the previous school's users under the new
/// prefix. The managed-school set decides which WISA ids the `employeeId in (…)`
/// lookups (#224/#231) ask about, so a school flipped **beheerd** changes what
/// the pull can see even when Azure itself has not moved.
///
/// The ids are sorted, so a settings document that merely reorders its school
/// rows does not read as a changed pull.
String azurePullFingerprint(AppSettings settings) {
  final managed = settings.managedWisaSchoolIds.toList()..sort();
  return 'schoolPrefix=${settings.schoolPrefix.trim()};'
      'beheerdeScholen=${managed.join(',')}';
}

/// A stable identity for the settings only the **link** consumes — the ones no
/// pull asks anything about (#264).
///
/// The third fingerprint beside the three pull ones, and the reason it exists is
/// that [wisaPullFingerprint], [smartschoolPullFingerprint] and
/// [azurePullFingerprint] together do *not* cover everything a saved document
/// changes. `ApplierSettings` — sampled on every `link()` — carries two values
/// that reach no connector at all:
///
/// - the Azure domain, which every proposed UPN is built from
///   (`StudentActionConfig.azureDomain`, and the `student.<domain>` sub-domain
///   derived from it, plus `StaffActionConfig.azureDomain`);
/// - the Smartschool class tree — the year or grade group codes, whichever the
///   school uses, with the student-group root as the flat fallback — which
///   decides where a newly created class hangs.
///
/// Saving either used to be adopted by **Check for drift** and not by the
/// Synchroniseer the operator reaches for: that pass re-links unconditionally,
/// while a sync over an unchanged WISA returns before `_relink()`. A moved
/// fingerprint is what tells the smart sync to fall through to the link — and
/// only to the link, since nothing here needs the network.
///
/// The other two `ApplierSettings` inputs are deliberately absent: the school
/// prefix and the managed-school set are already in [azurePullFingerprint],
/// because they scope the Azure pull itself, so a save that moves either forces
/// a re-pull *and* the re-link behind it.
///
/// Order-sensitive on the year/grade codes — they are positional, one per school
/// year — and the flags are honoured exactly as `classTreeFrom` honours them, so
/// editing a year label while the school runs on grades is not a changed tree.
String linkFingerprint(AppSettings settings) {
  final smartschool = settings.smartschool;
  final years = smartschool.useYears ? smartschool.years : const <String>[];
  final grades = smartschool.useGrades ? smartschool.grades : const <String>[];
  // The student-group path is fingerprinted untrimmed on purpose: it goes into
  // the tree exactly as stored, so a trailing space really is a different
  // lookup. The domain is trimmed because bootstrap trims it before the
  // connector and the action configs ever see it.
  return 'azureDomein=${settings.azure.domain.trim()};'
      'jaren=${jsonEncode(years)};'
      'graden=${jsonEncode(grades)};'
      'pad=${jsonEncode(smartschool.studentGroup)}';
}

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
