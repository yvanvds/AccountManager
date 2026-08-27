import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import 'aad_broker.dart';
import 'aad_resource.dart';
import 'sign_in_session.dart';

/// Gates the app behind a completed Azure AD sign-in.
///
/// On first build it acquires a Graph token from [session] — silently on a
/// school-account machine (no prompt), interactively otherwise. While that runs
/// it shows a signing-in panel; on success it reveals [child]; on failure it
/// shows the error with a Retry. This is the app's single sign-in entry point:
/// once Graph is signed in, the Azure SQL token is acquired silently on demand
/// by the connectors, so the operator signs in once.
///
/// When AAD is not configured ([graph] is `null`), the gate reveals [child]
/// directly rather than blocking on an acquisition it has no app registration
/// to make. That is not a courtesy: since #384 the app registration itself is
/// configured in Instellingen → Verbinding → Azure AD, so gating the shell
/// behind sign-in would put the screen that fixes sign-in behind sign-in. Every
/// screen that does need a token says so and points at that tab.
class SignInGate extends StatefulWidget {
  const SignInGate({
    super.key,
    required this.session,
    required this.graph,
    required this.child,
  });

  final SignInSession session;

  /// The Graph resource to acquire, or `null` when AAD is not configured.
  final AadResource? graph;

  final Widget child;

  @override
  State<SignInGate> createState() => _SignInGateState();
}

enum _Phase { signingIn, signedIn, notConfigured, failed }

class _SignInGateState extends State<SignInGate> {
  _Phase _phase = _Phase.signingIn;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.graph == null) {
      _phase = _Phase.notConfigured;
    } else {
      _signIn();
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _phase = _Phase.signingIn;
      _error = null;
    });
    try {
      await widget.session.tokenFor(widget.graph!);
      if (mounted) setState(() => _phase = _Phase.signedIn);
    } on AadBrokerException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error =
              e.isUserCancelled ? 'Het aanmelden is geannuleerd.' : e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.signedIn:
      case _Phase.notConfigured:
        return widget.child;
      case _Phase.signingIn:
        return _SignInScaffold(
          key: const ValueKey('signing-in'),
          child: _SigningInPanel(),
        );
      case _Phase.failed:
        return _SignInScaffold(
          key: const ValueKey('sign-in-failed'),
          child: _SignInFailedPanel(
              message: _error ?? 'Het aanmelden is mislukt.', onRetry: _signIn),
        );
    }
  }
}

/// Centres a sign-in panel on the product-themed surface, with the identity
/// rule across the top so the gate reads as part of the same app as the shell.
class _SignInScaffold extends StatelessWidget {
  const _SignInScaffold({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          const PlinkIdentityRule(),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(PlinkSpacing.s6),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SigningInPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · office 365', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        Text('Aanmelden…', style: text.headlineSmall),
        const SizedBox(height: PlinkSpacing.s4),
        Text(
          'Verbinden met Azure AD via je schoolaccount. Mogelijk opent er een '
          'browservenster om je aan te melden — rond het daar af en kom hier '
          'terug.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: PlinkSpacing.s5),
        const LinearProgressIndicator(),
      ],
    );
  }
}

class _SignInFailedPanel extends StatelessWidget {
  const _SignInFailedPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · aanmelden mislukt', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        Text('Kon je niet aanmelden', style: text.headlineSmall),
        const SizedBox(height: PlinkSpacing.s4),
        Text(message, style: text.bodyMedium),
        const SizedBox(height: PlinkSpacing.s5),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: onRetry,
            child: const Text('Probeer opnieuw'),
          ),
        ),
      ],
    );
  }
}
