/// The secret-resolution seam for the config model.
///
/// The legacy `config.json` stored the WISA password and the Smartschool
/// passphrase in cleartext next to the rest of the settings (PROJECT_OVERVIEW
/// §6.2). The port deliberately breaks that: [AppSettings] and its connection
/// profiles never carry a secret **value**, only a [SecretRef] naming where the
/// secret lives. Resolving a ref to its value goes through this interface, so
/// the settings blob on disk stays free of credentials.
///
/// A [SecretRef] is just a stable string key. In Phase A it names an entry in
/// an [InMemorySecretProvider]; in Phase B the same ref names a Key Vault
/// secret and only the provider implementation changes. Nothing above the seam
/// has to know which.
library;

/// A stable pointer to a secret value, safe to serialize.
///
/// Wraps the key ([name]) under which a secret is stored — e.g.
/// `wisa.password`, `smartschool.passphrase`, or in Phase B a Key Vault secret
/// name. The ref itself is not sensitive and round-trips through the settings
/// blob; the value it points at never does.
class SecretRef {
  const SecretRef(this.name);

  /// The storage key. For an [InMemorySecretProvider] this is the map key; for
  /// a Key-Vault-backed provider it is the vault secret name.
  final String name;

  @override
  bool operator ==(Object other) => other is SecretRef && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'SecretRef($name)';
}

/// Resolves and mutates secret values behind a [SecretRef].
///
/// Injected into the orchestration layer the same way [SettingsStore] and
/// `PersonIdResolver` are: production wires a Key-Vault-backed implementation
/// (Phase B), tests and headless runs use [InMemorySecretProvider]. Connect
/// time reads a secret with [read]; the Settings UI persists an operator-typed
/// credential with [write] and clears it with [delete].
abstract interface class SecretProvider {
  /// Returns the value stored under [ref], or `null` when nothing is stored —
  /// so an unconfigured credential is a plain `null`, not an error.
  Future<String?> read(SecretRef ref);

  /// Stores [value] under [ref], replacing any previous value.
  Future<void> write(SecretRef ref, String value);

  /// Removes any value stored under [ref]. A no-op when nothing is stored.
  Future<void> delete(SecretRef ref);
}

/// An in-memory [SecretProvider] holding secrets in a map.
///
/// The default for headless tests and first-run before a Key Vault is wired:
/// zero infra, nothing touches disk. Seed it with an initial map to simulate
/// already-provisioned credentials.
class InMemorySecretProvider implements SecretProvider {
  InMemorySecretProvider([Map<SecretRef, String> initial = const {}])
      : _secrets = {...initial};

  final Map<SecretRef, String> _secrets;

  @override
  Future<String?> read(SecretRef ref) async => _secrets[ref];

  @override
  Future<void> write(SecretRef ref, String value) async =>
      _secrets[ref] = value;

  @override
  Future<void> delete(SecretRef ref) async => _secrets.remove(ref);
}
