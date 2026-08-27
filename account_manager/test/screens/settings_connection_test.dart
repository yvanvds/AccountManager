import 'package:account_manager/src/auth/aad_app_config.dart';
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart'
    show StoreEndpoints;
import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_manager/src/settings/connection_config.dart';
import 'package:account_manager/src/settings/settings_bootstrap.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'settings_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _openTab(WidgetTester tester, String tabKey) async {
  await tester.tap(find.byKey(ValueKey(tabKey)));
  await tester.pumpAndSettle();
}

/// Which tab is actually in front. Read off the [TabBar]'s own controller
/// rather than inferred from what is findable: a [TabBarView] builds the pages
/// adjacent to the current one, so "the field exists" is not evidence that its
/// tab is the selected one.
int _selectedTab(WidgetTester tester) => tester
    .widget<TabBar>(find.byKey(const ValueKey('settings-tabs')))
    .controller!
    .index;

const AadAppConfig _storedAad = AadAppConfig(
  clientId: 'opgeslagen-client',
  tenantId: 'opgeslagen-tenant',
  azureDomain: 'opgeslagen.example',
  schoolPrefix: 'OPG',
);

const StoreEndpoints _stored = StoreEndpoints(
  cosmosEndpoint: 'https://opgeslagen.documents.azure.com:443/',
  cosmosDatabase: 'opgeslagen-db',
  vaultUri: 'https://opgeslagen-kv.vault.azure.net/',
  blobEndpoint: 'https://opgeslagen.blob.core.windows.net',
  blobContainer: 'opgeslagen-snapshots',
  signalrEndpoint: 'https://opgeslagen.service.signalr.net',
  signalrHub: 'opgeslagen-hub',
);

/// The Settings view bound to a store whose load fails — the state a wrong
/// Cosmos endpoint puts an operator in (#370).
Future<SettingsServices> Function() _brokenBootstrap(FailingSettingsStore s) =>
    () async => SettingsServices(
          store: s,
          secrets: InMemorySecretProvider(const <SecretRef, String>{}),
        );

