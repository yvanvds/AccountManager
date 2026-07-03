import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'aad_broker.dart';
import 'aad_resource.dart';

/// [AadBroker] backed by the native Windows WAM broker over a [MethodChannel].
///
/// The native side (`windows/runner/aad_broker.cpp`) registers the
/// [channelName] channel and implements two methods, `acquireSilent` and
/// `acquireInteractive`, each taking `{clientId, authority, scopes, account?}`
/// and returning `{accessToken, expiresOn, account}`. On any failure it raises
/// a `PlatformException` whose `code` this maps onto [AadBrokerException].
class MethodChannelAadBroker implements AadBroker {
  MethodChannelAadBroker({
    required this.clientId,
    required this.authority,
    @visibleForTesting MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(channelName);

  /// The platform channel name shared with the native runner.
  static const String channelName = 'net.attr-x.arcadia/aad_broker';

  /// Application (client) id of the registered Azure AD app.
  final String clientId;

  /// The STS authority URL, e.g.
  /// `https://login.microsoftonline.com/<tenant>`.
  final String authority;

  final MethodChannel _channel;

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) =>
      _invoke('acquireSilent', resource, allowNull: true);

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) async {
    final token = await _invoke('acquireInteractive', resource);
    // Interactive never legitimately returns "no account"; _invoke only yields
    // null for a null map, which acquireInteractive's contract forbids.
    return token!;
  }

  Future<BrokerToken?> _invoke(
    String method,
    AadResource resource, {
    bool allowNull = false,
  }) async {
    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<Object?, Object?>(method, {
        'clientId': clientId,
        'authority': authority,
        'scopes': resource.scopes,
      });
    } on PlatformException catch (e) {
      // A `null` silent result is modelled as code `no_account`, not an error.
      if (allowNull && e.code == 'no_account') return null;
      throw AadBrokerException(
        e.message ?? 'broker call "$method" failed',
        code: e.code,
        cause: e,
      );
    } on MissingPluginException catch (e) {
      throw AadBrokerException(
        'the native token broker is not registered on this platform',
        code: 'broker_unavailable',
        cause: e,
      );
    }

    if (result == null) {
      if (allowNull) return null;
      throw AadBrokerException('broker call "$method" returned no token');
    }
    return _parse(result);
  }

  static BrokerToken _parse(Map<Object?, Object?> map) {
    final accessToken = map['accessToken'] as String?;
    final expiresOnMs = map['expiresOn'] as int?;
    if (accessToken == null || accessToken.isEmpty || expiresOnMs == null) {
      throw const AadBrokerException(
        'broker returned a malformed token payload',
        code: 'malformed_result',
      );
    }
    return BrokerToken(
      accessToken: accessToken,
      expiresOn: DateTime.fromMillisecondsSinceEpoch(expiresOnMs, isUtc: true),
      account: map['account'] as String?,
    );
  }
}
