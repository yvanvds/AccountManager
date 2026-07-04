/// The connection target for the centralized Azure Key Vault.
///
/// Phase B backs the [SecretProvider] seam with Key Vault (issue #84),
/// replacing the plaintext-in-config credentials the port removes
/// (PROJECT_OVERVIEW §6.2). This value type names *where* the vault lives — its
/// data-plane base URI — and nothing more. Like [CosmosConfig] it is
/// deliberately free of credentials: authentication is a separate seam
/// ([KeyVaultTokenProvider]), so the target can round-trip through settings or a
/// log line without leaking a secret.
///
/// The concrete vault name for this deployment is recorded in
/// `docs/port-plan.md` (`accountmanager-kv`), not hard-coded here, so the
/// library stays independent of any one environment.
class KeyVaultConfig {
  const KeyVaultConfig({required this.vaultUri});

  /// The vault data-plane base URI, e.g.
  /// `https://accountmanager-kv.vault.azure.net/`. A trailing slash is
  /// optional; the provider normalizes it when building request URLs.
  final String vaultUri;

  /// Serializes to a JSON-encodable map. Carries no secret, so it is safe to
  /// persist next to the rest of [AppSettings].
  Map<String, dynamic> toJson() => {'vaultUri': vaultUri};

  /// Reconstructs a [KeyVaultConfig] from a map produced by [toJson].
  factory KeyVaultConfig.fromJson(Map<String, dynamic> json) =>
      KeyVaultConfig(vaultUri: json['vaultUri'] as String);

  @override
  bool operator ==(Object other) =>
      other is KeyVaultConfig && other.vaultUri == vaultUri;

  @override
  int get hashCode => vaultUri.hashCode;

  @override
  String toString() => 'KeyVaultConfig($vaultUri)';
}
