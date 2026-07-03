/// The connection target for the centralized Azure SQL database.
///
/// Phase B moves the shared state off per-operator files (`FileSettingsStore`,
/// `FilePersonIdResolver`, `FilePasswordQueueStore`) into one Azure SQL
/// database (epic #74). This value type names *where* that database lives —
/// the server host and catalog — and nothing more. It is deliberately free of
/// credentials: authentication is a separate seam ([AadTokenProvider]), so the
/// target can round-trip through settings or a log line without leaking a
/// secret (the same discipline `SecretRef` applies to the config blob).
///
/// The concrete server/catalog names for this deployment are recorded in
/// `docs/port-plan.md`, not hard-coded here, so the library stays independent
/// of any one environment.
class AzureSqlConfig {
  const AzureSqlConfig({required this.server, required this.database});

  /// The fully-qualified server host, e.g.
  /// `accountmanager-sql-arcadia.database.windows.net`.
  final String server;

  /// The database (catalog) name on [server], e.g. `accountmanager`.
  final String database;

  /// Serializes to a JSON-encodable map. Carries no secret, so it is safe to
  /// persist next to the rest of [AppSettings].
  Map<String, dynamic> toJson() => {'server': server, 'database': database};

  /// Reconstructs an [AzureSqlConfig] from a map produced by [toJson].
  factory AzureSqlConfig.fromJson(Map<String, dynamic> json) => AzureSqlConfig(
        server: json['server'] as String,
        database: json['database'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is AzureSqlConfig &&
      other.server == server &&
      other.database == database;

  @override
  int get hashCode => Object.hash(server, database);

  @override
  String toString() => 'AzureSqlConfig($server/$database)';
}
