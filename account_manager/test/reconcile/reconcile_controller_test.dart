import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/reconcile/log_buffer.dart';
import 'package:account_manager/src/reconcile/reconcile_controller.dart';
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:flutter_test/flutter_test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'reconcile_fakes.dart';

/// Collects every distinct [ApplyStep] [controller] publishes from now on — the
/// sequence the modal progress dialog renders as a pass walks its actions
/// (#243). A step is notified separately from the progress value, so listening
/// is the only way to see the ones a pass passed through.
List<ApplyStep> recordSteps(ReconcileController controller) {
  final steps = <ApplyStep>[];
  controller.addListener(() {
    final step = controller.applyStep;
    if (step != null && !identical(steps.lastOrNull, step)) steps.add(step);
  });
  return steps;
}

/// A [SignalPublisher] whose every publish throws — to prove a broadcast
/// failure is swallowed and never fails the pass that triggered it (#116).
class _ThrowingPublisher implements SignalPublisher {
  @override
  Future<void> publish(ChangeSignal signal) async =>
      throw StateError('signalr down');
}

/// An [InMemorySettingsStore] that counts its writes — so a test can prove the
/// sync-time school backfill (#207) writes only when it has something to fix.
class _RecordingSettingsStore extends InMemorySettingsStore {
  _RecordingSettingsStore(super.initial);

  int saves = 0;

  @override
  Future<void> save(AppSettings settings) {
    saves++;
    return super.save(settings);
  }
}

/// A settings store that hands back a document this session has never seen —
/// what a re-read looks like when another operator saved a werkdatum while this
/// pass was running (#276). Saves land normally on top of it.
class _MovedWerkdatumStore extends InMemorySettingsStore {
  _MovedWerkdatumStore(this.theirs) : super(const AppSettings());

  final AppSettings theirs;
  bool _handedOver = false;

  @override
  Future<AppSettings> load() async {
    if (_handedOver) return super.load();
    _handedOver = true;
    return theirs;
  }
}

/// A settings store whose every read throws — models the store being down while
/// a sync tries to repair the school profiles (#207).
class _ThrowingSettingsStore implements SettingsStore {
  const _ThrowingSettingsStore(this.error);

  final String error;

  @override
  Future<AppSettings> load() async => throw StateError(error);

  @override
  Future<void> save(AppSettings settings) async {}
}

