/// Windows DPAPI (`CryptProtectData` / `CryptUnprotectData`) over `dart:ffi`,
/// used to encrypt the persisted OAuth token cache at rest (#103).
///
/// DPAPI ties the ciphertext to the signed-in Windows user, so the cached
/// refresh token can only be read back by the operator who wrote it, on this
/// machine — the same mechanism the legacy connector used
/// (`TokenCacheHelper.cs`). No key management: Windows owns the key.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// `DATA_BLOB` from `dpapi.h`: a length + byte-pointer pair.
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptDataNative = Int32 Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> promptStruct,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _CryptData = int Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> promptStruct,
  int flags,
  Pointer<_DataBlob> dataOut,
);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> mem);

/// Never show a DPAPI UI prompt; fail instead (`CRYPTPROTECT_UI_FORBIDDEN`).
const int _uiForbidden = 0x1;

final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final _CryptData _protectData =
    _crypt32.lookupFunction<_CryptDataNative, _CryptData>('CryptProtectData');
final _CryptData _unprotectData =
    _crypt32.lookupFunction<_CryptDataNative, _CryptData>('CryptUnprotectData');
final _LocalFreeNative _localFree =
    _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeNative>('LocalFree');

/// User-scoped DPAPI as the [EncryptedTokenCache] cipher pair: [protect] maps
/// plaintext to base64 ciphertext, [unprotect] back. [unprotect] throws
/// [FormatException] when the payload cannot be decrypted (tampered, another
/// user's, or another machine's) — the exact signal `OAuthAuthProvider` treats
/// as a corrupt cache, discarding it and falling back to interactive sign-in.
abstract final class Dpapi {
  static String protect(String plaintext) =>
      base64Encode(_transform(_protectData, utf8.encode(plaintext), 'protect'));

  static String unprotect(String ciphertext) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(ciphertext);
    } on FormatException {
      throw const FormatException('token cache is not valid base64');
    }
    return utf8.decode(_transform(_unprotectData, bytes, 'unprotect'));
  }

  static Uint8List _transform(_CryptData fn, List<int> input, String op) {
    final inData = malloc<_DataBlob>();
    final outData = malloc<_DataBlob>();
    final inBytes = malloc<Uint8>(input.length);
    try {
      inBytes.asTypedList(input.length).setAll(0, input);
      inData.ref
        ..cbData = input.length
        ..pbData = inBytes;
      outData.ref
        ..cbData = 0
        ..pbData = nullptr;

      final ok = fn(
        inData,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        outData,
      );
      if (ok == 0) {
        throw FormatException('DPAPI $op failed');
      }
      try {
        return Uint8List.fromList(
          outData.ref.pbData.asTypedList(outData.ref.cbData),
        );
      } finally {
        _localFree(outData.ref.pbData.cast());
      }
    } finally {
      malloc.free(inBytes);
      malloc.free(inData);
      malloc.free(outData);
    }
  }
}
