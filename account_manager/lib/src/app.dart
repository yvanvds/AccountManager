import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import 'auth/aad_resource.dart';
import 'auth/sign_in_gate.dart';
import 'auth/sign_in_session.dart';
import 'reconcile/reconcile_bootstrap.dart';
import 'settings/connection_config.dart';
import 'settings/settings_bootstrap.dart';
import 'shell/app_shell.dart';
import 'update/update_controller.dart';

/// This app's per-product accent (Plink DS-5): one colour that is clearly
/// *not* the magenta spark, layered onto the paper/ink foundations. Arcadia
/// green.
const Color kProductAccent = Color(0xFF17796B);

/// Root of the Arcadia Account Manager desktop app.
///
/// Wraps the whole app in the Plink Labs design system: [PlinkTheme.paper] as
/// the light theme and [PlinkTheme.ink] as the dark theme, each carrying the
/// per-product accent. The UI itself is the [AppShell] — a navigation frame
/// that grows a destination per view as the Phase C slices land.
class AccountManagerApp extends StatelessWidget {
  const AccountManagerApp({
    super.key,
    required this.session,
    required this.graph,
    this.reconcileBootstrap,
    this.settingsBootstrap,
    this.connection,
    this.update,
  });

  /// The operator's Azure AD session, used by the sign-in gate and, later, by
  /// the connectors that carry its tokens.
  final SignInSession session;

  /// The Graph resource to sign in for, or `null` when AAD is not configured.
  final AadResource? graph;

  /// Assembles the reconcile stack when its screen is first opened, or `null`
  /// when AAD is not configured. Injectable so tests can bind the screen to
  /// fakes; the real closure is built in `main()`.
  final Future<ReconcileServices> Function()? reconcileBootstrap;

  /// Assembles the settings seams (store + secret provider) when the Settings
  /// screen is first opened, or `null` when AAD is not configured. Injectable so
  /// tests can bind the screen to fakes; the real closure is built in `main()`.
  final Future<SettingsServices> Function()? settingsBootstrap;

  /// Where this machine's backend coordinates are read and written (#370), and
  /// the reachability probe behind **Verbinding testen**.
  ///
  /// `null` binds the Verbinding section to an [InMemoryConnectionStore], which
  /// is what every test that does not care about it gets: a headless run then
  /// edits a throwaway copy instead of the operator's real `connection.json`.
  final ConnectionServices? connection;

  /// How this build finds out about newer published releases (#371), or `null`
  /// on a build (or a test) with no update mechanism at all.
  ///
  /// `null` is a real configuration rather than a test-only one: the Versie
  /// section still renders, saying the version is unknown and offering no
  /// check, which is exactly what a build with nowhere to update from should
  /// say.
  final UpdateServices? update;

  ThemeData _themed(ThemeData base) => base.copyWith(
        extensions: const <ThemeExtension<dynamic>>[
          PlinkProductAccent(kProductAccent),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arcadia Account Manager',
      debugShowCheckedModeBanner: false,
      theme: _themed(PlinkTheme.paper),
      darkTheme: _themed(PlinkTheme.ink),
      home: SignInGate(
        session: session,
        graph: graph,
        child: AppShell(
          reconcileBootstrap: reconcileBootstrap,
          settingsBootstrap: settingsBootstrap,
          connection: connection,
          update: update,
        ),
      ),
    );
  }
}
