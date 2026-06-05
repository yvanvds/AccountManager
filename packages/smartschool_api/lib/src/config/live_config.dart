import 'dart:io';

import 'package:account_core/account_core.dart' as core;

import '../connector.dart';

/// Two-variable configuration for talking to a live Smartschool tenant.
///
/// Used by both the capture script (`tool/capture_responses.dart`) and the
/// opt-in integration test (`test/integration/smartschool_live_test.dart`).
/// Offline unit tests never read this; they pass credentials in directly.
///
/// See `.smartschool.env.example` at the repository root for the variable
/// names.
class SmartschoolLiveConfig {
  final String site;
  final String accessCode;

  const SmartschoolLiveConfig({
    required this.site,
    required this.accessCode,
  });

  /// Names of the environment variables, in canonical order.
  static const List<String> envVarNames = [
    'SMARTSCHOOL_SITE',
    'SMARTSCHOOL_ACCESSCODE',
  ];

  /// Reads config from environment variables (defaulting to
  /// `Platform.environment`). Returns `null` when `SMARTSCHOOL_ACCESSCODE`
  /// is empty or missing — the integration test uses this as its skip
  /// signal, so `dart test` stays offline by default.
  ///
  /// Throws [ArgumentError] when `SMARTSCHOOL_ACCESSCODE` is set but
  /// `SMARTSCHOOL_SITE` is missing/empty.
  static SmartschoolLiveConfig? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final accessCode = (source['SMARTSCHOOL_ACCESSCODE'] ?? '').trim();
    if (accessCode.isEmpty) return null;

    final site = (source['SMARTSCHOOL_SITE'] ?? '').trim();
    if (site.isEmpty) {
      throw ArgumentError(
        'SMARTSCHOOL_ACCESSCODE is set but SMARTSCHOOL_SITE is missing or '
        'empty.',
      );
    }

    return SmartschoolLiveConfig(site: site, accessCode: accessCode);
  }

  /// Builds a connector from this config. Uses the default HTTP transport
  /// unless [log] is provided to capture diagnostics.
  SmartschoolConnector connector({core.ILog? log}) =>
      SmartschoolConnector.fromParts(
        site: site,
        accessCode: accessCode,
        log: log,
      );
}