void main() {
  testWidgets('the Verbinding tab shows the resolved values and their source',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final store = InMemoryConnectionStore(stored: _stored);
    await tester.pumpWidget(_wrap(SettingsScreen(
      bootstrap: SettingsHarness().bootstrap,
      connection: ConnectionServices(store: store),
    )));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-verbinding');

    final Finder cosmos =
        find.byKey(const ValueKey('settings-connection-cosmos-endpoint'));
    expect(
      tester.widget<TextField>(cosmos).controller!.text,
      _stored.cosmosEndpoint,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('settings-connection-signalr-hub')),
          )
          .controller!
          .text,
      _stored.signalrHub,
    );
    // Where the value came from, in the operator's words.
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-connection-source')),
          )
          .data,
      contains('uit '),
    );
  });

  testWidgets('an install with no connection file reads as the build default',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(_wrap(SettingsScreen(
      bootstrap: SettingsHarness().bootstrap,
      connection: ConnectionServices(store: InMemoryConnectionStore()),
    )));
    await tester.pumpAndSettle();
    await _openTab(tester, 'settings-tab-verbinding');

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-connection-source')),
          )
          .data,
      contains('standaardwaarde'),
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('settings-connection-cosmos-endpoint')),
          )
          .controller!
          .text,
      StoreEndpoints.fromEnvironment().cosmosEndpoint,
    );
  });

  testWidgets('editing and saving writes the whole coordinate set to the store',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final store = InMemoryConnectionStore();
    await tester.pumpWidget(_wrap(SettingsScreen(
      bootstrap: SettingsHarness().bootstrap,
      connection: ConnectionServices(store: store),
    )));
    await tester.pumpAndSettle();
    await _openTab(tester, 'settings-tab-verbinding');

    await tester.enterText(
      find.byKey(const ValueKey('settings-connection-cosmos-endpoint')),
      'https://nieuw.documents.azure.com:443/',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-connection-cosmos-database')),
      'nieuw-db',
    );
    await tester.tap(find.byKey(const ValueKey('settings-connection-save')));
    await tester.pumpAndSettle();

    expect(store.stored, isNotNull);
    expect(
        store.stored!.cosmosEndpoint, 'https://nieuw.documents.azure.com:443/');
    expect(store.stored!.cosmosDatabase, 'nieuw-db');
    // The untouched coordinates are written too, so the file is a complete
    // answer rather than a fragment layered over whatever the build had.
    expect(store.stored!.vaultUri, StoreEndpoints.fromEnvironment().vaultUri);
    // And the source flips: the values on screen now come from the file.
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-connection-source')),
          )
          .data,
      contains('uit '),
    );
  });

  testWidgets('a save that changes the coordinates says a relaunch is needed',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final store = InMemoryConnectionStore(stored: _stored);
    await tester.pumpWidget(_wrap(SettingsScreen(
      bootstrap: SettingsHarness().bootstrap,
      connection: ConnectionServices(store: store),
    )));
    await tester.pumpAndSettle();
    await _openTab(tester, 'settings-tab-verbinding');

    // Saving the values unchanged changes nothing that is running, so the
    // notice would be noise.
    await tester.tap(find.byKey(const ValueKey('settings-connection-save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-connection-relaunch')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-connection-cosmos-endpoint')),
      'https://anders.documents.azure.com:443/',
    );
    await tester.tap(find.byKey(const ValueKey('settings-connection-save')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-connection-relaunch')),
      findsOneWidget,
    );
  });

  testWidgets('a malformed connection file is reported, not hidden',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(_wrap(SettingsScreen(
      bootstrap: SettingsHarness().bootstrap,
      connection: ConnectionServices(store: _WarningStore()),
    )));
    await tester.pumpAndSettle();
    await _openTab(tester, 'settings-tab-verbinding');

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-connection-warning')),
          )
          .data,
      contains('kon niet gelezen worden'),
    );
  });

  testWidgets('Verbinding testen probes the values as typed, before they save',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final probe = FakeConnectionProbe(const <ConnectionProbeResult>[
      ConnectionProbeResult(id: 'cosmos', label: 'Cosmos DB', ok: true),
      ConnectionProbeResult(
        id: 'vault',
        label: 'Key Vault',
        ok: false,
        detail: 'Failed host lookup',
      ),
    ]);
    final store = InMemoryConnectionStore();
    await tester.pumpWidget(_wrap(SettingsScreen(
      bootstrap: SettingsHarness().bootstrap,
      connection: ConnectionServices(store: store, probe: probe.call),
    )));
    await tester.pumpAndSettle();
    await _openTab(tester, 'settings-tab-verbinding');

    await tester.enterText(
      find.byKey(const ValueKey('settings-connection-cosmos-endpoint')),
      'https://getypt.documents.azure.com:443/',
    );
    await tester.tap(find.byKey(const ValueKey('settings-connection-test')));
    await tester.pumpAndSettle();

    // Probed as typed — the whole point is finding the typo before it costs a
    // relaunch — and nothing was committed.
    expect(probe.calls, 1);
    expect(
      probe.lastEndpoints!.cosmosEndpoint,
      'https://getypt.documents.azure.com:443/',
    );
    expect(store.stored, isNull);

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-connection-probe-cosmos')),
          )
          .data,
      contains('bereikbaar'),
    );
    final String vault = tester
        .widget<Text>(
          find.byKey(const ValueKey('settings-connection-probe-vault')),
        )
        .data!;
    expect(vault, contains('niet bereikbaar'));
    expect(vault, contains('Failed host lookup'));
  });

  testWidgets('with no probe wired the test button is absent, not inert',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(_wrap(SettingsScreen(
      bootstrap: SettingsHarness().bootstrap,
      connection: ConnectionServices(store: InMemoryConnectionStore()),
    )));
    await tester.pumpAndSettle();
    await _openTab(tester, 'settings-tab-verbinding');

    expect(
      find.byKey(const ValueKey('settings-connection-test')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('settings-connection-save')),
      findsOneWidget,
    );
  });

  group('the screen opens while the settings store is unreachable (#370)', () {
    testWidgets('the Verbinding tab is brought forward and is fully editable',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final store = InMemoryConnectionStore();
      final broken = FailingSettingsStore();
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: _brokenBootstrap(broken),
        connection: ConnectionServices(store: store),
      )));
      await tester.pumpAndSettle();

      // No dead end: the tab frame is there and Verbinding is already the tab
      // in front, without the operator having to find it.
      expect(find.byKey(const ValueKey('settings-tabs')), findsOneWidget);
      expect(broken.loads, 1);
      expect(_selectedTab(tester), 4, reason: 'Verbinding is the last tab');
      expect(
        find.byKey(const ValueKey('settings-connection-cosmos-endpoint')),
        findsOneWidget,
      );

      // And it saves — the whole feature is worthless if the section renders
      // but cannot write.
      await tester.enterText(
        find.byKey(const ValueKey('settings-connection-cosmos-endpoint')),
        'https://hersteld.documents.azure.com:443/',
      );
      await tester.tap(find.byKey(const ValueKey('settings-connection-save')));
      await tester.pumpAndSettle();

      expect(
        store.stored!.cosmosEndpoint,
        'https://hersteld.documents.azure.com:443/',
      );
    });

    testWidgets('the document tabs explain themselves and offer the retry',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final broken = FailingSettingsStore();
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: _brokenBootstrap(broken),
        connection: ConnectionServices(store: InMemoryConnectionStore()),
      )));
      await tester.pumpAndSettle();

      await _openTab(tester, 'settings-tab-algemeen');
      expect(_selectedTab(tester), 0);
      expect(find.text('Kon de instellingen niet laden'), findsOneWidget);
      expect(find.textContaining('tabblad Verbinding'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings-retry')));
      await tester.pumpAndSettle();
      expect(broken.loads, 2);

      // A second failure must not yank the operator back off the tab they are
      // on — the reveal is a one-time courtesy, not a hijack.
      expect(_selectedTab(tester), 0);
      expect(find.text('Kon de instellingen niet laden'), findsOneWidget);
    });

    testWidgets('a load that succeeds leaves the operator on Algemeen',
        (WidgetTester tester) async {
      // The negative control for the reveal above: nothing moves the tab when
      // there is nothing to fix.
      _useTallWindow(tester);
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
      )));
      await tester.pumpAndSettle();

      expect(_selectedTab(tester), 0);
    });

    testWidgets('Opslaan is disabled with no document to save',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: _brokenBootstrap(FailingSettingsStore()),
        connection: ConnectionServices(store: InMemoryConnectionStore()),
      )));
      await tester.pumpAndSettle();

      final Finder save = find.byKey(const ValueKey('settings-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      // Herladen stays live: it is the retry.
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('settings-reload')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a store that recovers fills the document tabs in',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      // First attempt fails, the second succeeds — what fixing the endpoint and
      // pressing Herladen looks like from the screen's side.
      var attempt = 0;
      final settings = InMemorySettingsStore(
        const AppSettings(schoolPrefix: 'GBS'),
      );
      Future<SettingsServices> bootstrap() async => SettingsServices(
            store: _FlakySettingsStore(() => attempt++ == 0, settings),
            secrets: InMemorySecretProvider(const <SecretRef, String>{}),
          );
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
      )));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('settings-tab-algemeen')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-reload')));
      await tester.pumpAndSettle();

      await _openTab(tester, 'settings-tab-algemeen');
      expect(find.text('GBS'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('settings-save')))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('the Azure AD app registration is configured here (#384)', () {
    testWidgets('the section shows the resolved values and their source',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(
          store: InMemoryConnectionStore(
            stored: _stored,
            storedAad: _storedAad,
          ),
        ),
      )));
      await tester.pumpAndSettle();
      await _openTab(tester, 'settings-tab-verbinding');

      expect(_text(tester, 'settings-aad-client-id'), _storedAad.clientId);
      expect(_text(tester, 'settings-aad-tenant-id'), _storedAad.tenantId);
      expect(_text(tester, 'settings-aad-domain'), _storedAad.azureDomain);
      expect(
        _text(tester, 'settings-aad-school-prefix'),
        _storedAad.schoolPrefix,
      );
      expect(_note(tester, 'settings-aad-source'), contains('uit '));
      // Configured, so the "you cannot sign in yet" line is absent rather than
      // standing over four filled-in fields.
      expect(
          find.byKey(const ValueKey('settings-aad-incomplete')), findsNothing);
    });

    testWidgets('a file written before #384 reads as the build default',
        (WidgetTester tester) async {
      // The realistic upgrade: an install that took #370 has a connection.json
      // with endpoints and no AAD keys. The two halves must report separately —
      // the endpoints came from the file, the sign-in config did not.
      _useTallWindow(tester);
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(
          store: InMemoryConnectionStore(stored: _stored),
        ),
      )));
      await tester.pumpAndSettle();
      await _openTab(tester, 'settings-tab-verbinding');

      expect(_note(tester, 'settings-connection-source'), contains('uit '));
      expect(_note(tester, 'settings-aad-source'), contains('standaardwaarde'));
      // And on a build with no --dart-define that default is empty, which is
      // said out loud rather than left to be inferred from two blank fields.
      expect(_text(tester, 'settings-aad-client-id'), isEmpty);
      expect(
        _note(tester, 'settings-aad-incomplete'),
        contains('Aanmelden is nog niet mogelijk'),
      );
    });

    testWidgets('saving writes both halves of the file in one press',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      final store = InMemoryConnectionStore();
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(store: store),
      )));
      await tester.pumpAndSettle();
      await _openTab(tester, 'settings-tab-verbinding');

      await _type(tester, 'settings-aad-client-id', 'nieuwe-client');
      await _type(tester, 'settings-aad-tenant-id', 'nieuwe-tenant');
      await _type(tester, 'settings-aad-domain', 'nieuw.example');
      await _type(tester, 'settings-aad-school-prefix', 'NWE');
      await _type(
        tester,
        'settings-connection-cosmos-database',
        'nieuw-db',
      );
      await tester.tap(find.byKey(const ValueKey('settings-connection-save')));
      await tester.pumpAndSettle();

      // One button, one file: the sign-in config and the coordinates both land.
      expect(store.storedAad?.clientId, 'nieuwe-client');
      expect(store.storedAad?.tenantId, 'nieuwe-tenant');
      expect(store.storedAad?.azureDomain, 'nieuw.example');
      expect(store.storedAad?.schoolPrefix, 'NWE');
      expect(store.stored?.cosmosDatabase, 'nieuw-db');

      expect(_note(tester, 'settings-aad-source'), contains('uit '));
      // The session is still running on the client id it started with, and says
      // so rather than pretending the change took effect.
      expect(
        find.byKey(const ValueKey('settings-connection-relaunch')),
        findsOneWidget,
      );
    });

    testWidgets(
        'a changed tenant drops the cached tokens; a changed client id '
        'does not', (WidgetTester tester) async {
      _useTallWindow(tester);
      var forgotten = 0;
      final store = InMemoryConnectionStore(
        stored: _stored,
        storedAad: _storedAad,
      );
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(
          store: store,
          forgetTokens: () async => forgotten++,
        ),
      )));
      await tester.pumpAndSettle();
      await _openTab(tester, 'settings-tab-verbinding');

      // Same tenant, different client: every cached token still has the right
      // audience, so dropping them would cost a browser round-trip for nothing.
      await _type(tester, 'settings-aad-client-id', 'andere-client');
      await tester.tap(find.byKey(const ValueKey('settings-connection-save')));
      await tester.pumpAndSettle();
      expect(forgotten, 0);

      // A different tenant means a different STS issued them for different
      // resources — they can only be rejected from here on.
      await _type(tester, 'settings-aad-tenant-id', 'andere-tenant');
      await tester.tap(find.byKey(const ValueKey('settings-connection-save')));
      await tester.pumpAndSettle();
      expect(forgotten, 1);
      expect(
        _note(tester, 'settings-connection-message'),
        contains('aanmeldingen zijn gewist'),
      );
    });

    testWidgets('"Standaardwaarden invullen" leaves the AAD fields alone',
        (WidgetTester tester) async {
      // The endpoints have real compiled defaults to restore; these four have
      // only the empty string, so restoring them would erase the one thing on
      // this tab the build cannot supply.
      _useTallWindow(tester);
      await tester.pumpWidget(_wrap(SettingsScreen(
        bootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(
          store: InMemoryConnectionStore(
            stored: _stored,
            storedAad: _storedAad,
          ),
        ),
      )));
      await tester.pumpAndSettle();
      await _openTab(tester, 'settings-tab-verbinding');

      await tester
          .tap(find.byKey(const ValueKey('settings-connection-defaults')));
      await tester.pumpAndSettle();

      expect(
        _text(tester, 'settings-connection-cosmos-endpoint'),
        StoreEndpoints.fromEnvironment().cosmosEndpoint,
      );
      expect(_text(tester, 'settings-aad-client-id'), _storedAad.clientId);
      expect(_text(tester, 'settings-aad-tenant-id'), _storedAad.tenantId);
    });

    group('a seed beside the program is named as such (#387)', () {
      testWidgets(
          'a fresh install shows the seeded values and says which file they '
          'came from', (WidgetTester tester) async {
        // The user-visible half of the issue: nothing has been typed on this
        // machine, and both sections are filled in from a file IT placed beside
        // the program. The source line has to name *that* file — "uit
        // connection.json" stopped being a complete sentence the moment two
        // files could be called that.
        _useTallWindow(tester);
        final store = _SeededStore();

        await tester.pumpWidget(_wrap(SettingsScreen(
          bootstrap: SettingsHarness().bootstrap,
          connection: ConnectionServices(store: store),
        )));
        await tester.pumpAndSettle();
        await _openTab(tester, 'settings-tab-verbinding');

        expect(
          _text(tester, 'settings-connection-cosmos-endpoint'),
          _stored.cosmosEndpoint,
        );
        expect(_text(tester, 'settings-aad-client-id'), _storedAad.clientId);

        // Both halves name the seed, and both say a save goes somewhere else.
        for (final String note in <String>[
          _note(tester, 'settings-connection-source'),
          _note(tester, 'settings-aad-source'),
        ]) {
          expect(note, contains(_SeededStore.seedPath));
          expect(note, contains(_SeededStore.localPath));
          expect(note, contains('naast het programma'));
        }

        // Configured from the seed alone, so the "you cannot sign in yet" line
        // is absent — the install needs no typing at all, which is the claim.
        expect(find.byKey(const ValueKey('settings-aad-incomplete')),
            findsNothing);
      });

      testWidgets(
          'a save goes to this machine\'s file, which the tab then names as '
          'the source over the seed', (WidgetTester tester) async {
        _useTallWindow(tester);
        final store = _SeededStore();

        await tester.pumpWidget(_wrap(SettingsScreen(
          bootstrap: SettingsHarness().bootstrap,
          connection: ConnectionServices(store: store),
        )));
        await tester.pumpAndSettle();
        await _openTab(tester, 'settings-tab-verbinding');

        await _type(tester, 'settings-connection-cosmos-database', 'eigen-db');
        await tester
            .tap(find.byKey(const ValueKey('settings-connection-save')));
        await tester.pumpAndSettle();

        // The correction is this machine's, and the message says where it went:
        // the seed is IT's, and the install directory it sits in is replaced
        // wholesale on the next upgrade.
        expect(store.wroteEndpoints?.cosmosDatabase, 'eigen-db');
        expect(
          _note(tester, 'settings-connection-message'),
          contains(_SeededStore.localPath),
        );

        // …and the tab now names the file that answers, while still saying the
        // seed is there and losing — the only place "I edited connection.json
        // and nothing changed" can be answered.
        final String note = _note(tester, 'settings-connection-source');
        expect(note, contains(_SeededStore.localPath));
        expect(note, contains(_SeededStore.seedPath));
        expect(note, contains('voorrang'));
      });

      testWidgets('a malformed seed warns on the tab instead of blanking it',
          (WidgetTester tester) async {
        // A file dropped beside the executable must be no more able to take the
        // tab down than one in %APPDATA%: the install that cannot render this
        // screen is the one that cannot be repaired.
        _useTallWindow(tester);
        final store = _SeededStore.broken();

        await tester.pumpWidget(_wrap(SettingsScreen(
          bootstrap: SettingsHarness().bootstrap,
          connection: ConnectionServices(store: store),
        )));
        await tester.pumpAndSettle();
        await _openTab(tester, 'settings-tab-verbinding');

        expect(
          _note(tester, 'settings-connection-warning'),
          contains(_SeededStore.seedPath),
        );
        // The fields still hold the build's own coordinates, so the tab is
        // usable rather than empty.
        expect(
          _text(tester, 'settings-connection-cosmos-endpoint'),
          StoreEndpoints.fromEnvironment().cosmosEndpoint,
        );
        expect(tester.takeException(), isNull);
      });
    });

    group('the screen opens with Azure AD unconfigured', () {
      testWidgets('the tab frame renders, Verbinding is in front, and it saves',
          (WidgetTester tester) async {
        // The failure this issue exists for. `bootstrap: null` is exactly what
        // `main()` passes when the resolved AadAppConfig has no client/tenant —
        // an installed v1.0.0, every time — and the screen used to answer it
        // with a bare "Niet geconfigureerd" panel telling the operator to pass
        // --dart-define values they can never pass. It has to render the tab
        // that fixes it instead.
        //
        // …and with a broken connection file at the same time, which is the
        // other half of the acceptance criterion: the two failures compound on a
        // fresh install and neither may take the tab down.
        _useTallWindow(tester);
        final store = _WarningStore();
        await tester.pumpWidget(_wrap(SettingsScreen(
          bootstrap: null,
          connection: ConnectionServices(store: store),
        )));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('settings-tabs')), findsOneWidget);
        expect(_selectedTab(tester), 4, reason: 'Verbinding is the last tab');
        expect(
          _note(tester, 'settings-connection-warning'),
          contains('kon niet gelezen worden'),
        );

        // Editable, and the save commits — a section that renders but cannot
        // write would leave the install exactly as stuck as before.
        await _type(tester, 'settings-aad-client-id', 'verse-client');
        await _type(tester, 'settings-aad-tenant-id', 'verse-tenant');
        await tester
            .tap(find.byKey(const ValueKey('settings-connection-save')));
        await tester.pumpAndSettle();

        expect(store.wroteAad?.clientId, 'verse-client');
        expect(store.wroteAad?.tenantId, 'verse-tenant');
        expect(store.wroteAad?.isConfigured, isTrue);
        // The endpoints ride along untouched, so the file is a complete answer.
        expect(
          store.wroteEndpoints?.cosmosEndpoint,
          StoreEndpoints.fromEnvironment().cosmosEndpoint,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('the document tabs say why and where to go, with no retry',
          (WidgetTester tester) async {
        _useTallWindow(tester);
        await tester.pumpWidget(_wrap(SettingsScreen(
          bootstrap: null,
          connection: ConnectionServices(store: InMemoryConnectionStore()),
        )));
        await tester.pumpAndSettle();

        await _openTab(tester, 'settings-tab-algemeen');
        expect(find.text('Niet geconfigureerd'), findsOneWidget);
        expect(find.textContaining('tabblad Verbinding'), findsOneWidget);
        // No retry button: nothing can be retried until the app is relaunched
        // against a saved app registration, and a dead button is worse than a
        // sentence.
        expect(find.byKey(const ValueKey('settings-retry')), findsNothing);

        // Both document-scoped header buttons are inert for the same reason.
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('settings-save')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('settings-reload')),
              )
              .onPressed,
          isNull,
        );
      });
    });
  });
}

