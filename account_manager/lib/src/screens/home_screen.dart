import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

/// The landing screen of the shell.
///
/// A placeholder for now: it confirms the app is alive, wrapped in the Plink
/// theme, and names the views that later Phase C slices will wire in. It is
/// intentionally content-light — the real work lands on the reconcile screen.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(PlinkSpacing.s6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // The operator's language, like every other screen (#265): Start
              // is the first thing they land on, so it cannot be the one page
              // that greets them in English.
              Eyebrow('Arcadia · accountsynchronisatie', onInk: ink),
              const SizedBox(height: PlinkSpacing.s4),
              Text('Account Manager', style: text.displaySmall),
              const SizedBox(height: PlinkSpacing.s4),
              Text(
                'Stemt gebruikersaccounts en klasgroepen op elkaar af tussen '
                'WISA, Smartschool en Azure AD / Office 365. De schermen '
                'worden stap voor stap toegevoegd — te beginnen met aanmelden '
                'en het tabblad Synchronisatie.',
                style: text.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
