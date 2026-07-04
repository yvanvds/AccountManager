import 'package:account_manager/src/auth/auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MethodChannelAadBroker.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const cosmos = AadResource.cosmos;

  MethodChannelAadBroker brokerUnderTest() => MethodChannelAadBroker(
        clientId: 'client-123',
        authority: 'https://login.microsoftonline.com/tenant-abc',
        channel: channel,
      );

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('forwards clientId, authority and scopes to the native method',
      () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return <String, Object?>{
        'accessToken': 'AT',
        'expiresOn': DateTime.utc(2030).millisecondsSinceEpoch,
        'account': 'op@school.example',
      };
    });

    final result = await brokerUnderTest().acquireSilent(cosmos);

    expect(seen!.method, 'acquireSilent');
    final args = seen!.arguments as Map;
    expect(args['clientId'], 'client-123');
    expect(args['authority'], 'https://login.microsoftonline.com/tenant-abc');
    expect(args['scopes'], ['https://cosmos.azure.com/.default']);
    expect(result!.accessToken, 'AT');
    expect(result.account, 'op@school.example');
    expect(result.expiresOn, DateTime.utc(2030));
  });

  test('maps the no_account PlatformException to a null silent result',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'no_account', message: 'nothing cached');
    });

    expect(await brokerUnderTest().acquireSilent(cosmos), isNull);
  });

  test('surfaces other PlatformExceptions as AadBrokerException with the code',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'user_cancelled', message: 'dismissed');
    });

    await expectLater(
      brokerUnderTest().acquireInteractive(cosmos),
      throwsA(
        isA<AadBrokerException>()
            .having((e) => e.code, 'code', 'user_cancelled')
            .having((e) => e.isUserCancelled, 'isUserCancelled', isTrue),
      ),
    );
  });

  test('maps a missing native plugin to broker_unavailable', () async {
    // No handler registered → MissingPluginException.
    await expectLater(
      brokerUnderTest().acquireSilent(cosmos),
      throwsA(
        isA<AadBrokerException>()
            .having((e) => e.isBrokerUnavailable, 'isBrokerUnavailable', true),
      ),
    );
  });

  test('rejects a malformed token payload', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{'account': 'op@school.example'}; // no token
    });

    await expectLater(
      brokerUnderTest().acquireInteractive(cosmos),
      throwsA(isA<AadBrokerException>()
          .having((e) => e.code, 'code', 'malformed_result')),
    );
  });
}