/// The text a keyed [TextField] currently holds.
String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

/// The prose a keyed note renders.
String _note(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

Future<void> _type(WidgetTester tester, String key, String value) async {
  await tester.enterText(find.byKey(ValueKey(key)), value);
  await tester.pump();
}

/// The two-file resolution of #387, modelled: a read-only seed beside the
/// program answers until a save puts this machine's own `%APPDATA%` file over
/// it, and the seed's path stays reportable either way.
///
/// A fake rather than a real `FileConnectionStore` over two temp files, for a
/// mechanical reason: a widget test runs in fake async, where a real
/// `File.readAsString` never completes and `pumpAndSettle` times out before the
/// screen has any values. The real two-file layering is proved against real
/// files in `test/settings/connection_config_test.dart` and end to end in
/// `integration_test/app_launch_test.dart`; what this fake pins is the part only
/// the screen can get wrong — naming *which* of the two files answered.
class _SeededStore implements ConnectionStore {
  _SeededStore() : warning = '';

  /// The same store with an unreadable seed: nothing to resolve from, a warning
  /// to render, and the build's own values underneath.
  _SeededStore.broken()
      : warning = '$seedPath kon niet gelezen worden (FormatException). De '
            'standaardwaarden van deze build worden gebruikt.';

  /// Where a save goes — `%APPDATA%`, always.
  static const String localPath =
      r'C:\Users\test\AppData\Roaming\AccountManager'
      r'\connection.json';

  /// Where IT put the seed: the install directory.
  static const String seedPath =
      r'C:\Users\test\AppData\Local\Programs\AccountManager\connection.json';

  final String warning;

  StoreEndpoints? wroteEndpoints;
  AadAppConfig? wroteAad;

  bool get _broken => warning.isNotEmpty;

  @override
  String get location => localPath;

  @override
  Future<ResolvedConnection> read() async {
    final StoreEndpoints? saved = wroteEndpoints;
    final AadAppConfig? savedAad = wroteAad;
    final StoreEndpoints seeded =
        _broken ? StoreEndpoints.fromEnvironment() : _stored;
    final AadAppConfig seededAad =
        _broken ? AadAppConfig.fromEnvironment() : _storedAad;
    ConnectionSource sourceOf(bool saved) => saved
        ? ConnectionSource.file
        : _broken
            ? ConnectionSource.defaults
            : ConnectionSource.seed;
    return ResolvedConnection(
      endpoints: saved ?? seeded,
      source: sourceOf(saved != null),
      aad: savedAad ?? seededAad,
      aadSource: sourceOf(savedAad != null),
      // Reported whether it won or not: a seed that is being shadowed is exactly
      // the case the operator cannot otherwise explain.
      seedLocation: seedPath,
      warning: warning,
    );
  }

  @override
  Future<void> write({
    required StoreEndpoints endpoints,
    required AadAppConfig aad,
  }) async {
    wroteEndpoints = endpoints;
    wroteAad = aad;
  }
}

/// A store whose file is there but unreadable — the [ResolvedConnection.warning]
/// path, without depending on a real broken file on the test machine.
class _WarningStore implements ConnectionStore {
  _WarningStore();

  /// What a save put here, so a test can prove the tab still *writes* while the
  /// file it reads from is broken.
  StoreEndpoints? wroteEndpoints;
  AadAppConfig? wroteAad;

  @override
  String get location => connectionFileName;

  @override
  Future<ResolvedConnection> read() async => ResolvedConnection(
        endpoints: StoreEndpoints.fromEnvironment(),
        source: ConnectionSource.defaults,
        aad: AadAppConfig.fromEnvironment(),
        warning: '$connectionFileName kon niet gelezen worden '
            '(FormatException). De standaardwaarden van deze build worden '
            'gebruikt.',
      );

  @override
  Future<void> write({
    required StoreEndpoints endpoints,
    required AadAppConfig aad,
  }) async {
    wroteEndpoints = endpoints;
    wroteAad = aad;
  }
}

/// A [SettingsStore] that fails while [fails] says so and serves [inner]
/// afterwards.
class _FlakySettingsStore implements SettingsStore {
  _FlakySettingsStore(this.fails, this.inner);

  final bool Function() fails;
  final SettingsStore inner;

  @override
  Future<AppSettings> load() async {
    if (fails()) throw StateError('CosmosException(404 NotFound)');
    return inner.load();
  }

  @override
  Future<void> save(AppSettings settings) => inner.save(settings);
}
