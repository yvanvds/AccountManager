import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/auth/aad_app_config.dart';
import 'src/auth/method_channel_aad_broker.dart';
import 'src/auth/sign_in_session.dart';

void main() {
  // Azure AD app-registration values come from --dart-define (see
  // AadAppConfig); an unconfigured build still launches, gated into a
  // "not configured" state rather than a failed sign-in.
  final config = AadAppConfig.fromEnvironment();
  final broker = MethodChannelAadBroker(
    clientId: config.clientId,
    authority: config.authority,
  );
  final session = SignInSession(broker);

  runApp(
    AccountManagerApp(
      session: session,
      graph: config.isConfigured ? config.graph : null,
    ),
  );
}
