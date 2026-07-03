import 'dart:io';

import 'package:azure_api/azure_api.dart' show TokenCache;

/// A [TokenCache] backed by one file, so the loopback sign-in survives app
/// restarts (#103). Store only ciphertext here — wrap it in azure_api's
/// `EncryptedTokenCache` with the DPAPI cipher; this class never sees (or
/// writes) a plaintext refresh token.
class FileTokenCache implements TokenCache {
  FileTokenCache(String path) : _file = File(path);

  final File _file;

  @override
  Future<String?> read() async {
    try {
      if (!await _file.exists()) return null;
      final data = await _file.readAsString();
      return data.isEmpty ? null : data;
    } on FileSystemException {
      // Unreadable cache = no cache; the caller falls back to interactive.
      return null;
    }
  }

  @override
  Future<void> write(String data) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(data, flush: true);
  }

  @override
  Future<void> clear() async {
    try {
      if (await _file.exists()) await _file.delete();
    } on FileSystemException {
      // Best effort: a locked file just means a stale cache lingers.
    }
  }
}
