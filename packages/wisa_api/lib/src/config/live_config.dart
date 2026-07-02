import 'dart:io';

import 'package:account_core/account_core.dart' as core;

import '../connector.dart';

/// Six-variable configuration for talking to a live WISA host, plus the
/// optional `WISA_WERKDATUM` override for the export Werkdatum.
///
/// Used by both the capture script (`tool/capture_responses.dart`) and
/// the opt-in integration test (`test/integration/wisa_live_test.dart`).
/// Offline unit tests never read this; they pass credentials in directly.
///
/// See `.wisa.env.example` at the repository root for the variable names.
class WisaLiveConfig {
  final String server;
  final int port;
  final String database;
  final String username;
  final String password;
  final int schoolId;

  /// Explicit Werkdatum for the export, from `WISA_WERKDATUM`. `null`
  /// when the variable is unset; use [resolveWorkDate] to fall back to
  /// the end-of-school-year default.
  final DateTime? workDate;

  const WisaLiveConfig({
    required this.server,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.schoolId,
    this.workDate,
  });

  /// Names of the six environment variables, in canonical order.
  static const List<String> envVarNames = [
    'WISA_SERVER',
    'WISA_PORT',
    'WISA_DATABASE',
    'WISA_USERNAME',
    'WISA_PASSWORD',
    'WISA_SCHOOL_ID',
  ];

  /// Reads config from environment variables (defaulting to
  /// `Platform.environment`). Returns `null` when `WISA_USERNAME` is
  /// empty or missing — the integration test uses this as its skip
  /// signal, so `dart test` stays offline by default.
  ///
  /// Throws [ArgumentError] when `WISA_USERNAME` is set but one of the
  /// other five variables is missing/empty, a numeric variable cannot
  /// be parsed, or `WISA_WERKDATUM` is set but not an ISO-8601 date.
  static WisaLiveConfig? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final username = (source['WISA_USERNAME'] ?? '').trim();
    if (username.isEmpty) return null;

    final missing = <String>[
      for (final name in const [
        'WISA_SERVER',
        'WISA_PORT',
        'WISA_DATABASE',
        'WISA_PASSWORD',
        'WISA_SCHOOL_ID',
      ])
        if ((source[name] ?? '').trim().isEmpty) name,
    ];
    if (missing.isNotEmpty) {
      throw ArgumentError(
        'WISA_USERNAME is set but the following env vars are missing or '
        'empty: ${missing.join(', ')}',
      );
    }

    final portRaw = source['WISA_PORT']!.trim();
    final port = int.tryParse(portRaw);
    if (port == null) {
      throw ArgumentError('WISA_PORT is not an integer: "$portRaw"');
    }
    final schoolIdRaw = source['WISA_SCHOOL_ID']!.trim();
    final schoolId = int.tryParse(schoolIdRaw);
    if (schoolId == null) {
      throw ArgumentError(
        'WISA_SCHOOL_ID is not an integer: "$schoolIdRaw"',
      );
    }

    DateTime? workDate;
    final workDateRaw = (source['WISA_WERKDATUM'] ?? '').trim();
    if (workDateRaw.isNotEmpty) {
      workDate = DateTime.tryParse(workDateRaw);
      if (workDate == null) {
        throw ArgumentError(
          'WISA_WERKDATUM is not an ISO-8601 date: "$workDateRaw"',
        );
      }
    }

    return WisaLiveConfig(
      server: source['WISA_SERVER']!.trim(),
      port: port,
      database: source['WISA_DATABASE']!.trim(),
      username: username,
      password: source['WISA_PASSWORD']!.trim(),
      schoolId: schoolId,
      workDate: workDate,
    );
  }

  /// The Werkdatum the live test should use: the explicit [workDate]
  /// when `WISA_WERKDATUM` was set, otherwise 30 June of [now]'s year —
  /// the end of the Belgian school year, so the export has enrolled
  /// students regardless of the calendar date (issue #57: `DateTime.now()`
  /// yields an empty export all summer).
  DateTime resolveWorkDate(DateTime now) =>
      workDate ?? DateTime(now.year, 6, 30);

  /// Builds a connector from this config. The connector uses the default
  /// HTTP transport unless [log] is provided to capture diagnostics.
  WisaConnector connector({core.ILog? log}) => WisaConnector.fromParts(
        server: server,
        port: port,
        database: database,
        username: username,
        password: password,
        log: log,
      );
}
