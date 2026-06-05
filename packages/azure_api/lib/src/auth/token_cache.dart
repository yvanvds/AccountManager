/// Persists the serialized OAuth credentials (access + refresh token) between
/// runs, so a returning user is not prompted to sign in every time.
///
/// The stored payload is opaque to this package (it is whatever
/// [oauth2.Credentials.toJson] produced). **It contains a refresh token and
/// must be encrypted at rest.** The legacy connector used Windows DPAPI
/// (`TokenCacheHelper.cs`); in the port, the Flutter app supplies a
/// `flutter_secure_storage`-backed implementation (DPAPI on Windows), or wraps
/// any [TokenCache] in an [EncryptedTokenCache]. The package itself never
/// writes the cache to disk in plaintext.
abstract interface class TokenCache {
  /// Returns the stored payload, or `null` if nothing is cached.
  Future<String?> read();

  /// Stores [data], replacing any previous payload.
  Future<void> write(String data);

  /// Removes the stored payload (e.g. on sign-out or unrecoverable refresh
  /// failure).
  Future<void> clear();
}

/// In-memory cache. Holds nothing across process restarts — used by tests and
/// as a safe default when no persistent, encrypted cache has been wired up.
class InMemoryTokenCache implements TokenCache {
  String? _data;

  @override
  Future<String?> read() async => _data;

  @override
  Future<void> write(String data) async => _data = data;

  @override
  Future<void> clear() async => _data = null;
}

/// Transforms applied to the cache payload at rest. The real app supplies a
/// platform cipher (DPAPI / secure-storage); tests supply a reversible
/// transform to exercise the round-trip.
typedef TokenEncrypt = String Function(String plaintext);
typedef TokenDecrypt = String Function(String ciphertext);

/// Wraps another [TokenCache], encrypting on write and decrypting on read.
///
/// This is how the package keeps the cache "encrypted at rest" without baking
/// in a platform crypto dependency: the cipher is injected. The inner cache
/// only ever sees ciphertext.
class EncryptedTokenCache implements TokenCache {
  final TokenCache _inner;
  final TokenEncrypt _encrypt;
  final TokenDecrypt _decrypt;

  EncryptedTokenCache({
    required TokenCache inner,
    required TokenEncrypt encrypt,
    required TokenDecrypt decrypt,
  })  : _inner = inner,
        _encrypt = encrypt,
        _decrypt = decrypt;

  @override
  Future<String?> read() async {
    final stored = await _inner.read();
    if (stored == null) return null;
    return _decrypt(stored);
  }

  @override
  Future<void> write(String data) => _inner.write(_encrypt(data));

  @override
  Future<void> clear() => _inner.clear();
}
