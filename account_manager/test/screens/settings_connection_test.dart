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
      connection: const ConnectionServices(store: _WarningStore()),
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
}

/// A store whose file is there but unreadable — the [ResolvedConnection.warning]
/// path, without depending on a real broken file on the test machine.
class _WarningStore implements ConnectionStore {
  const _WarningStore();

  @override
  String get location => connectionFileName;

  @override
  Future<ResolvedConnection> read() async => ResolvedConnection(
        endpoints: StoreEndpoints.fromEnvironment(),
        source: ConnectionSource.defaults,
        warning: '$connectionFileName kon niet gelezen worden '
            '(FormatException). De standaardwaarden van deze build worden '
            'gebruikt.',
      );

  @override
  Future<void> write(StoreEndpoints endpoints) async {}
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
