import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import 'shell/app_shell.dart';

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
  const AccountManagerApp({super.key});

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
      home: const AppShell(),
    );
  }
}