void main() {
  group('first sync', () {
    test('pulls all three systems and derives the linked view + actions',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      expect(h.wisaSyncs, 1);
      expect(h.ssSyncs, 1);
      expect(h.azSyncs, 1);
      expect(h.controller.error, isNull);
      expect(h.controller.noChangesNeeded, isFalse);
      expect(h.controller.linked, isNotNull);
      // The fixture's one deterministic action: WISA says 3C, Smartschool 2B.
      expect(
        h.controller.linked!.studentActions
            .whereType<actions.MoveToSmartschoolClassGroup>(),
        hasLength(1),
      );
      expect(h.controller.pendingViews, isNotEmpty);
      expect(h.log.entries.where((e) => e.isError), isEmpty);
    });
  });

  group('smart WISA diff', () {
    test('an unchanged WISA re-sync reports "no changes needed" and stops',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      // Fresh pull, identical content (a new fetchedAt must not count).
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(h.wisaSyncs, 2, reason: 'WISA itself is re-pulled to diff');
      expect(h.ssSyncs, 1, reason: 'Smartschool is not re-read by default');
      expect(h.azSyncs, 1, reason: 'Azure is not re-read by default');
      expect(identical(h.controller.linked, linkedBefore), isTrue,
          reason: 'the existing linked view is kept, no re-link');
      expect(
        h.log.entries.map((e) => e.message),
        contains('WISA is ongewijzigd sinds de vorige synchronisatie — '
            'geen accountwijzigingen nodig.'),
      );
    });

    test('a changed WISA pull re-links without re-reading the other systems',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      h.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isFalse);
      expect(h.wisaSyncs, 2);
      expect(h.ssSyncs, 1);
      expect(h.azSyncs, 1);
      expect(identical(h.controller.linked, linkedBefore), isFalse,
          reason: 'a WISA change re-derives the linked view');
    });
  });

  group('aged Azure refresh (#320)', () {
    test('a pass that re-links refreshes an aged Azure snapshot incrementally',
        () async {
      // The seed a session opens on: last night's Azure from the cold store,
      // carrying the resume token that pass left behind.
      final h = ReconcileHarness(
        azureInitial: azSnap(
          fetchedAt: kFixtureDate.subtract(const Duration(hours: 12)),
          deltaToken: 'AZ-TOKEN',
        ),
      );

      await h.controller.sync();

      // Before #320 this pass left Azure alone entirely — the snapshot was not
      // null and no Azure setting had moved — so the stored token was minted by
      // every drift pass and spent by none.
      expect(h.azSyncs, 1);
      expect(h.azFullReads, 0,
          reason: 'the refresh is the cheap delta resume, never a re-read');
      expect(h.controller.error, isNull);
      // The pass says which kind of read the operator got, the way the drift
      // pass's "volledig opnieuw gelezen" line does (#316).
      expect(
        h.log.entries.map((e) => e.message),
        contains(allOf(
          startsWith('De Azure-gegevens dateren van '),
          endsWith('— Azure AD wordt incrementeel bijgewerkt.'),
        )),
      );
    });

    test('a fresh Azure snapshot is left alone, and says nothing about it',
        () async {
      final h = ReconcileHarness(azureInitial: azSnap(deltaToken: 'AZ-TOKEN'));

      await h.controller.sync();

      expect(h.azSyncs, 0, reason: 'the copy in hand is this minute old');
      expect(
        h.log.entries.map((e) => e.message),
        everyElement(isNot(contains('incrementeel bijgewerkt'))),
      );
    });

    test('an unchanged WISA re-sync still pulls nothing, however aged Azure is',
        () async {
      // The refresh window collapsed to nothing, so the age test is true on
      // every pass: the only thing that can keep Azure unpulled below is the
      // unchanged-WISA shortcut itself. It has to win — falling through it
      // would re-link and rewrite the whole materialized view for every other
      // operator merely because time passed.
      final h = ReconcileHarness(azureRefreshAge: Duration.zero);
      await h.controller.sync();
      expect(h.azSyncs, 1, reason: 'the first pass holds no snapshot at all');

      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(h.azSyncs, 1, reason: 'the shortcut returns before the refresh');
      expect(h.ssSyncs, 1);
    });
  });

  group('sync-complete log line (#162)', () {
    test('a completed sync logs a terminal ready line with the action count',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      // The count mirrors the relink summary's pendingActions.length (the
      // fixture derives six pending actions across the families — its two
      // Smartschool-only classes each carry the #313 either/or, which is two
      // actions and one decision), and the line names the operator who ran the
      // pass (#169).
      expect(
        h.log.entries.map((e) => e.message),
        contains('Sync voltooid — 6 openstaande actie(s). Klaar. '
            'Operator: operator@school.example.'),
      );
      // It is the *last* line — the operator sees it closing the pass.
      expect(
          h.log.entries.last.message,
          'Sync voltooid — 6 openstaande actie(s). Klaar. '
          'Operator: operator@school.example.');
    });

    test('an empty operator degrades gracefully — no dangling "by" (#169)',
        () async {
      final h = ReconcileHarness(syncedBy: '');

      await h.controller.sync();

      expect(h.log.entries.last.message,
          'Sync voltooid — 6 openstaande actie(s). Klaar.');
    });

    test('the "no changes needed" path also logs a ready line', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      // A later, identical WISA pull: the early-return no-change path.
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));

      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(
        h.log.entries.map((e) => e.message),
        contains('Sync voltooid — geen accountwijzigingen nodig. Klaar. '
            'Operator: operator@school.example.'),
      );
      expect(
          h.log.entries.last.message,
          'Sync voltooid — geen accountwijzigingen nodig. Klaar. '
          'Operator: operator@school.example.');
    });

    test('a drift check closes with a terminal line of its own (#303)',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      h.log.clear();

      await h.controller.checkDrift();

      // Until #303 a drift pass logged no closing line at all: it ended on
      // `_link`'s "Gekoppeld: …" summary, which reads exactly like a pass still
      // in flight. It gets the same line a sync gets — named for the pass that
      // actually ran, because a drift check is not a sync.
      expect(
          h.log.entries.last.message,
          'Driftcontrole voltooid — 6 openstaande actie(s). Klaar. '
          'Operator: operator@school.example.');
      expect(
        h.log.entries.where((e) => e.message.startsWith('Sync voltooid')),
        isEmpty,
        reason: 'the drift pass must not claim to have synced',
      );
    });

    test('an empty operator degrades gracefully on the drift line too (#303)',
        () async {
      final h = ReconcileHarness(syncedBy: '');
      await h.controller.sync();
      h.log.clear();

      await h.controller.checkDrift();

      expect(h.log.entries.last.message,
          'Driftcontrole voltooid — 6 openstaande actie(s). Klaar.');
    });
  });

  group('the pass reports itself in Dutch (#258)', () {
    // The Log panel is one running account of one pass, so it cannot change
    // language halfway through it: the terminal line #253 translated used to
    // land under a stack of English pull/link lines. Every step the operator
    // reads is pinned here, exactly as the panel renders it.
    test('a sync names each system it pulls and what it linked', () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      final messages = h.log.entries.map((e) => e.message).toList();
      expect(
        messages,
        containsAllInOrder(<String>[
          'WISA ophalen…',
          'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 0 klassen.',
          'Smartschool ophalen…',
          'Azure AD ophalen…',
        ]),
      );
      expect(messages, contains(startsWith('Gekoppeld: ')));
      // Not one line of the pass fell back to the English it used to log.
      expect(messages.where((m) => m.startsWith('Syncing ')), isEmpty);
      expect(messages.where((m) => m.startsWith('Linked: ')), isEmpty);
    });

    test('a drift check names both systems it re-reads', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      h.log.clear();

      await h.controller.checkDrift();

      expect(
        h.log.entries.map((e) => e.message),
        containsAllInOrder(<String>[
          'Smartschool controleren op drift…',
          'Azure AD controleren op drift…',
        ]),
      );
    });

    test('a dry-run keeps the "Dry-run" of the Acties buttons', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      h.log.clear();

      await h.controller.dryRunEntries(h.controller.pendingEntries);

      final messages = h.log.entries.map((e) => e.message).toList();
      expect(messages.first, startsWith('Dry-run gestart voor '));
      expect(messages.last, startsWith('Dry-run klaar: '));
      expect(messages.last, contains(' gelukt, '));
      expect(messages.last, endsWith(' mislukt.'));
    });

    test('an apply says "Toepassen", the verb those same buttons use',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      h.log.clear();

      await h.controller.applyEntries(h.controller.pendingEntries);

      final messages = h.log.entries.map((e) => e.message).toList();
      expect(messages.first, startsWith('Toepassen gestart voor '));
      expect(messages, contains(startsWith('Toepassen klaar: ')));
      expect(messages.where((m) => m.startsWith('Apply ')), isEmpty);
    });
  });

  group('persist resilience (#168)', () {
    test(
        'a stalled writeMaterialized times out, logs it, and returns the pass '
        'to ready so Synchronise re-enables', () async {
      final stalling = StallingLinkedStore();
      final h = ReconcileHarness(
        controllerStore: stalling,
        persistTimeout: const Duration(milliseconds: 50),
      );

      await h.controller.sync();

      // The persist step was reached but hung — the controller did not wait
      // forever: it timed out and finished the pass.
      expect(stalling.writeAttempted, isTrue);
      expect(h.controller.busy, isFalse,
          reason: 'a stalled persist must not leave the pass wedged');
      expect(h.controller.phase, ReconcilePhase.ready);
      // The operator sees the timeout, not silence.
      expect(
        h.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(contains(
          'Het opslaan van het gedeelde overzicht duurde langer dan',
        )),
      );
      // The in-memory linked view is still usable this session.
      expect(h.controller.linked, isNotNull);
    });

    test(
        'a failing writeMaterialized is caught, logged, and the pass still '
        'reaches ready', () async {
      final failing = StallingLinkedStore(
        failWith: StateError('cosmos down'),
      );
      final h = ReconcileHarness(controllerStore: failing);

      await h.controller.sync();

      expect(h.controller.busy, isFalse);
      expect(h.controller.phase, ReconcilePhase.ready);
      expect(
        h.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(contains('Kon het gedeelde overzicht niet opslaan')),
      );
      expect(h.controller.linked, isNotNull);
    });

    test(
        'a failing writeMaterialized still drops the drill-down caches, so the '
        'open class cannot pair the previous generation with the fresh view '
        '(#289)', () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();

      // Session 1 materializes generation 1, so there are stored documents for
      // the next session to drill into.
      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      // Session 2 reads that view and the Klasgroepen inventory — and its own
      // writes fail.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
        controllerStore: StallingLinkedStore(
          inner: linkedStore,
          failWith: StateError('cosmos down'),
        ),
      );
      await s2.controller.loadOverview();
      await s2.controller.loadGroups();
      expect(s2.controller.groupDocs, isNotEmpty);

      await s2.controller.sync();

      // The write really did fail…
      expect(
        s2.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(contains('Kon het gedeelde overzicht niet opslaan')),
      );
      // …and the session still holds the view it just linked.
      expect(s2.controller.linked, isNotNull);
      // The cache derived from the *previous* generation went with the re-link,
      // whether or not the shared write landed. (The Acties list has no such
      // cache since #295: it renders off the linked view itself.)
      expect(s2.controller.groupDocs, isNull);
    });

    test(
        'a stalled writeMaterialized during a drift check drops them too '
        '(#289)', () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();

      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
        controllerStore: StallingLinkedStore(inner: linkedStore),
        persistTimeout: const Duration(milliseconds: 50),
      );
      await s2.controller.loadOverview();
      await s2.controller.loadGroups();
      expect(s2.controller.groupDocs, isNotEmpty);

      await s2.controller.checkDrift();

      expect(
        s2.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(contains(
          'Het opslaan van het gedeelde overzicht duurde langer dan',
        )),
      );
      expect(s2.controller.groupDocs, isNull);
    });
  });

  group('check for drift', () {
    test('re-reads Smartschool and Azure and re-links', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      await h.controller.checkDrift();

      expect(h.ssSyncs, 2);
      expect(h.azSyncs, 2);
      expect(h.wisaSyncs, 1, reason: 'drift check does not re-pull WISA');
      expect(h.controller.linked, isNotNull);
    });
  });

  group('settings school-profile backfill (#207)', () {
    // The reported settings document: entries written before a profile had a
    // `code`/`name` at all (#171/#194), so the Settings grid — the one view
    // that consults no snapshot — rendered "School 25" until the operator
    // pressed Scholen ophalen *and* Opslaan. Every sync already pulls the whole
    // school list, so it repairs them.
    const legacy = AppSettings(
      wisaSchools: <WisaSchoolProfile>[
        WisaSchoolProfile(schoolId: 25, ours: true),
        WisaSchoolProfile(schoolId: 27, virtual: true),
      ],
    );
    const pulled = <wapi.WisaSchool>[
      wapi.WisaSchool(id: 25, name: 'Instituut Sancta Maria-A', code: 'ISMAA'),
      wapi.WisaSchool(id: 27, name: 'Instituut Sancta Maria-B', code: 'ISMAB'),
    ];

    test('a sync fills the pulled names and codes into the stored profiles',
        () async {
      final settings = InMemorySettingsStore(legacy);
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
      );

      await h.controller.sync();

      final saved = await settings.load();
      expect(
        saved.wisaSchools.map((p) => p.name),
        ['Instituut Sancta Maria-A', 'Instituut Sancta Maria-B'],
      );
      expect(saved.wisaSchools.map((p) => p.code), ['ISMAA', 'ISMAB']);
      expect(saved.wisaSchools.first.ours, isTrue,
          reason: 'the managed mark is the operator\'s, never rewritten');
      expect(saved.wisaSchools.last.virtual, isTrue);
      expect(h.log.entries.where((e) => e.isError), isEmpty);
      // And the repair says so in the operator's own language (#258).
      expect(
        h.log.entries.map((e) => e.message),
        contains('Naam en code van 2 WISA-school(en) bijgewerkt in de '
            'instellingen (id 25, 27).'),
      );
    });

    test('the unchanged-WISA shortcut still repairs the document', () async {
      // The repair runs before the smart-diff early return, so an operator
      // whose group has nothing to reconcile still gets named schools.
      final settings = InMemorySettingsStore(legacy);
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
      );
      await h.controller.sync();
      // Model the pre-fix document coming back (another operator saved over it)
      // and re-sync with identical WISA content.
      await settings.save(legacy);

      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      final saved = await settings.load();
      expect(saved.wisaSchools.first.name, 'Instituut Sancta Maria-A');
    });

    test('nothing is written when every profile is already named', () async {
      final settings = _RecordingSettingsStore(const AppSettings(
        wisaSchools: <WisaSchoolProfile>[
          WisaSchoolProfile(
            schoolId: 25,
            code: 'ISMAA',
            name: 'Instituut Sancta Maria-A',
            ours: true,
          ),
        ],
      ));
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
      );

      await h.controller.sync();

      expect(settings.saves, 0,
          reason: 'a sync must not rewrite the settings document for nothing');
    });

    test('a drift check that pulls WISA repairs the document too (#303)',
        () async {
      // The repair follows the *pull*, not the pass. `checkDrift` normally
      // re-reads only Smartschool and Azure — but a session holding no roster
      // yet pulls WISA first, and that branch has exactly the authority a sync
      // has, so it heals the profiles with it instead of leaving the operator's
      // grid saying "School 25" until they happen to press Synchroniseer.
      final settings = InMemorySettingsStore(legacy);
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
        schoolProfiles: legacy.wisaSchools,
      );

      await h.controller.checkDrift();

      expect(h.wisaSyncs, 1,
          reason: 'no roster in hand, so the drift pass pulls one');
      final saved = await settings.load();
      expect(
        saved.wisaSchools.map((p) => p.name),
        ['Instituut Sancta Maria-A', 'Instituut Sancta Maria-B'],
      );
      expect(saved.wisaSchools.map((p) => p.code), ['ISMAA', 'ISMAB']);
      expect(saved.wisaSchools.first.ours, isTrue);
      expect(saved.wisaSchools.last.virtual, isTrue);
      expect(h.log.entries.where((e) => e.isError), isEmpty);
    });

    test(
        'a drift check over the roster in hand leaves the document alone '
        '(#303)', () async {
      // The deliberate other half of that decision. The merge writes WISA's
      // name over the stored one, so a snapshot somebody else pulled hours ago
      // must not get to overwrite a rename a fresher sync already recorded — and
      // an ordinary drift pass never re-reads WISA, so it has nothing newer to
      // say about the school list than the document already holds.
      final settings = _RecordingSettingsStore(legacy);
      final h = ReconcileHarness(
        wisaInitial: wisaSnap(schools: pulled),
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
        schoolProfiles: legacy.wisaSchools,
      );

      await h.controller.checkDrift();

      expect(h.wisaSyncs, 0,
          reason: 'the roster in hand is the one a drift pass links against');
      expect(settings.saves, 0);
      expect((await settings.load()).wisaSchools.first.name, isEmpty);
    });

    test('a failing settings store is logged, never fails the sync', () async {
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: const _ThrowingSettingsStore('cosmos 503'),
      );

      await h.controller.sync();

      expect(h.controller.error, isNull);
      expect(h.controller.linked, isNotNull);
      expect(
        h.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(
          'Kon de WISA-schoolnamen niet bijwerken in de instellingen: '
          'Bad state: cosmos 503',
        ),
      );
    });
  });

  group('a DontImportFromWisa apply persists its rule (#276)', () {
    // Two freshly hired teachers exist in WISA only, so each raises the #248
    // either/or: provision them, or stop importing them. Picking the opt-out is
    // what earns a `DontImportUserFromWisa` rule — and, until #276, that rule
    // lived only in the process-lifetime `WisaImportRules` holder, so the next
    // launch rebuilt it empty, WISA still reported the person active, and the
    // account the operator had meanwhile deleted (#269) was proposed anew.
    ReconcileHarness ignoreStaffHarness({
      SettingsStore? settingsStore,
      LiveSettings? liveSettings,
    }) =>
        ReconcileHarness(
          wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
          smartschool: ssSnap(
            groups: const [],
            accounts: const [],
            memberships: const [],
          ),
          azure: azSnap(users: const []),
          settingsStore: settingsStore,
          liveSettings: liveSettings,
        );

    /// Syncs, switches the staff either/or to the opt-out the way the screen
    /// does, and applies that one row.
    Future<void> ignoreTheStaffMember(ReconcileHarness h) async {
      final entry =
          h.controller.pendingEntries.firstWhere((e) => e.family == 'staff');
      h.controller.chooseAlternative(
        entry: entry,
        group: actions.staffImportAlternative,
        kind: 'DontImportStaffFromWisa',
      );
      // Re-read after the choice: the entry list is rebuilt.
      final chosen = h.controller.pendingEntries
          .firstWhere((e) => e.targetId == entry.targetId);
      await h.controller.applyEntry(chosen);
    }

    test('writes the earned rule to the shared settings document', () async {
      final settings = InMemorySettingsStore(const AppSettings());
      final live = LiveSettings(const AppSettings());
      final h = ignoreStaffHarness(settingsStore: settings, liveSettings: live);
      await h.controller.sync();

      await ignoreTheStaffMember(h);

      final saved = await settings.load();
      expect(saved.wisaRules.single, isA<wapi.DontImportUserFromWisa>());
      expect(
        (saved.wisaRules.single as wapi.DontImportUserFromWisa).userCode,
        'SMIT',
      );
      // …and it is published, so this session's next pull unions it in without
      // a reload (#263) and Instellingen shows what the store holds (#273).
      expect(live.current.wisaRules, hasLength(1));
      expect(h.controller.error, isNull);
    });

    test('tells the operator the exclusion is permanent and shared', () async {
      // A rule every operator inherits, for as long as nobody removes it, must
      // not land silently — the log is where the operator finds out what the
      // click actually committed them to.
      final settings = InMemorySettingsStore(const AppSettings());
      final h = ignoreStaffHarness(
        settingsStore: settings,
        liveSettings: LiveSettings(const AppSettings()),
      );
      await h.controller.sync();

      await ignoreTheStaffMember(h);

      expect(
        h.log.entries.map((e) => e.message),
        contains('Importregel bewaard voor iedereen: Gebruiker niet importeren '
            'uit WISA: SMIT. Dit blijft gelden tot de regel in Instellingen → '
            'Wisa verwijderd wordt.'),
      );
    });

    test('applying the same rule twice does not grow the persisted list',
        () async {
      // `WisaImportRules`' de-dup has to hold across the persist path too, or a
      // September of re-applies would append the same rule until the settings
      // document itself became the problem.
      final settings = _RecordingSettingsStore(const AppSettings());
      final h = ignoreStaffHarness(
        settingsStore: settings,
        liveSettings: LiveSettings(const AppSettings()),
      );
      await h.controller.sync();

      await ignoreTheStaffMember(h);
      await ignoreTheStaffMember(h);

      expect((await settings.load()).wisaRules, hasLength(1));
      expect(settings.saves, 1,
          reason: 'the second apply had nothing new to write');
    });

    test('a dry run writes nothing', () async {
      // A dry run projects the rule without earning it; a shared, permanent
      // change must never come out of a preview.
      final settings = _RecordingSettingsStore(const AppSettings());
      final h = ignoreStaffHarness(
        settingsStore: settings,
        liveSettings: LiveSettings(const AppSettings()),
      );
      await h.controller.sync();
      final entry =
          h.controller.pendingEntries.firstWhere((e) => e.family == 'staff');
      h.controller.chooseAlternative(
        entry: entry,
        group: actions.staffImportAlternative,
        kind: 'DontImportStaffFromWisa',
      );

      await h.controller.dryRunEntry(h.controller.pendingEntries
          .firstWhere((e) => e.targetId == entry.targetId));

      expect(settings.saves, 0);
      expect((await settings.load()).wisaRules, isEmpty);
    });

    test('a failing settings store is logged, never fails the pass', () async {
      // The apply pass itself succeeded and its results are on screen; losing
      // them to a wedged Cosmos would be the worse failure.
      final h = ignoreStaffHarness(
        settingsStore: const _ThrowingSettingsStore('cosmos 503'),
        liveSettings: LiveSettings(const AppSettings()),
      );
      await h.controller.sync();

      await ignoreTheStaffMember(h);

      expect(h.controller.error, isNull);
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.applied),
      );
      expect(
        h.log.entries.where((e) => e.isError).map((e) => e.message),
        contains('Kon de WISA-importregel(s) niet opslaan in de instellingen: '
            'Bad state: cosmos 503'),
      );
    });

    test('does not arm the drift gate it just satisfied (#238)', () async {
      // `wisaPullFingerprint` covers the persisted rules, so this write would
      // otherwise block **Controleer op drift** with "synchroniseer eerst" —
      // over a rule the applier had already re-pulled WISA with.
      final settings = InMemorySettingsStore(const AppSettings());
      final live = LiveSettings(const AppSettings());
      final h = ignoreStaffHarness(settingsStore: settings, liveSettings: live);
      await h.controller.sync();
      expect(h.controller.canCheckDrift, isTrue);

      await ignoreTheStaffMember(h);

      expect(h.controller.driftBlockedReason, isNull);
      expect(h.controller.canCheckDrift, isTrue);
    });

    test('still arms it for a change another operator slipped in', () async {
      // The re-credit is narrow on purpose: it claims only *these rules*. A
      // werkdatum this session's snapshot was never pulled with comes back on
      // the re-read and must keep blocking drift.
      final live = LiveSettings(const AppSettings());
      final h = ignoreStaffHarness(
        settingsStore: _MovedWerkdatumStore(
          AppSettings(
            wisa: WisaConnection(
              workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9)),
            ),
          ),
        ),
        liveSettings: live,
      );
      await h.controller.sync();
      expect(h.controller.canCheckDrift, isTrue);

      await ignoreTheStaffMember(h);

      expect(live.current.wisaRules, hasLength(1),
          reason: 'the rule still landed on the document that came back');
      expect(
        h.controller.driftBlockedReason,
        'WISA-instellingen gewijzigd — synchroniseer eerst.',
      );
    });

    group('the persisted rule records who, when, and for whom (#285)', () {
      test('stamps the operator, the instant, and the subject\'s name',
          () async {
        // A `DontImportUserFromWisa` stores nothing but `SMIT`, and the staff
        // these rules are about are precisely the ones who later disappear from
        // WISA — so the name has to be captured here, at the decision, or it is
        // gone. The operator is the load-bearing half: with no reason field on
        // the record, it is the pointer to the person who remembers.
        final settings = InMemorySettingsStore(const AppSettings());
        final h = ignoreStaffHarness(
          settingsStore: settings,
          liveSettings: LiveSettings(const AppSettings()),
        );
        await h.controller.sync();

        await ignoreTheStaffMember(h);

        final saved = await settings.load();
        final provenance =
            saved.provenanceOf(const wapi.DontImportUserFromWisa('SMIT'))!;
        expect(provenance.subject, 'Anna Smit');
        expect(provenance.addedBy, 'operator@school.example');
        // The pass's own clock, sampled once for the whole pass.
        expect(provenance.addedAt, kFixtureDate);
      });

      test('re-applying keeps the first operator\'s stamp', () async {
        // Two operators can reach the same conclusion; the union puts persisted
        // rules first (#263), so the collapse keeps the decision the document
        // has been standing on — and its author with it.
        final settings = InMemorySettingsStore(AppSettings(
          wisaRules: const <wapi.WisaImportRule>[
            wapi.DontImportUserFromWisa('SMIT'),
          ],
          wisaRuleProvenance: <String, RuleProvenance>{
            'user:SMIT': RuleProvenance(
              subject: 'Anna Smit',
              addedBy: 'ann@school.example',
              addedAt: DateTime.utc(2026, 1, 15, 9),
            ),
          },
        ));
        final h = ignoreStaffHarness(
          settingsStore: settings,
          liveSettings: LiveSettings(const AppSettings()),
        );
        await h.controller.sync();

        await ignoreTheStaffMember(h);

        final provenance = (await settings.load())
            .provenanceOf(const wapi.DontImportUserFromWisa('SMIT'))!;
        expect(provenance.addedBy, 'ann@school.example');
        expect(provenance.addedAt, DateTime.utc(2026, 1, 15, 9));
      });

      test('an unsigned-in session still records when, and for whom', () async {
        // #98's sign-in is what supplies the operator; a session without one
        // must not lose the other two fields — "onbekend" for the author is the
        // honest degradation, a lost date is a real loss.
        final settings = InMemorySettingsStore(const AppSettings());
        final h = ReconcileHarness(
          wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
          smartschool: ssSnap(
            groups: const [],
            accounts: const [],
            memberships: const [],
          ),
          azure: azSnap(users: const []),
          settingsStore: settings,
          liveSettings: LiveSettings(const AppSettings()),
          syncedBy: '',
        );
        await h.controller.sync();

        await ignoreTheStaffMember(h);

        final provenance = (await settings.load())
            .provenanceOf(const wapi.DontImportUserFromWisa('SMIT'))!;
        expect(provenance.addedBy, isEmpty);
        expect(provenance.subject, 'Anna Smit');
        expect(provenance.addedAt, isNotNull);
      });
    });
  });

  group('cross-session snapshot persistence (#107)', () {
    test('a first sync persists all three snapshots to the store', () async {
      final store = InMemorySnapshotStore();
      final h = ReconcileHarness(store: store);

      await h.controller.sync();

      expect(
        store.storedSystems,
        containsAll([
          core.Origin.wisa,
          core.Origin.smartschool,
          core.Origin.azure,
        ]),
      );
      expect(
          store.peek(core.Origin.azure)!.syncedBy, 'operator@school.example');
    });

    test('a fresh session seeded from the store reuses Smartschool + Azure',
        () async {
      final store = InMemorySnapshotStore();
      // Session 1 pulls and persists everything.
      await ReconcileHarness(store: store).controller.sync();

      // Session 2: a fresh controller over the same store.
      final resumed = await ReconcileHarness.resume(store: store);
      await resumed.controller.sync();

      // WISA is still pulled (the smart diff needs a fresh WISA read), but the
      // Smartschool and Azure snapshots are trusted from the store — no pull.
      expect(resumed.wisaSyncs, 1);
      expect(resumed.ssSyncs, 0,
          reason: 'Smartschool is seeded from the store, not re-pulled');
      expect(resumed.azSyncs, 0,
          reason: 'Azure is seeded from the store, not re-pulled');
      expect(resumed.controller.linked, isNotNull,
          reason: 'the linked view is derived from the seeded snapshots');
      expect(resumed.log.entries.where((e) => e.isError), isEmpty);
    });

    test('check-for-drift re-pulls and replaces the stored copies', () async {
      final store = InMemorySnapshotStore();
      await ReconcileHarness(store: store).controller.sync();
      expect(store.peek(core.Origin.smartschool)!.fetchedAt, kFixtureDate);

      final resumed = await ReconcileHarness.resume(store: store);
      // The drift pull returns snapshots stamped later than the stored copies.
      final driftAt = kFixtureDate.add(const Duration(hours: 3));
      resumed.ssResult = ssSnap(fetchedAt: driftAt);
      resumed.azResult = azSnap(fetchedAt: driftAt);

      await resumed.controller.checkDrift();

      // A drift check re-reads Smartschool + Azure from the connectors…
      expect(resumed.ssSyncs, 1);
      expect(resumed.azSyncs, 1);
      // …and replaces the stored snapshots with the fresh pulls.
      expect(store.peek(core.Origin.smartschool)!.fetchedAt, driftAt);
      expect(store.peek(core.Origin.azure)!.fetchedAt, driftAt);
    });

    test('the Azure delta token survives across sessions', () async {
      final store = InMemorySnapshotStore();
      final s1 = ReconcileHarness(
        store: store,
        azure: az.AzureSnapshot(
          fetchedAt: kFixtureDate,
          deltaToken: 'DELTA-42',
          users: [azUser()],
          groups: const [],
        ),
      );
      await s1.controller.sync();

      // The seeded Azure snapshot carries the delta token forward, priming the
      // next incremental /users/delta.
      final resumed = await ReconcileHarness.resume(store: store);
      expect(resumed.app.azure.snapshot?.deltaToken, 'DELTA-42');
    });
  });

  group('failures', () {
    test('a failing WISA sync surfaces the error and keeps the old view',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      h.wisaError = StateError('WISA host unreachable');
      await h.controller.sync();

      expect(h.controller.error, contains('WISA host unreachable'));
      expect(h.controller.busy, isFalse);
      expect(identical(h.controller.linked, linkedBefore), isTrue);
      expect(h.log.hasErrors, isTrue);
    });
  });

  group('dry-run', () {
    test('walks every applyable action with zero writes', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      await h.controller.dryRunEntries(h.controller.pendingEntries);

      final results = h.controller.dryRunResults;
      expect(results, isNotNull);
      expect(results, isNotEmpty);
      expect(
        results!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.dryRun),
      );
      expect(
        results.map((r) => r.changes.summary),
        contains('Wijzig de klas in Smartschool'),
      );
      expect(h.soap.soapActions, isEmpty, reason: 'a dry run writes nothing');
      expect(h.graph.requests, isEmpty, reason: 'a dry run writes nothing');
      expect(h.controller.applyResults, isNull);
    });
  });

  group('apply', () {
    test('writes the pending actions and refreshes the linked view', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      await h.controller.applyEntries(h.controller.pendingEntries);

      final results = h.controller.applyResults;
      expect(results, isNotNull);
      expect(
        results!
            .where((r) => r.changes.summary == 'Wijzig de klas in Smartschool')
            .single
            .outcome,
        actions.ActionOutcome.applied,
      );
      expect(h.soap.soapActions, isNotEmpty,
          reason: 'the class move is a real Smartschool write');
      expect(identical(h.controller.linked, linkedBefore), isFalse,
          reason: 'a real write re-links from the patched snapshot');
    });

    /// Every node of the overview tree keyed by its rollup key, with the count
    /// the badge renders — the whole projection #236 is about, in one map.
    Map<String, int> pendingByNode(ReconcileController c) => <String, int>{
          for (final root in c.studentRollups) ...<String, int>{
            root.key: root.pendingCount,
            for (final klas in c.studentChildrenOf(root))
              klas.key: klas.pendingCount,
          },
          if (c.groupRollup case final groups?) groups.key: groups.pendingCount,
        };

    /// The classroom node whose badge the fixture's one student action sits
    /// under: Sam's class, 3C of school 1.
    Rollup klas3C(ReconcileController c) => c
        .studentChildrenOf(
            c.studentRollups.singleWhere((r) => r.gradeYear == '3'))
        .singleWhere((r) => r.classroom == '3C');

    /// Sam's pending entry — the one applyable student action in the fixture.
    PendingAccountEntry samEntry(ReconcileController c) =>
        c.pendingEntries.singleWhere((e) => e.family == 'student');

    test('re-derives the counts the pass just changed, and only those (#236)',
        () async {
      // The badges read `Rollup.pendingCount` off `_rollups`, which only
      // [_persist] assigned — and that runs from `_relink()` alone. So an apply
      // left the drilled-in list (live, derived from `_linked`) and the overview
      // disagreeing until the next Synchroniseer.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      expect(klas3C(h.controller).pendingCount, 1);
      expect(h.controller.groupRollup!.pendingCount, 4);

      await h.controller.applyEntry(samEntry(h.controller));

      expect(h.controller.error, isNull);
      expect(klas3C(h.controller).pendingCount, 0,
          reason: 'the badge used to keep its pre-apply count until a re-sync');
      expect(
        h.controller.studentRollups
            .singleWhere((r) => r.gradeYear == '3')
            .pendingCount,
        0,
        reason: 'the grade-year above it is summed from the same rollups',
      );
      expect(h.controller.groupRollup!.pendingCount, 4,
          reason: 'a re-derivation of what changed, not a blanket reset');
    });

    test('a dry-run leaves every count exactly as it found it (#236)',
        () async {
      // The correction is gated on a *real* write: a projection changes nothing,
      // so it must not move a single badge.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final before = pendingByNode(h.controller);
      expect(before.values, contains(greaterThan(0)));

      await h.controller.dryRunEntries(h.controller.pendingEntries);

      expect(pendingByNode(h.controller), before);
      expect(h.soap.soapActions, isEmpty, reason: 'nothing was written');
      expect(h.graph.requests, isEmpty, reason: 'nothing was written');
    });

    test(
        'a pass with a refused write clears only what really went through '
        '(#236)', () async {
      // The counts must follow the writes, not the pass: the first action is
      // refused, the rest land. Sam's class keeps its badge while the class
      // groups lose theirs.
      var calls = 0;
      final h = appliedClassWorkHarness(applyGate: () async {
        if (++calls == 1) throw StateError('Office 365 weigerde dit');
      });
      await h.controller.sync();
      expect(klas3C(h.controller).pendingCount, 1);

      await h.controller.applyEntries(h.controller.pendingEntries);

      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        containsAll(<actions.ActionOutcome>[
          actions.ActionOutcome.failed,
          actions.ActionOutcome.applied,
        ]),
      );
      expect(klas3C(h.controller).pendingCount, 1,
          reason: "the refused write left Sam's name as it was");
      // The node itself stays: since #227 it aggregates the class *inventory*,
      // so the classes are still there — with nothing left to do on them.
      expect(h.controller.groupRollup!.pendingCount, 0,
          reason: 'the class-group work that did land is gone');
      expect(h.controller.groupRollup!.accountCount, greaterThan(0),
          reason: 'the classes themselves did not disappear with their work');
    });

    /// The stored counterpart of [klas3C]: 3C's node as the *shared* view holds
    /// it, which is what every other operator reads.
    Future<Rollup?> stored3C(ReconcileHarness h) async {
      for (final r in await h.linkedStore.readRollups()) {
        if (r.classroom == '3C' && r.school == '1') return r;
      }
      return null;
    }

    test(
        'the applied work leaves the shared store too, not just this session '
        '(#254)', () async {
      // #236 fixed the local half and deliberately stopped there: rewriting
      // ~9.6k documents per apply was not affordable and there was no narrower
      // seam. `writeApplied` is that seam, so the stored counts now move with
      // the session's — and every other operator stops being offered work that
      // has already been applied.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      expect((await stored3C(h))!.pendingCount, 1);
      final before = await h.linkedStore.readSyncState();

      await h.controller.applyEntry(samEntry(h.controller));

      expect(h.controller.error, isNull);
      expect((await stored3C(h))!.pendingCount, 0,
          reason:
              'the stored view used to stay pre-apply until someone synced');
      expect((await h.linkedStore.readSyncState()).generation,
          before.generation + 1);
      expect(h.controller.syncState.generation, before.generation + 1,
          reason: 'a session that wrote the view is current, not ahead of it');
      expect(klas3C(h.controller).pendingCount, 0);
    });

    test('the stored account document drops the applied candidate (#254)',
        () async {
      // The badge is a sum over documents, so the document has to move with it —
      // a passive session reads the per-account docs, not just the rollups.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final entry = samEntry(h.controller);
      final before =
          await h.linkedStore.readClassroom(school: '1', classroom: '3C');
      expect(
        before.singleWhere((a) => a.id.value == entry.targetId).candidates,
        isNotEmpty,
      );

      await h.controller.applyEntry(entry);

      final after =
          await h.linkedStore.readClassroom(school: '1', classroom: '3C');
      expect(
        after.singleWhere((a) => a.id.value == entry.targetId).candidates,
        isEmpty,
      );
      expect(after, hasLength(before.length),
          reason: 'the class still holds everyone it held');
    });

    test('the write-back is scoped to what the pass touched (#254)', () async {
      // A one-row apply must not republish this session's whole picture of the
      // view: everything it did not write to is left exactly as the last sync
      // put it — including the class-group half, which since #227 is a document
      // per class rather than per class with work.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final groupsBefore = await h.linkedStore.readGroups();

      await h.controller.applyEntry(samEntry(h.controller));

      final klasgroepen = (await h.linkedStore.readRollups())
          .singleWhere((r) => r.level == RollupLevel.groups);
      expect(klasgroepen.pendingCount, 4,
          reason: 'a re-derivation of what changed, not a blanket reset');
      expect(await h.linkedStore.readGroups(), hasLength(groupsBefore.length));
      final threeD =
          await h.linkedStore.readClassroom(school: '1', classroom: '3D');
      expect(threeD, hasLength(1), reason: 'the untouched class is intact');
    });

    test('a dry-run writes nothing to the shared store either (#254)',
        () async {
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final before = await h.linkedStore.readSyncState();

      await h.controller.dryRunEntries(h.controller.pendingEntries);

      expect(
          (await h.linkedStore.readSyncState()).generation, before.generation);
      expect((await stored3C(h))!.pendingCount, 1);
    });

    test('an apply stands down while another operator is syncing (#254)',
        () async {
      // The apply path does not take the sync lease — it is frequent and
      // concurrent by design (#108/#121). So the write-back has to notice one:
      // that pass is republishing the whole view from a fresher link, and a
      // narrow patch bumping the generation past it would be exactly the local
      // correction outranking the shared view this must not create.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final before = await h.linkedStore.readSyncState();
      await h.linkedStore
          .acquireLease(owner: 'mieke@school', now: kFixtureDate);

      await h.controller.applyEntry(samEntry(h.controller));

      expect(h.controller.error, isNull,
          reason: 'the writes to Smartschool and Office 365 really happened');
      expect(
          (await h.linkedStore.readSyncState()).generation, before.generation);
      expect(h.controller.syncState.generation, before.generation,
          reason: 'never ahead of the store');
      expect((await stored3C(h))!.pendingCount, 1);
      expect(klas3C(h.controller).pendingCount, 0,
          reason: "#236's local correction still stands for this session");
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('mieke@school')),
      );
    });

    test('a failing write-back is logged and never fails the pass (#254)',
        () async {
      final failing = StallingLinkedStore(failWith: StateError('cosmos down'));
      final h = ReconcileHarness(controllerStore: failing);
      await h.controller.sync();

      await h.controller.applyEntries(h.controller.pendingEntries);

      expect(failing.appliedWriteAttempted, isTrue);
      expect(h.controller.phase, ReconcilePhase.ready);
      expect(h.controller.error, isNull,
          reason: 'the connector writes succeeded; only the share failed');
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('gedeelde overzicht')),
      );
    });

    test(
        'a stalled write-back times out and the pass still reaches ready '
        '(#254)', () async {
      final stalling = StallingLinkedStore();
      final h = ReconcileHarness(
        controllerStore: stalling,
        persistTimeout: const Duration(milliseconds: 50),
      );
      await h.controller.sync();

      await h.controller.applyEntries(h.controller.pendingEntries);

      expect(stalling.appliedWriteAttempted, isTrue);
      expect(h.controller.phase, ReconcilePhase.ready);
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('gedeelde overzicht')),
      );
    });

    test(
        'an operator decision on a touched account survives the write-back '
        '(#254)', () async {
      // The derived documents are replaced wholesale, so a decision the store
      // holds for exactly the account a pass touched would be silently stripped
      // if the patch did not re-attach it — the very clobber decisions live in
      // their own documents to avoid.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final entry = samEntry(h.controller);
      final decision = AccountDecision(
        accountId: core.LinkedAccountId(entry.targetId),
        kind: DecisionKind.acceptedDuplicate,
        targetKind: 'duplicate-mail',
        decidedBy: 'mieke@school',
        decidedAt: kFixtureDate,
      );
      await h.linkedStore.putDecision(decision);

      await h.controller.applyEntry(entry);

      expect(await h.linkedStore.readDecisions(), hasLength(1),
          reason: 'the decision document itself is never touched here');
    });

    test('informational group actions are listed but never applied', () async {
      // An orphan Smartschool class (no WISA counterpart) surfaces the
      // informational DoNotImportFromSmartschool — visible in the pending
      // list, skipped by the apply pass (its apply() throws by contract).
      final h = ReconcileHarness(
        smartschool: ssSnap(
          groups: [
            ssGroup('2B', code: '2B_ss'),
            ssGroup('3C', code: '3C_ss'),
            ssGroup('9Z', code: '9Z_ss'),
          ],
        ),
      );
      await h.controller.sync();

      final informational = h.controller.pendingViews.where((v) => !v.canApply);
      expect(informational, isNotEmpty);
      expect(h.controller.applyableCount,
          lessThan(h.controller.pendingActions.length));

      await h.controller.applyEntries(h.controller.pendingEntries);

      expect(h.controller.error, isNull);
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        isNot(contains(actions.ActionOutcome.failed)),
      );
    });
  });

  group('provisioning a WISA-only student (#230)', () {
    /// A new intake: one student in a managed school with neither a Smartschool
    /// nor an Office 365 account, and the Smartschool class they belong to.
    ReconcileHarness newIntakeHarness() => ReconcileHarness(
          wisa: wisaSnap(
            students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
            schools: [wisaSchool(1)],
          ),
          smartschool: ssSnap(
            groups: [ssGroup('3C', code: '3C_ss')],
            accounts: const [],
            memberships: const [],
          ),
          azure: azSnap(users: const []),
          ourSchoolIds: const {1},
        );

    /// The student's own pending entry (the Smartschool class the fixture
    /// carries has no WISA counterpart, so it raises a group entry of its own).
    PendingAccountEntry studentEntry(ReconcileController controller) =>
        controller.pendingEntries.singleWhere((e) => e.family == 'student');

    test('is offered exactly one applyable entry', () async {
      final h = newIntakeHarness();
      await h.controller.sync();

      final entry = studentEntry(h.controller);
      expect(entry.canApply, isTrue);
      expect(entry.choices.single.selected.kind, 'AddStudentToAzure');
    });

    test('applying it provisions both accounts and reports both writes',
        () async {
      final h = newIntakeHarness();
      await h.controller.sync();

      await h.controller.applyEntry(studentEntry(h.controller));

      expect(h.controller.error, isNull);
      expect(
        h.controller.applyResults!.map((r) => r.changes.summary),
        <String>[
          'Maak een nieuw Office 365 account',
          'Maak een nieuw Smartschool account',
        ],
        reason: 'one click, the whole provisioning chain',
      );
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.applied),
      );
      // Both writes really happened, and the linked view carries both records.
      expect(h.graph.createdUsers.single['employeeId'], 'W7');
      expect(h.soap.soapActions.any((a) => a.contains('saveUser')), isTrue);
      final linked = h.controller.linked!.snapshot.accounts.single;
      expect(linked.azure, isNotNull);
      expect(linked.smartschool, isNotNull);
    });

    test('the chained write is logged like any other', () async {
      final h = newIntakeHarness();
      await h.controller.sync();

      await h.controller.applyEntry(studentEntry(h.controller));

      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('Maak een nieuw Smartschool account')),
      );
    });

    test('a dry run projects only the write it can actually describe',
        () async {
      // The chain rides the incremental refresh, which a dry run does not
      // perform — so it stays a projection of the one write, with no Graph POST
      // and no Smartschool call behind it.
      final h = newIntakeHarness();
      await h.controller.sync();

      await h.controller.dryRunEntry(studentEntry(h.controller));

      expect(
        h.controller.dryRunResults!.map((r) => r.changes.summary),
        <String>['Maak een nieuw Office 365 account'],
      );
      expect(h.graph.createdUsers, isEmpty);
      expect(h.soap.soapActions, isEmpty);
    });

    test(
        'the published step counts planned actions and reports the chained '
        'write apart from them (#243)', () async {
      // The progress dialog's total can only ever be the *planned* actions:
      // dispatch is a pure function of the record as it stands, so the
      // Smartschool create does not exist until the Azure create has landed and
      // relinked. Folding it into the total would mean promising a number
      // nobody could know — so it is reported as a follow-up instead.
      final h = newIntakeHarness();
      await h.controller.sync();

      final steps = recordSteps(h.controller);
      await h.controller.applyEntries(h.controller.pendingEntries);

      expect(steps.map((s) => s.total).toSet(), <int>{steps.length},
          reason: 'the planned total never moves mid-pass');
      expect(
          steps.map((s) => s.index), List.generate(steps.length, (i) => i + 1));
      expect(steps.first.summary, 'Maak een nieuw Office 365 account');
      expect(steps.first.followUps, 0);
      expect(steps.first.dry, isFalse);
      // The Azure create pulled the Smartschool create in behind it, so the
      // pass performed one write more than it planned actions.
      expect(h.controller.applyResults!.length, steps.length + 1);
      expect(steps.skip(1).map((s) => s.followUps), everyElement(1));
      // Nothing is in flight once the pass is over.
      expect(h.controller.applyStep, isNull);
    });
  });

  group('the pass publishes the step it is on (#243)', () {
    test('a dry-run names each action before it runs, and clears at the end',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      final steps = recordSteps(h.controller);
      await h.controller.dryRunEntries(h.controller.pendingEntries);

      expect(steps, isNotEmpty);
      expect(steps.map((s) => s.dry), everyElement(isTrue));
      expect(steps.map((s) => s.target), everyElement(isNotEmpty));
      expect(steps.map((s) => s.summary), everyElement(isNotEmpty));
      expect(steps.last.index, steps.last.total);
      expect(h.controller.applyStep, isNull);
    });

    test('a sync publishes no step — it walks no actions', () async {
      final h = ReconcileHarness();
      final steps = recordSteps(h.controller);
      await h.controller.sync();

      expect(steps, isEmpty);
      expect(h.controller.applyStep, isNull);
    });
  });

  group('managed-school filter visibility (#230)', () {
    test('a sync says how many students the filter dropped', () async {
      // School 2 is not in the managed set, and its student owns no account of
      // ours — so they are (correctly, #178) kept out of the Actions view. That
      // used to happen with no node, no count and no log line, which is exactly
      // how a school the operator forgot to flag in Instellingen reads.
      final h = ReconcileHarness(
        wisa: wisaSnap(
          students: [
            wisaStudent(wisaId: '1'),
            wisaStudent(wisaId: '2', schoolId: 2),
          ],
          schools: [wisaSchool(1), wisaSchool(2)],
        ),
        smartschool: ssSnap(
          groups: const [],
          accounts: const [],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
        ourSchoolIds: const {1},
      );

      await h.controller.sync();

      expect(
        h.log.entries.map((e) => e.message),
        contains('1 leerling(en) overgeslagen: '
            'niet in een school die we beheren.'),
      );
    });

    test('a sync with nothing dropped stays quiet', () async {
      final h = ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(wisaId: '1')],
          schools: [wisaSchool(1)],
        ),
        smartschool: ssSnap(
          groups: const [],
          accounts: const [],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
        ourSchoolIds: const {1},
      );

      await h.controller.sync();

      expect(
        h.log.entries.map((e) => e.message),
        isNot(contains(contains('overgeslagen'))),
      );
    });
  });

  group('busy-pass progress (#176)', () {
    /// Records [ReconcileController.progress] on every notification, so a test
    /// can assert the pass stepped the bar forward through its stages even
    /// though the whole pass resolves within a single microtask flush.
    List<double> recordProgress(ReconcileController controller) {
      final seen = <double>[];
      controller.addListener(() => seen.add(controller.progress));
      return seen;
    }

    void expectMonotonic(List<double> values) {
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThanOrEqualTo(values[i - 1]),
            reason: 'progress must never move backwards: $values');
      }
    }

    test('a sync steps the bar forward through every stage', () async {
      final h = ReconcileHarness();
      final seen = recordProgress(h.controller);

      await h.controller.sync();

      expect(seen, isNotEmpty);
      expect(seen.first, 0.0, reason: 'a pass resets the bar to the start');
      expectMonotonic(seen);
      // The bar visited intermediate stages (systems pulled, linking,
      // persisting) rather than jumping straight to done — the "advances"
      // the issue asks for.
      expect(seen.where((v) => v > 0.0 && v < 1.0).length,
          greaterThanOrEqualTo(3));
      // …and it *finishes*: the bar used to stop on the 0.9 `_relink` set
      // before persisting and be cleared from there (#303).
      expect(h.controller.progress, 1.0);
    });

    test('an unchanged re-sync still advances past the start', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));

      final seen = recordProgress(h.controller);
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(seen.first, 0.0);
      expectMonotonic(seen);
      expect(seen.any((v) => v > 0.0), isTrue,
          reason: 'even the short no-changes path moves the bar off zero');
      // The short path is a finished pass too, so it completes the bar as well
      // — it used to stop on the 0.25 the WISA pull left it at (#303).
      expect(h.controller.progress, 1.0);
    });

    test('a drift check steps the bar forward through its stages', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      final seen = recordProgress(h.controller);
      await h.controller.checkDrift();

      expect(seen.first, 0.0);
      expectMonotonic(seen);
      expect(seen.where((v) => v > 0.0 && v < 1.0), isNotEmpty);
      expect(h.controller.progress, 1.0, reason: 'and reaches the end (#303)');
    });

    test('an apply advances once per action, reaching 1.0', () async {
      final h = manyDepartedHarness(count: 4);
      await h.controller.sync();
      expect(h.controller.applyableCount, 4);

      final seen = recordProgress(h.controller);
      await h.controller.applyEntries(h.controller.pendingEntries);

      expect(seen.first, 0.0);
      expectMonotonic(seen);
      // One step per applied action: 0.25, 0.5, 0.75, 1.0.
      expect(seen, containsAllInOrder(<double>[0.25, 0.5, 0.75, 1.0]));
      expect(h.controller.progress, 1.0);
    });
  });

  group('materialized view (#115)', () {
    test('a sync writes per-account docs + rollups + bumps the generation',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      final state = await h.linkedStore.readSyncState();
      expect(state.generation, 1, reason: 'first sync bumps 0 → 1');
      expect(state.updatedBy, 'operator@school.example');

      expect(h.linkedStore.accountCount, 1);
      final rollups = await h.linkedStore.readRollups();
      final classroom =
          rollups.singleWhere((r) => r.level == RollupLevel.classroom);
      expect(classroom.accountCount, 1);
      expect(classroom.classroom, '3C');

      expect(h.controller.hasOverview, isTrue);
      expect(h.controller.syncState.generation, 1);
    });

    test(
        'school rollups are labelled from the persisted Settings profiles, '
        'not the school id (#204)', () async {
      // The regression: the label map was built solely from the WISA snapshot's
      // schools, so a session whose snapshot carries none (a cold seed written
      // before schools were serialized) baked `School 25` into every document.
      final h = namedSchoolHarness();

      await h.controller.sync();

      final rollups = await h.linkedStore.readRollups();
      final school = rollups.singleWhere((r) => r.level == RollupLevel.school);
      expect(school.label, 'Instituut Sancta Maria-A (ISMAA)');
      expect(school.label, isNot('School 25'));

      // The same label is baked into the per-account documents the drill-down
      // reads back, so a passive session sees it too.
      final accounts = await h.linkedStore.readClassroom(
        school: school.school,
        classroom: '3C',
      );
      expect(accounts.single.schoolLabel, 'Instituut Sancta Maria-A (ISMAA)');
    });

    test('a live WISA pull labels schools it carries itself (#204)', () async {
      // No Settings profile at all: the pulled school list still names the
      // school by its own two halves rather than by its id.
      final h = ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(schoolId: 25)],
          schools: const [
            wapi.WisaSchool(
              id: 25,
              name: 'Instituut Sancta Maria-A',
              code: 'ISMAA',
            ),
          ],
        ),
      );

      await h.controller.sync();

      final rollups = await h.linkedStore.readRollups();
      final school = rollups.singleWhere((r) => r.level == RollupLevel.school);
      expect(school.label, 'Instituut Sancta Maria-A (ISMAA)');
    });

    test('re-sync bumps the generation again', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      // A changed WISA pull forces a re-link + re-materialize.
      h.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      expect((await h.linkedStore.readSyncState()).generation, 2);
    });

    test('a persisted decision survives a re-sync whose situation still exists',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      // Stand in for what #110's UI will write: a decision on the pending move.
      final accountId = h.controller.linked!.studentActions.first.target.id;
      await h.linkedStore.putDecision(AccountDecision(
        accountId: accountId,
        kind: DecisionKind.chosenAlternative,
        targetKind: 'MoveToSmartschoolClassGroup',
        decidedBy: 'operator@school.example',
        decidedAt: kFixtureDate,
      ));

      // Re-sync (WISA changed but the move situation persists).
      h.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      final decisions = await h.linkedStore.readDecisions();
      expect(decisions, hasLength(1),
          reason: 'the move is still due, so the decision is kept');
      final classroom =
          await h.linkedStore.readClassroom(school: '1', classroom: '3D');
      expect(classroom.single.decisions, hasLength(1),
          reason: 'the surviving decision is re-attached to the account doc');
    });
  });

  group('category overview summaries (#163)', () {
    void expectSummary(CategorySummary s,
        {required int total, required int pending}) {
      expect(s.total, total);
      expect(s.pending, pending);
    }

    test('are empty before any sync', () {
      final h = ReconcileHarness();
      expectSummary(h.controller.studentSummary, total: 0, pending: 0);
      expectSummary(h.controller.staffSummary, total: 0, pending: 0);
      expectSummary(h.controller.groupSummary, total: 0, pending: 0);
    });

    test('sum the rollups per category after a sync', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      // One fixture student (School 1); the rollup pendingCount sums her
      // applyable candidate actions (as the Actions drill-down badges do).
      expectSummary(h.controller.studentSummary, total: 1, pending: 2);
      // No staff in the fixture ⇒ the staff bucket is absent.
      expectSummary(h.controller.staffSummary, total: 0, pending: 0);
      // Two Smartschool-only classes (2B, 3C) are informational group notices,
      // so they count toward the total but carry no applyable pending action.
      expectSummary(h.controller.groupSummary, total: 2, pending: 0);
    });

    test('departed students sum across the unassigned bucket, not staff',
        () async {
      // Three WISA-departed, Smartschool-only accounts, all in the synthetic
      // "unassigned" school — never the staff bucket. Each raises the
      // unregister/delete pair, which is one either/or the operator resolves
      // once — so the rollup pendingCount is 3, not the 3 × 2 it counted before
      // #251 (an apply pass writes one resolution per student, never both).
      final h = manyDepartedHarness(count: 3);
      await h.controller.sync();

      expectSummary(h.controller.studentSummary, total: 3, pending: 3);
      expect(h.controller.applyableCount, 3,
          reason: 'the badge and the live list agree on what is pending');
      expectSummary(h.controller.staffSummary, total: 0, pending: 0);
    });

    test('a passive session derives the summaries from the stored rollups',
        () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
          .controller
          .sync();

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      expect(s2.controller.linked, isNull);
      expectSummary(s2.controller.studentSummary, total: 1, pending: 2);
      expectSummary(s2.controller.groupSummary, total: 2, pending: 0);
    });
  });

  group('school-less student drill-down (#210)', () {
    test(
        'the top level is the grade-years merged across every managed school, '
        'with combined counts and no school node', () async {
      final h = twoSchoolHarness();
      await h.controller.sync();

      // School 1 holds 1A + 3C, school 2 holds 1B + OKAN. The overview merges
      // the years: one "Jaar 1" spanning both schools' first years.
      expect(
        h.controller.studentRollups.map((r) => r.label),
        <String>['Jaar 1', 'Jaar 3', 'Overige klassen'],
        reason: 'ordering is pinned: years ascending, then the non-numeric one',
      );
      final jaar1 = h.controller.studentRollups.first;
      expect(jaar1.accountCount, 2, reason: "school 1's 1A plus school 2's 1B");
      expect(jaar1.pendingCount, greaterThan(0));

      // The school level is gone from the view — and never had a node label of
      // its own to fall back on.
      expect(
        h.controller.studentRollups.map((r) => r.level),
        everyElement(isNot(RollupLevel.school)),
      );
      expect(h.controller.studentRollups.map((r) => r.label),
          isNot(contains('School 1')));

      // …but the stored rollups keep it, so the aggregates that count by
      // RollupLevel.school (the badges, the category summaries) still have data.
      expect(h.controller.schoolRollups.map((r) => r.label),
          containsAll(<String>['School 1', 'School 2']));
      expect(h.controller.studentSummary.total, 4);
    });

    test(
        'a merged year lists both schools\' classrooms, each keeping its own '
        'partition', () async {
      final h = twoSchoolHarness();
      await h.controller.sync();

      final jaar1 =
          h.controller.studentRollups.firstWhere((r) => r.label == 'Jaar 1');
      final classes = h.controller.studentChildrenOf(jaar1);
      expect(classes.map((r) => r.label), <String>['1A', '1B']);
      // The partition key of each class is its real school — what
      // `readClassroom(partitionKey: school)` targets. Acties stopped reading
      // classroom partitions in #295, but the store still holds them that way
      // and the counts are still summed per school.
      expect(classes.map((r) => r.school), <String>['1', '2']);
      expect(
        await h.linkedStore.readClassroom(school: '2', classroom: '1B'),
        hasLength(1),
      );
    });

    test('a non-numeric class group is never labelled "Jaar Overig"', () async {
      final h = twoSchoolHarness();
      await h.controller.sync();

      final other = h.controller.studentRollups.last;
      expect(other.label, 'Overige klassen');
      expect(other.gradeYear, 'Overig');
      expect(
        h.controller.studentChildrenOf(other).map((r) => r.label),
        <String>['OKAN'],
      );
    });

    test('"Niet toegewezen" expands straight to its classrooms', () async {
      // Three WISA-departed accounts: all land in the unassigned bucket, whose
      // grade level is always the synthetic "Overig" and carries no decision.
      final h = manyDepartedHarness(count: 3);
      await h.controller.sync();

      final roots = h.controller.studentRollups;
      expect(roots.map((r) => r.label), <String>['Niet toegewezen'],
          reason: 'no year node for a bucket that has no real year');
      final children = h.controller.studentChildrenOf(roots.single);
      expect(children.map((r) => r.label), <String>['Zonder klas']);
      expect(children.single.level, RollupLevel.classroom,
          reason: 'the always-empty grade level is skipped');
      expect(children.single.accountCount, 3);
    });

    test(
        'a passive session projects the same tree from the stored view, with '
        'its badges and header count untouched', () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      final s1 = twoSchoolHarness();
      // Materialize through a first session, then read it back passively.
      final active = ReconcileHarness(
        store: snapshots,
        linkedStore: linkedStore,
        wisa: s1.wisaResult,
        smartschool: s1.ssResult,
        azure: s1.azResult,
        ourSchoolIds: const {1, 2},
      );
      await active.controller.sync();

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      expect(s2.controller.linked, isNull, reason: 'passive: never linked');
      expect(
        s2.controller.studentRollups.map((r) => r.label),
        active.controller.studentRollups.map((r) => r.label),
      );
      expect(
        s2.controller.studentRollups.map((r) => r.accountCount),
        active.controller.studentRollups.map((r) => r.accountCount),
      );
      // The counters read from RollupLevel.school rollups, which the view
      // projection deliberately left in the store.
      expect(
          s2.controller.totalPendingCount, active.controller.totalPendingCount);
      expect(s2.controller.studentPendingCount,
          active.controller.studentPendingCount);
      expect(
          s2.controller.staffPendingCount, active.controller.staffPendingCount);
      expect(s2.controller.totalPendingCount, greaterThan(0));
    });
  });

  group('materialized group actions (#119)', () {
    test('a sync materializes group docs + a group rollup', () async {
      // The fixture's two Smartschool-only classes (2B, 3C) raise the
      // informational orphan notice — the group family.
      final h = ReconcileHarness();

      await h.controller.sync();

      expect(h.linkedStore.groupCount, greaterThan(0));
      final groups = await h.linkedStore.readGroups();
      expect(groups.map((g) => g.label), containsAll(['2B', '3C']));
      expect(h.controller.groupRollup, isNotNull);
      expect(h.controller.groupRollup!.accountCount, groups.length);
    });

    test('a passive session reads the class inventory with no pull or link()',
        () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();

      // Session 1 syncs and materializes the shared view.
      await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
          .controller
          .sync();

      // Session 2: a fresh, passive controller over the same stores.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      expect(s2.controller.groupRollup, isNotNull,
          reason: 'the group rollup came from the shared store');
      expect(s2.controller.groupDocs, isNull,
          reason: 'the inventory is read when the Klasgroepen tab asks for it');

      await s2.controller.loadGroups();

      expect(s2.controller.groupDocs, isNotEmpty);
      // No connector pull and no linked view derived this session.
      expect(s2.wisaSyncs, 0);
      expect(s2.ssSyncs, 0);
      expect(s2.azSyncs, 0);
      expect(s2.controller.linked, isNull);
    });

    test('a sync drops the cached inventory so the tab re-reads it (#227)',
        () async {
      final h = ReconcileHarness();
      // The tab is open before anything has been materialized: an empty
      // inventory, read from an empty store.
      await h.controller.loadGroups();
      expect(h.controller.groupDocs, isEmpty);

      await h.controller.sync();

      expect(h.controller.groupDocs, isNull,
          reason: 'the pre-sync inventory must not linger on screen');
      await h.controller.loadGroups();
      expect(h.controller.groupDocs, isNotEmpty);
    });

    test(
        'the two attention counts are one derivation each, so the pointer one '
        'action screen carries matches the list it points at (#301)', () async {
      // `3C` and `3D` are both missing their Office 365 group; of the two
      // students only Sam's Office 365 display name is stale.
      final h = appliedClassWorkHarness();
      await h.controller.sync();

      // Nothing to count until the inventory has been read: a count the store
      // was never asked for is not a count.
      expect(h.controller.groupDocs, isNull);
      expect(h.controller.classesNeedingAttention, 0);

      await h.controller.loadGroups();
      expect(h.controller.classesNeedingAttention, 2);

      // Accounts, not actions. The view holds three pending cards — Sam plus
      // the two classes — so neither the total nor the class half is the
      // number the Klasgroepen pointer wants.
      expect(h.controller.totalPendingCount, 3);
      expect(h.controller.accountsNeedingAttention, 1);
      expect(h.controller.groupPendingEntries, hasLength(2));
    });

    test(
        'an informational candidate is class work, so it counts on Klasgroepen '
        'and not against the accounts (#301)', () async {
      // `2F` has no Office 365 group, which leaves each of its students with an
      // `AzureClassGroupMembership` diagnosis of work that is done per class on
      // the other tab. It must not turn them into accounts that need attention.
      final h = azureClassGroupHarness();
      await h.controller.sync();
      await h.controller.loadGroups();

      expect(h.controller.classesNeedingAttention, greaterThan(0));
      expect(h.controller.accountsNeedingAttention, 0);
    });
  });

  group('passive session reads the store (#115)', () {
    test(
        'a resumed session renders the overview and drills into a classroom '
        'without any pull or link()', () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();

      // Session 1 syncs and materializes the shared view.
      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      // Session 2: a fresh controller over the same stores, passive.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      // No connector pull and no linked view derived this session.
      expect(s2.wisaSyncs, 0);
      expect(s2.ssSyncs, 0);
      expect(s2.azSyncs, 0);
      expect(s2.controller.linked, isNull, reason: 'link() was never called');

      // The overview came from the store.
      expect(s2.controller.hasOverview, isTrue);
      expect(s2.controller.syncState.generation, 1);
      final classroom = s2.controller.schoolRollups
          .expand((s) => s2.controller.childrenOf(s.key))
          .expand((g) => s2.controller.childrenOf(g.key))
          .single;
      expect(classroom.accountCount, 1);

      // Still no pull.
      expect(s2.wisaSyncs, 0);
      expect(s2.ssSyncs, 0);
      expect(s2.azSyncs, 0);
    });
  });

  group('multi-operator coordination (#108)', () {
    test('a sync records per-system freshness (who/when) in the shared store',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      final systems = (await h.linkedStore.readSyncState()).systems;
      expect(
          systems.keys,
          containsAll(<core.Origin>[
            core.Origin.wisa,
            core.Origin.smartschool,
            core.Origin.azure,
          ]));
      expect(systems[core.Origin.wisa]?.syncedBy, 'operator@school.example');
      expect(systems[core.Origin.wisa]?.at, kFixtureDate);
      // …and the controller mirrors it for the header.
      expect(h.controller.syncState.systems[core.Origin.azure]?.syncedBy,
          'operator@school.example');
    });

    test('the "WISA unchanged" path still stamps WISA freshness', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      // A later, identical WISA pull: no re-link, but WISA was still read.
      final later = kFixtureDate.add(const Duration(hours: 1));
      h.wisaResult = wisaSnap(fetchedAt: later);

      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      final systems = (await h.linkedStore.readSyncState()).systems;
      expect(systems[core.Origin.wisa]?.at, later,
          reason: 'WISA freshness advances even with no view change');
      expect((await h.linkedStore.readSyncState()).generation, 1,
          reason: 'an unchanged sync does not bump the generation');
    });

    test(
        'a later WISA-only smart-sync keeps the Smartschool/Azure freshness '
        '(#170)', () async {
      final store = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: store);
      // First full sync: all three systems are pulled and stamped at the
      // fixture time.
      await h.controller.sync();
      final first = (await store.readSyncState()).systems;
      expect(
        first.keys,
        containsAll(<core.Origin>[
          core.Origin.wisa,
          core.Origin.smartschool,
          core.Origin.azure,
        ]),
        reason: 'the first full sync records every system',
      );

      // A later smart-sync where only WISA changed: Smartschool and Azure are
      // not re-pulled (their in-session snapshots are present).
      final later = kFixtureDate.add(const Duration(hours: 1));
      h.wisaResult = wisaSnap(
        fetchedAt: later,
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      expect(h.ssSyncs, 1,
          reason: 'Smartschool is not re-pulled by smart-sync');
      expect(h.azSyncs, 1, reason: 'Azure is not re-pulled by smart-sync');

      // The store must still carry all three — WISA advanced, the drift-checked
      // pair keeps its earlier stamp rather than being overwritten.
      final stored = (await store.readSyncState()).systems;
      expect(stored[core.Origin.wisa]?.at, later);
      expect(stored[core.Origin.smartschool]?.at, kFixtureDate);
      expect(stored[core.Origin.azure]?.at, kFixtureDate);
      // …and the operator stamp from the earlier pull survives too (#169).
      expect(
          stored[core.Origin.smartschool]?.syncedBy, 'operator@school.example');
      expect(stored[core.Origin.azure]?.syncedBy, 'operator@school.example');

      // The controller mirrors the merged store for the header line.
      final live = h.controller.syncState.systems;
      expect(
        live.keys,
        containsAll(<core.Origin>[
          core.Origin.wisa,
          core.Origin.smartschool,
          core.Origin.azure,
        ]),
      );
      expect(live[core.Origin.wisa]?.at, later);
      expect(live[core.Origin.smartschool]?.at, kFixtureDate);
      expect(live[core.Origin.azure]?.at, kFixtureDate);
    });

    test('a Check for drift stamps Smartschool and Azure freshness (#170)',
        () async {
      final store = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: store);
      await h.controller.sync();

      // Drift check re-pulls Smartschool and Azure at a later time.
      final later = kFixtureDate.add(const Duration(hours: 2));
      h.ssResult = ssSnap(fetchedAt: later);
      h.azResult = azSnap(fetchedAt: later);
      await h.controller.checkDrift();

      final systems = (await store.readSyncState()).systems;
      expect(systems[core.Origin.smartschool]?.at, later);
      expect(systems[core.Origin.azure]?.at, later);
      // WISA keeps its earlier sync stamp (drift does not re-pull it here).
      expect(systems[core.Origin.wisa]?.at, kFixtureDate);
    });

    test('a sync takes and releases the lease', () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      // Released at the end of the pass — free for the next operator.
      expect(await h.linkedStore.readLease(kFixtureDate), isNull);
      expect(h.controller.syncLockedByOther, isFalse);
    });

    test("another operator's live lease blocks this session's sync", () async {
      final linkedStore = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: linkedStore);
      // A different operator is mid-sync.
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

      await h.controller.sync();

      expect(h.wisaSyncs, 0, reason: 'the blocked sync never pulls');
      expect(h.controller.syncLockedByOther, isTrue);
      expect(h.controller.syncLockOwner, 'mieke@school');
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('mieke@school')),
      );
    });

    test('a foreign lease blocks check-for-drift too', () async {
      final linkedStore = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: linkedStore);
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

      await h.controller.checkDrift();

      expect(h.ssSyncs, 0);
      expect(h.controller.syncLockedByOther, isTrue);
    });

    test('loadOverview surfaces a lock held by another operator', () async {
      final linkedStore = InMemoryLinkedStore();
      // Session 1 materializes an overview.
      await ReconcileHarness(linkedStore: linkedStore).controller.sync();
      // A second operator grabs the lease.
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

      final passive = ReconcileHarness(linkedStore: linkedStore);
      await passive.controller.loadOverview();

      expect(passive.controller.syncLockedByOther, isTrue);
      expect(passive.controller.syncLockOwner, 'mieke@school');
    });

    test(
        'loadOverview leaves the phase idle — reading the shared store is not '
        'a pass (#275)', () async {
      final linkedStore = InMemoryLinkedStore();
      // Another operator's sync materialized the shared overview.
      await ReconcileHarness(linkedStore: linkedStore).controller.sync();

      final passive = ReconcileHarness(linkedStore: linkedStore);
      expect(passive.controller.phase, ReconcilePhase.idle);

      await passive.controller.loadOverview();

      // The shared overview is in hand…
      expect(passive.controller.hasOverview, isTrue);
      // …but this session has pulled nothing and linked nothing, so it is
      // still idle. `ready` claims "the last pass finished and `linked` is
      // current", which would be a straight untruth here — and because the
      // store read resolves before the first frame, that untruth is what kept
      // the screen's idle explainer from ever being painted (#275).
      expect(passive.controller.phase, ReconcilePhase.idle);
      expect(passive.controller.linked, isNull);
      expect(passive.controller.busy, isFalse);

      // A real pass is what moves it off idle.
      await passive.controller.sync();
      expect(passive.controller.phase, ReconcilePhase.ready);
      expect(passive.controller.linked, isNotNull);
    });

    test('onStoreChanged refetches the overview', () async {
      final linkedStore = InMemoryLinkedStore();
      final snapshots = InMemorySnapshotStore();

      // Session 1 materializes generation 1 (the student sits in 3C).
      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      // Session 2 renders the shared overview.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        contains('3C'),
      );

      // Session 1 moves the student to 3D and re-syncs → generation 2.
      s1.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await s1.controller.sync();
      expect((await linkedStore.readSyncState()).generation, 2);

      // The realtime layer (#116) will call this on the generation bump.
      await s2.controller.onStoreChanged(2);

      expect(s2.controller.syncState.generation, 2);
      // 3D now exists in the refreshed rollups, and 3C is gone with it.
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        <String>['3D'],
      );
    });

    test('onStoreChanged is a no-op for a stale-or-equal generation', () async {
      final linkedStore = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: linkedStore);
      await h.controller.sync();

      // Same generation the controller already holds → nothing refetched.
      await h.controller.onStoreChanged(1);
      expect(h.controller.syncState.generation, 1);
    });

    test(
        'resyncFromStore catches a reconnecting session up regardless of '
        'generation (#124)', () async {
      final linkedStore = InMemoryLinkedStore();
      final snapshots = InMemorySnapshotStore();

      // Session 1 materializes generation 1 (the student sits in 3C).
      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      // Session 2 renders the shared overview.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        contains('3C'),
      );

      // Session 1 moves the student to 3D → generation 2. Session 2 was
      // "disconnected" and never saw the nudge.
      s1.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await s1.controller.sync();

      // A reconnect drives the catch-up with no generation argument — it
      // re-reads unconditionally.
      await s2.controller.resyncFromStore();
      expect(s2.controller.syncState.generation, 2);
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        contains('3D'),
      );
    });
  });

  group('adopting the shared synced state (#287)', () {
    /// Session 1 syncs, leaving cold snapshots and a materialized view behind;
    /// session 2 is the fresh launch that seeds from them.
    Future<(ReconcileHarness, InMemorySnapshotStore, InMemoryLinkedStore)>
        sharedState({wapi.WisaSnapshot? wisa}) async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      final s1 = ReconcileHarness(
        wisa: wisa,
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s1.controller.sync();
      return (s1, snapshots, linkedStore);
    }

    test(
        'a seeded session links from the shared state without pulling or '
        'persisting', () async {
      final (_, snapshots, linkedStore) = await sharedState();
      final generationBefore = (await linkedStore.readSyncState()).generation;
      final hub = InMemorySignalHub();

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
        hub: hub,
      );
      expect(s2.controller.linked, isNull, reason: 'nothing linked on open');

      await s2.controller.openSession();

      // The whole point: a usable view, and not one connector was touched.
      expect(s2.controller.linked, isNotNull);
      expect(s2.wisaSyncs, 0);
      expect(s2.ssSyncs, 0);
      expect(s2.azSyncs, 0);
      // It says whose pull it is working from.
      expect(s2.controller.adoptedFrom?.syncedBy, 'operator@school.example');
      expect(s2.controller.seedRefusedReason, isNull);
      // And the shared store is exactly as it was: no generation bump, no
      // rewrite of the ~9.6k documents, no nudge to every other operator.
      expect((await linkedStore.readSyncState()).generation, generationBefore);
      expect(hub.published, isEmpty);
      // Reading the store is still not a pass (#275).
      expect(s2.controller.phase, ReconcilePhase.idle);
    });

    test('the adopted view carries every account, school-wide', () async {
      final (s1, snapshots, linkedStore) = await sharedState();
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );

      await s2.controller.openSession();

      // The same pending work the syncing session derived — with no classroom
      // to open, which is what the flat school-wide list needs (#295).
      expect(
        s2.controller.pendingEntries.map((e) => e.targetId),
        s1.controller.pendingEntries.map((e) => e.targetId),
      );
      expect(s2.controller.pendingEntries, isNotEmpty);
      // And the account documents behind the rows are derived school-wide from
      // that same view, with no per-classroom read at all (#295).
      expect(
        s2.controller.linkedAccounts.map((a) => a.label),
        s1.controller.linkedAccounts.map((a) => a.label),
      );
      expect(s2.controller.linkedAccounts, isNotEmpty);
    });

    test('adoption runs once however many screens open the session', () async {
      final (_, snapshots, linkedStore) = await sharedState();
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );

      await s2.controller.openSession();
      final first = s2.controller.linked;
      // The Acties and Klasgroepen tabs open the same controller.
      await s2.controller.openSession();
      await s2.controller.openSession();

      expect(identical(s2.controller.linked, first), isTrue,
          reason: 'a link over the whole roster is not paid for three times');
    });

    test('a session with no seeded snapshot refuses, and says which', () async {
      final linkedStore = InMemoryLinkedStore();
      await ReconcileHarness(linkedStore: linkedStore).controller.sync();

      // The everyday first launch on a machine whose cold store is empty.
      final fresh = ReconcileHarness(linkedStore: linkedStore);
      await fresh.controller.openSession();

      expect(fresh.controller.linked, isNull);
      expect(fresh.controller.adoptedFrom, isNull);
      expect(
        fresh.controller.seedRefusedReason,
        contains('Geen opgeslagen momentopname voor WISA, Smartschool en '
            'Azure AD'),
      );
      expect(fresh.wisaSyncs, 0);
    });

    test('a store nobody has ever synced has nothing to adopt', () async {
      final snapshots = InMemorySnapshotStore();
      // Seeds without a shared sync record: a cold store written by a pass
      // whose materialize never landed.
      await ReconcileHarness(store: snapshots).controller.sync();

      final s2 = await ReconcileHarness.resume(store: snapshots);
      await s2.controller.openSession();

      expect(s2.controller.linked, isNull);
      expect(
        s2.controller.seedRefusedReason,
        contains('nog geen gedeelde synchronisatie'),
      );
    });

    test('a werkdatum today no longer resolves to refuses, naming both dates',
        () async {
      // The shared roster was pulled three days ago and is *as of* that date;
      // this session's settings track "now", which is the fixture date.
      final stale = kFixtureDate.subtract(const Duration(days: 3));
      final (_, snapshots, linkedStore) = await sharedState(
        wisa: wisaSnap(workDate: stale),
      );

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.openSession();

      expect(s2.controller.linked, isNull);
      expect(s2.controller.seedRefusedReason,
          contains(wapi.formatWerkdatum(stale)));
      expect(s2.controller.seedRefusedReason,
          contains(wapi.formatWerkdatum(kFixtureDate)));
    });

    test('a werkdatum that still matches today is adopted', () async {
      final (_, snapshots, linkedStore) = await sharedState(
        wisa: wisaSnap(workDate: kFixtureDate),
      );

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.openSession();

      expect(s2.controller.linked, isNotNull);
      expect(s2.controller.adoptedFrom?.workDate, kFixtureDate);
    });

    test('a saved setting the seed predates refuses until a sync', () async {
      final (_, snapshots, linkedStore) = await sharedState();
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      // The operator changes an Azure pull input in Instellingen before the
      // first screen finishes opening. The seeded snapshot was pulled without
      // it, so adopting would act on a view the save never reached.
      s2.liveSettings.publish(
        s2.liveSettings.current.copyWith(schoolPrefix: 'NIEUW'),
      );

      await s2.controller.openSession();

      expect(s2.controller.linked, isNull);
      expect(s2.controller.seedRefusedReason, contains('Instellingen'));
    });

    test('a real sync takes the view over from the adopted one', () async {
      final (_, snapshots, linkedStore) = await sharedState();
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.openSession();
      expect(s2.controller.adoptedFrom, isNotNull);

      // The operator decides they want something fresher after all.
      s2.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await s2.controller.sync();

      expect(s2.wisaSyncs, 1);
      expect(s2.controller.linked, isNotNull);
      expect(s2.controller.adoptedFrom, isNull,
          reason: 'this view is this session\'s own now');
      expect((await linkedStore.readSyncState()).generation, 2);
    });

    test('a refusal clears once a sync has produced a view', () async {
      final linkedStore = InMemoryLinkedStore();
      await ReconcileHarness(linkedStore: linkedStore).controller.sync();
      final fresh = ReconcileHarness(linkedStore: linkedStore);
      await fresh.controller.openSession();
      expect(fresh.controller.seedRefusedReason, isNotNull);

      await fresh.controller.sync();

      expect(fresh.controller.seedRefusedReason, isNull);
      expect(fresh.controller.linked, isNotNull);
    });

    test('an adopted session can dry-run and apply without syncing first',
        () async {
      final (_, snapshots, linkedStore) = await sharedState();
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.openSession();

      await s2.controller.dryRunEntries(s2.controller.pendingEntries);

      expect(s2.controller.dryRunResults, isNotNull);
      expect(s2.controller.dryRunResults, isNotEmpty);
      expect(s2.wisaSyncs, 0, reason: 'still no pull anywhere in this session');
    });
  });

  group('realtime signals (#116)', () {
    test('a sync publishes syncStarted → viewChanged → syncEnded', () async {
      final hub = InMemorySignalHub();
      final h = ReconcileHarness(hub: hub);

      await h.controller.sync();

      expect(hub.published.map((s) => s.kind), [
        ChangeSignalKind.syncStarted,
        ChangeSignalKind.viewChanged,
        ChangeSignalKind.syncEnded,
      ]);
      expect(hub.published.first.owner, h.syncedBy);
      final changed = hub.published[1];
      expect(changed.generation, 1);
      expect(changed.shard, isNull,
          reason: 'the sync path rewrites the whole view — no narrower shard');
      expect(hub.published.last.owner, h.syncedBy);
    });

    test('an unchanged WISA re-sync does not publish a viewChanged', () async {
      final hub = InMemorySignalHub();
      final h = ReconcileHarness(hub: hub);
      await h.controller.sync();
      final before = hub.published.length;

      // A fresh but identical WISA pull → "no changes needed", no re-link.
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
      await h.controller.sync();

      final second = hub.published.sublist(before);
      expect(second.map((s) => s.kind),
          isNot(contains(ChangeSignalKind.viewChanged)),
          reason: 'nothing materialized, so no view-change nudge');
      // The lease is still taken and released around the (no-op) pass.
      expect(second.map((s) => s.kind), [
        ChangeSignalKind.syncStarted,
        ChangeSignalKind.syncEnded,
      ]);
    });

    test("another session's viewChanged refetches this session's overview",
        () async {
      final hub = InMemorySignalHub();
      final linkedStore = InMemoryLinkedStore();
      final snapshots = InMemorySnapshotStore();

      // Session 1 materializes generation 1 and broadcasts.
      final s1 = ReconcileHarness(
          store: snapshots, linkedStore: linkedStore, hub: hub);
      await s1.controller.sync();

      // Session 2 renders the shared overview passively, on the same hub.
      final s2 = await ReconcileHarness.resume(
          store: snapshots, linkedStore: linkedStore, hub: hub);
      await s2.controller.loadOverview();
      expect(s2.controller.syncState.generation, 1);

      // Session 1 moves the student and re-syncs → generation 2 is broadcast.
      s1.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await s1.controller.sync();
      await pumpEventQueue();

      // Session 2 caught up from the signal alone — no direct onStoreChanged.
      expect(s2.controller.syncState.generation, 2);
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        contains('3D'),
      );
    });

    test('a syncStarted signal locks a passive session; syncEnded unlocks',
        () async {
      final hub = InMemorySignalHub();
      final linkedStore = InMemoryLinkedStore();
      // A first session leaves an overview in the shared store (no hub, so it
      // does not publish into this test).
      await ReconcileHarness(linkedStore: linkedStore).controller.sync();

      final passive = ReconcileHarness(linkedStore: linkedStore, hub: hub);
      await passive.controller.loadOverview();
      expect(passive.controller.syncLockedByOther, isFalse);

      // Another operator takes the lease and nudges everyone.
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);
      await hub
          .publisher()
          .publish(const ChangeSignal.syncStarted(owner: 'mieke@school'));
      await pumpEventQueue();
      expect(passive.controller.syncLockedByOther, isTrue);
      expect(passive.controller.syncLockOwner, 'mieke@school');

      // They finish: release + nudge → the passive session re-enables.
      await linkedStore.releaseLease(owner: 'mieke@school');
      await hub
          .publisher()
          .publish(const ChangeSignal.syncEnded(owner: 'mieke@school'));
      await pumpEventQueue();
      expect(passive.controller.syncLockedByOther, isFalse);
    });

    test('a publish failure is logged but never fails the sync', () async {
      final h = ReconcileHarness(publisher: _ThrowingPublisher());

      await h.controller.sync();

      expect(h.controller.error, isNull, reason: 'the pass still succeeds');
      expect(h.controller.linked, isNotNull);
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('Kon geen wijzigingssignaal versturen')),
      );
    });
  });

  group('an apply reaches the other operators (#254)', () {
    /// 3C's node as [c] currently renders it, or null when the tree no longer
    /// carries the class at all.
    Rollup? klas3C(ReconcileController c) {
      for (final school in c.studentRollups) {
        for (final klas in c.studentChildrenOf(school)) {
          if (klas.classroom == '3C') return klas;
        }
      }
      return null;
    }

    test(
        'a passive session catches up from the signal alone — no sync, no pull',
        () async {
      // The bug, at the level it is actually felt: operator B keeps being
      // offered work operator A already applied, until *somebody* runs a full
      // Synchroniseer. Two sessions, one shared store, one realtime hub.
      final hub = InMemorySignalHub();
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      final a = appliedClassWorkHarness(
        store: snapshots,
        linkedStore: linkedStore,
        hub: hub,
      );
      await a.controller.sync();

      final b = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
        hub: hub,
      );
      await b.controller.loadOverview();
      expect(klas3C(b.controller)?.pendingCount, 1,
          reason: "B is offered Sam's stale Office 365 name");

      // A applies it. B is told, and refetches the changed shard.
      final entry =
          a.controller.pendingEntries.singleWhere((e) => e.family == 'student');
      await a.controller.applyEntry(entry);
      await pumpEventQueue();

      expect(b.controller.syncState.generation, 2);
      expect(klas3C(b.controller)?.pendingCount, 0,
          reason: 'B used to keep offering it until someone re-synced');
      expect(b.wisaSyncs, 0, reason: 'the nudge never triggers a pull');
      expect(b.ssSyncs, 0);
      expect(b.azSyncs, 0);
    });

    test('the applied entry is dropped from the stored account document too',
        () async {
      // The rollups are aggregates; the per-account documents are what a
      // session adopting the shared state links from. The write-back has to
      // move both, or the next session to open reads the work as still due.
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      final a = appliedClassWorkHarness(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await a.controller.sync();
      expect(
        (await linkedStore.readClassroom(school: '1', classroom: '3C'))
            .expand((acc) => acc.candidates)
            .where((c) => c.canApply),
        hasLength(1),
      );

      await a.controller.applyEntry(a.controller.pendingEntries
          .singleWhere((e) => e.family == 'student'));
      await pumpEventQueue();

      expect(
        (await linkedStore.readClassroom(school: '1', classroom: '3C'))
            .expand((acc) => acc.candidates),
        isEmpty,
        reason: 'the write-back patched the document, not only the rollup',
      );
    });

    test('the apply broadcasts the classroom it changed, not the whole view',
        () async {
      final hub = InMemorySignalHub();
      final h = appliedClassWorkHarness(hub: hub);
      await h.controller.sync();
      final before = hub.published.length;

      await h.controller.applyEntry(
        h.controller.pendingEntries.singleWhere((e) => e.family == 'student'),
      );

      final published = hub.published.sublist(before);
      expect(published.map((s) => s.kind), [ChangeSignalKind.viewChanged],
          reason: 'an apply takes no lease, so it opens and closes nothing');
      final signal = published.single;
      expect(signal.generation, 2);
      expect(signal.shard?.school, '1');
      expect(signal.shard?.classroom, '3C');
      expect(signal.shard?.accountId, isNotNull,
          reason: 'a one-row apply can name the very account it wrote');
    });

    test('a shard rules the class inventory out of the refetch', () async {
      // What the shard is for: a session holding the Klasgroepen inventory is
      // told about a change in one classroom, and does not pay for an inventory
      // read it can prove is pointless.
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      await appliedClassWorkHarness(store: snapshots, linkedStore: linkedStore)
          .controller
          .sync();

      final b = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await b.controller.loadOverview();
      await b.controller.loadGroups();
      final loaded = b.controller.groupDocs;
      expect(loaded, isNotEmpty);

      await b.controller.onStoreChanged(
        99,
        shard: const ShardRef(school: '1', classroom: '3C'),
      );

      expect(b.controller.syncState.generation, 1,
          reason: 'the overview itself is always re-read');
      expect(identical(b.controller.groupDocs, loaded), isTrue,
          reason: 'the inventory was never re-read — the shard ruled it out');

      // …while a shard that cannot rule it out does re-read it.
      await b.controller.onStoreChanged(
        100,
        shard: const ShardRef(school: groupsPartition),
      );
      expect(identical(b.controller.groupDocs, loaded), isFalse);
    });

    test('a class-group apply reaches the stored group document', () async {
      // A group entry is keyed by the class's display name, the document by the
      // materializer's namespaced `group|<name>`. Cross that wrong and the patch
      // writes a document nothing reads.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final entry =
          h.controller.pendingEntries.firstWhere((e) => e.family == 'group');
      final id = materializedGroupId(entry.targetId);
      expect(
        (await h.linkedStore.readGroups())
            .singleWhere((g) => g.id.value == id)
            .candidates,
        isNotEmpty,
      );

      await h.controller.applyEntry(entry);

      final stored = (await h.linkedStore.readGroups())
          .singleWhere((g) => g.id.value == id);
      expect(stored.hasPending, isFalse,
          reason: 'the very document the Klasgroepen tab reads has moved');
      expect(
          (await h.linkedStore.readRollups())
              .singleWhere((r) => r.level == RollupLevel.groups)
              .pendingCount,
          lessThan(4));
    });
  });

  group('accepted duplicate-mail (#109)', () {
    test('a synced collision surfaces one warning with its colliding accounts',
        () async {
      final h = dupMailHarness();
      await h.controller.sync();

      final warnings = h.controller.duplicateWarnings;
      expect(warnings, hasLength(1));
      final w = warnings.single;
      expect(w.mail, 'shared@school.example');
      expect(w.accepted, isFalse);
      expect(w.accounts.map((a) => a.uid).toSet(), {'admin', 'user'});
      // The colliding accounts carry their display detail for the drill-down.
      expect(w.accounts.every((a) => a.name.isNotEmpty), isTrue);
      expect(w.accounts.every((a) => a.accountType == 'student'), isTrue);
    });

    test(
        'accepting persists a decision and demotes the warning; revoke restores',
        () async {
      final linkedStore = InMemoryLinkedStore();
      final h = dupMailHarness(linkedStore: linkedStore);
      await h.controller.sync();

      await h.controller.acceptDuplicate('shared@school.example');
      // Persisted as an acceptedDuplicate decision keyed to a colliding account.
      final stored = await linkedStore.readDecisions();
      expect(stored, hasLength(1));
      expect(stored.single.kind, DecisionKind.acceptedDuplicate);
      // …and the live warning is now demoted (accepted).
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);

      await h.controller.revokeDuplicate('shared@school.example');
      expect(await linkedStore.readDecisions(), isEmpty);
      expect(h.controller.duplicateWarnings.single.accepted, isFalse);
    });

    test('an accepted collision survives a re-sync (re-attached decision)',
        () async {
      final linkedStore = InMemoryLinkedStore();
      // A snapshot store makes the re-sync path materialize + merge decisions.
      final h = ReconcileHarness(
        wisa: wisaSnap(students: const []),
        smartschool: dupMailSnap(),
        azure: azSnap(users: const []),
        store: InMemorySnapshotStore(),
        linkedStore: linkedStore,
      );
      await h.controller.sync();
      await h.controller.acceptDuplicate('shared@school.example');
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);

      // Re-read Smartschool/Azure and re-link; the view is rewritten wholesale.
      await h.controller.checkDrift();

      // The decision survived the rewrite (merge re-attached it), still accepted.
      expect(await linkedStore.readDecisions(), hasLength(1));
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);
    });

    test('a changed colliding set re-warns even after acceptance', () async {
      final linkedStore = InMemoryLinkedStore();
      final h = dupMailHarness(linkedStore: linkedStore);
      await h.controller.sync();
      await h.controller.acceptDuplicate('shared@school.example');
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);

      // A third account joins the same mail: re-read Smartschool via drift.
      h.ssResult = dupMailSnap(uids: const ['admin', 'user', 'intruder']);
      await h.controller.checkDrift();

      final w = h.controller.duplicateWarnings.single;
      expect(w.accounts, hasLength(3));
      expect(w.accepted, isFalse,
          reason: 'a new colliding account must re-surface the warning');
    });
  });

  group('a LinkedAccountId claimed twice (INV-24, #319)', () {
    test('the collision reaches the controller instead of vanishing', () async {
      final h = idCollisionHarness();
      await h.controller.sync();

      final collisions = h.controller.linkIdCollisions;
      expect(collisions, hasLength(1));
      expect(collisions.single.id, 'p-shared');
      // Two records, each named by what it holds so they can be told apart —
      // which is the only thing that makes the collision actionable.
      expect(collisions.single.records, hasLength(2));
      expect(collisions.single.records.first, contains('WISA W1'));
      expect(collisions.single.records.first, contains('Smartschool jane'));
      expect(collisions.single.records.last, contains('WISA W2'));
      expect(collisions.single.records.last, contains('Smartschool —'));
    });

    test('the sync log names it, so it is visible with no card at all',
        () async {
      final h = idCollisionHarness();
      await h.controller.sync();

      final lines = h.log.entries.map((e) => e.message).toList();
      final named = lines.where((l) => l.contains('Koppelingsfout')).toList();
      expect(named, hasLength(1));
      expect(named.single, contains('p-shared'));
      expect(named.single, contains('WISA W1'));
      expect(named.single, contains('WISA W2'));
    });

    test('the tally counts the shared id once, so the overview is honest',
        () async {
      final h = idCollisionHarness();
      await h.controller.sync();

      // Two WISA students on one id ⇒ one person. Counting per record made the
      // WISA total 2 and the dashboard's linked/total ratio wrong for as long
      // as the collision lasted.
      expect(h.controller.linked!.snapshot.wisa.total, 1);
    });

    test('an ordinary sync reports no collision', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      expect(h.controller.linkIdCollisions, isEmpty);
      expect(
        h.log.entries
            .map((e) => e.message)
            .where((l) => l.contains('Koppelingsfout')),
        isEmpty,
      );
    });
  });

  group('a class entry that owes two writes (#272)', () {
    /// The Smartschool half: the recorded SOAP action is the fully-qualified
    /// `…V3#saveClass`.
    bool savedAClass(ReconcileHarness h) =>
        h.soap.soapActions.any((a) => a.endsWith('#saveClass'));

    PendingAccountEntry entryOf(ReconcileHarness h) =>
        h.controller.groupPendingEntries
            .firstWhere((e) => e.targetId == '5WW1');

    test('offers the Office 365 create beside the Smartschool either/or',
        () async {
      final h = newClassNeedingBothWritesHarness();
      await h.controller.sync();

      final entry = entryOf(h);
      expect(
        entry.choices.map((c) => c.selected.kind),
        ['CreateAzureClassGroup', 'AddToSmartschool'],
        reason: 'two decisions on one card, and both are selected to run',
      );
      expect(h.controller.applyScope(<PendingAccountEntry>[entry]).systems,
          [core.Origin.azure, core.Origin.smartschool]);
    });

    test('applying it creates the Smartschool class *and* the Office 365 group',
        () async {
      final h = newClassNeedingBothWritesHarness();
      await h.controller.sync();

      await h.controller.applyEntry(entryOf(h));

      expect(savedAClass(h), isTrue);
      expect(h.graph.createdGroups, hasLength(1));
      expect(h.graph.createdGroups.single['displayName'], 'GBS-5WW1');
      // …and the create chained its roster write (#245), so the group is not
      // left empty by the one click that made it.
      expect(h.graph.batchedWrites, hasLength(2));
      expect(
        h.controller.groupPendingEntries.map((e) => e.targetId),
        isNot(contains('5WW1')),
        reason: 'both writes landed, so the class owes nothing',
      );
    });

    test('a refused Office 365 create does not stop the Smartschool half',
        () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();

      await h.controller.applyEntry(entryOf(h));

      expect(savedAClass(h), isTrue,
          reason: 'a failed action must not abort the rest of the pass');
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        [actions.ActionOutcome.failed, actions.ActionOutcome.applied],
      );
    });

    test('a refused Office 365 create is reported on the entry that owed it',
        () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();
      await h.controller.applyEntry(entryOf(h));

      // The card's own verdict — the whole of #272. Before this the only two
      // records of the refusal were a log line on another screen and a row in a
      // results section below the entire inventory.
      final entry = entryOf(h);
      final outcomes = h.controller.applyOutcomesFor(entry);
      expect(outcomes, hasLength(2));
      expect(outcomes.first.outcome, actions.ActionOutcome.failed);
      expect(outcomes.first.changes.summary,
          'Maak de Office 365-groep GBS-5WW1 voor klas 5WW1');
      expect(
          '${outcomes.first.error}', contains('Authorization_RequestDenied'));
      expect(outcomes.last.outcome, actions.ActionOutcome.applied);
      expect(
          outcomes.last.changes.summary, 'Voeg deze klas toe aan Smartschool');
    });

    test('a refused create stays on the card, so it can be run again',
        () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();
      await h.controller.applyEntry(entryOf(h));

      final entry = entryOf(h);
      expect(
          entry.choices.map((c) => c.selected.kind), ['CreateAzureClassGroup'],
          reason: 'a failed write left the record alone, so it is re-offered');
      expect(entry.canApply, isTrue);

      // And a retry against a tenant that no longer refuses it lands.
      h.graph.refuseGroupCreates = false;
      await h.controller.applyEntry(entry);
      expect(h.graph.createdGroups, hasLength(1));
      expect(h.graph.createdGroups.single['displayName'], 'GBS-5WW1');
    });

    test("another entry's verdict never lands on this card", () async {
      final h = newClassChoiceHarness();
      await h.controller.sync();
      final one = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');
      final other = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1B');

      await h.controller.applyEntry(one);

      expect(h.controller.applyOutcomesFor(other), isEmpty);
      expect(
        h.controller
            .applyOutcomesFor(one)
            .map((o) => o.changes.summary)
            .toList(),
        contains('Voeg deze klas toe aan Smartschool'),
      );
    });

    test('a sync clears the verdict a previous pass left on a card', () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();
      await h.controller.applyEntry(entryOf(h));
      expect(h.controller.applyOutcomesFor(entryOf(h)), isNotEmpty);

      await h.controller.checkDrift();
      expect(h.controller.applyOutcomesFor(entryOf(h)), isEmpty);
    });
  });

  group("a verdict belongs to the decision it is the verdict of (#283)", () {
    PendingAccountEntry entryOf(ReconcileHarness h) =>
        h.controller.groupPendingEntries
            .firstWhere((e) => e.targetId == '5WW1');

    test('every row is stamped with the decision that produced it', () async {
      final h = newClassNeedingBothWritesHarness();
      await h.controller.sync();
      // Before the apply, so both decisions are still there to be named.
      expect(entryOf(h).choices.map((c) => c.situationId),
          ['CreateAzureClassGroup', actions.classImportAlternative]);

      await h.controller.applyEntry(entryOf(h));

      // `family` + `targetId` name the card, never the decision — the whole
      // reason the verdicts pooled. The situation is the third stamp.
      expect(
        h.controller.applyResults!.map((r) => r.situationId).toList(),
        <String>[
          // The Office 365 create…
          'CreateAzureClassGroup',
          // …and the roster write it chained (#245), which the operator
          // started by picking that option, so it answers that decision.
          'CreateAzureClassGroup',
          actions.classImportAlternative,
        ],
      );
    });

    test('the refused half routes into the decision that is still offered',
        () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();
      await h.controller.applyEntry(entryOf(h));

      final entry = entryOf(h);
      final choice = entry.choices.single;
      expect(choice.situationId, 'CreateAzureClassGroup',
          reason:
              'the failed write left the record alone, so it is re-offered');

      final routed = h.controller.applyOutcomesForChoice(entry, choice);
      expect(routed, hasLength(1));
      expect(routed.single.outcome, actions.ActionOutcome.failed);
      expect(routed.single.changes.summary,
          'Maak de Office 365-groep GBS-5WW1 voor klas 5WW1');
      expect('${routed.single.error}', contains('Authorization_RequestDenied'));
    });

    test('the half that succeeded is still reported, at card level', () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();
      await h.controller.applyEntry(entryOf(h));

      // The Smartschool create landed, so its decision is gone from the entry
      // the relink built — and its verdict would silently vanish with it.
      final entry = entryOf(h);
      expect(entry.choices.map((c) => c.situationId),
          isNot(contains(actions.classImportAlternative)));

      final unrouted = h.controller.unroutedApplyOutcomesFor(entry);
      expect(unrouted, hasLength(1));
      expect(unrouted.single.outcome, actions.ActionOutcome.applied);
      expect(unrouted.single.changes.summary,
          'Voeg deze klas toe aan Smartschool');
    });

    test('the split partitions the verdict — nothing doubled, nothing lost',
        () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();
      await h.controller.applyEntry(entryOf(h));

      final entry = entryOf(h);
      final shown = <ActionOutcomeEntry>[
        for (final c in entry.choices)
          ...h.controller.applyOutcomesForChoice(entry, c),
        ...h.controller.unroutedApplyOutcomesFor(entry),
      ];
      expect(
        shown.map((r) => r.changes.summary).toList(),
        h.controller
            .applyOutcomesFor(entry)
            .map((r) => r.changes.summary)
            .toList(),
      );
    });

    test("another decision's verdict never lands in this block", () async {
      final h = newClassNeedingBothWritesHarness();
      h.graph.refuseGroupCreates = true;
      await h.controller.sync();
      await h.controller.applyEntry(entryOf(h));

      final entry = entryOf(h);
      final routed = h.controller
          .applyOutcomesForChoice(entry, entry.choices.single)
          .map((r) => r.changes.summary);
      expect(routed, isNot(contains('Voeg deze klas toe aan Smartschool')));
    });

    test('a dry-run verdict routes the same way as an apply', () async {
      final h = newClassNeedingBothWritesHarness();
      await h.controller.sync();
      // A dry-run settles nothing, so both decisions are still on the card and
      // each one claims its own row.
      await h.controller.dryRunEntry(entryOf(h));

      final entry = entryOf(h);
      expect(
        <String>[
          for (final c in entry.choices)
            ...h.controller
                .applyOutcomesForChoice(entry, c)
                .map((r) => r.changes.summary),
        ],
        <String>[
          'Maak de Office 365-groep GBS-5WW1 voor klas 5WW1',
          'Voeg deze klas toe aan Smartschool',
        ],
      );
      expect(h.controller.unroutedApplyOutcomesFor(entry), isEmpty);
    });
  });

  group('a second Azure write in one pass (#321)', () {
    PendingAccountEntry studentEntry(ReconcileHarness h) =>
        h.controller.pendingEntries.singleWhere((e) => e.family == 'student');

    List<String> summariesOf(PendingAccountEntry e) =>
        <String>[for (final c in e.choices) c.selected.changes.summary];

    test('the card owes both Azure modifies before the pass', () async {
      final h = twoAzureWritesHarness();
      await h.controller.sync();

      expect(
        summariesOf(studentEntry(h)),
        containsAll(<String>[
          'Wijzig de naam in Azure',
          'Wijzig de school in Azure',
        ]),
        reason: 'the fixture is the two-Azure-writes card the bug needs',
      );
    });

    test('the held record carries both writes, not only the last', () async {
      // The pass resolved every action once, up front, off the pre-apply view,
      // and an Azure modify projects its mutated record as `_az.copyWith(…)`
      // off the record it was bound to. So the second splice put the pre-apply
      // value of the first write's field back: Graph held both PATCHes and the
      // snapshot held one.
      final h = twoAzureWritesHarness();
      await h.controller.sync();

      await h.controller.applyEntry(studentEntry(h));

      expect(h.controller.error, isNull);
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.applied),
      );
      expect(
        h.graph.requests.where((r) => r.method == 'PATCH'),
        hasLength(2),
        reason: 'both writes really went out',
      );
      final user = h.app.azure.snapshot!.users.single;
      expect(user.displayName, 'Jane Doe');
      expect(user.companyName, 'GBS');
    });

    test('neither write is re-offered the moment it landed', () async {
      // The contradicted record is what the relink dispatches from — and what
      // `_shareApplied` publishes to the other operators — so a reverted splice
      // re-raises an action for a change Azure already holds.
      final h = twoAzureWritesHarness();
      await h.controller.sync();

      await h.controller.applyEntry(studentEntry(h));

      expect(
        h.controller.pendingEntries.where((e) => e.family == 'student'),
        isEmpty,
      );
    });

    test('a dry-run still projects both, writing nothing', () async {
      // A projection refreshes no view, so there is nothing to re-resolve
      // against and the pass must behave exactly as it always did.
      final h = twoAzureWritesHarness();
      await h.controller.sync();

      await h.controller.dryRunEntry(studentEntry(h));

      expect(
        h.controller.dryRunResults!.map((r) => r.changes.summary),
        containsAll(<String>[
          'Wijzig de naam in Azure',
          'Wijzig de school in Azure',
        ]),
      );
      expect(h.graph.requests, isEmpty);
      expect(summariesOf(studentEntry(h)), hasLength(2),
          reason: 'nothing was written, so nothing was settled');
    });
  });

  group('LogBuffer', () {
    test('caps its entries and reports errors', () {
      final log = LogBuffer(capacity: 3, clock: () => kFixtureDate);
      for (var i = 0; i < 5; i++) {
        log.addMessage(core.Origin.wisa, 'message $i');
      }
      expect(log.entries, hasLength(3));
      expect(log.entries.first.message, 'message 2');
      expect(log.hasErrors, isFalse);

      log.addError(core.Origin.azure, 'boom');
      expect(log.hasErrors, isTrue);

      log.clear();
      expect(log.entries, isEmpty);
    });
  });
}
