import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

void main() {
  group('GraphResponse', () {
    test('json decodes an object body', () {
      const resp = GraphResponse(statusCode: 200, body: '{"a":1}');
      expect(resp.json['a'], 1);
      expect(resp.isSuccess, isTrue);
    });

    test('json on an empty body (204) is an empty map', () {
      expect(const GraphResponse(statusCode: 204).json, isEmpty);
    });

    test('json throws when the body is not a JSON object', () {
      expect(
        () => const GraphResponse(statusCode: 200, body: '[]').json,
        throwsFormatException,
      );
    });
  });

  group('GraphException', () {
    test('exposes Graph error code/message and renders them', () {
      const ex = GraphException(
        403,
        '{"error":{"code":"Forbidden","message":"no access"}}',
      );
      expect(ex.code, 'Forbidden');
      expect(ex.message, 'no access');
      expect(ex.toString(), contains('Forbidden'));
      expect(ex.toString(), contains('no access'));
    });

    test('tolerates a non-JSON error body', () {
      const ex = GraphException(500, 'Internal Server Error');
      expect(ex.code, isNull);
      expect(ex.message, isNull);
      expect(ex.toString(), contains('Internal Server Error'));
    });

    group('isResourceNotFound (#356)', () {
      GraphException notFoundWith(String code) => GraphException(
            404,
            '{"error":{"code":"$code","message":"Resource does not exist or '
            'one of its queried reference-property objects are not present."}}',
          );

      test('true for a 404 naming Request_ResourceNotFound', () {
        expect(notFoundWith('Request_ResourceNotFound').isResourceNotFound,
            isTrue);
      });

      test('the code match is case-insensitive', () {
        expect(notFoundWith('request_resourcenotfound').isResourceNotFound,
            isTrue);
      });

      test('false for a 404 carrying any other code', () {
        // Graph's directory "gone" code is the whole test: a 404 about a path
        // it does not serve is a different fault and must stay loud.
        expect(notFoundWith('Request_BadRequest').isResourceNotFound, isFalse);
        expect(notFoundWith('UnknownError').isResourceNotFound, isFalse);
      });

      test('false for a 404 with no Graph error envelope at all', () {
        // A proxy or gateway in front of Graph answers like this; it says
        // nothing about whether the object exists.
        const ex = GraphException(404, '<html>Not Found</html>');
        expect(ex.code, isNull);
        expect(ex.isResourceNotFound, isFalse);
      });

      test('false for every other status, including with the same code', () {
        // The failures the tolerance must never swallow: an expired token, a
        // refusal, throttling, an outage.
        for (final status in [401, 403, 410, 429, 500, 503]) {
          expect(
            GraphException(
              status,
              '{"error":{"code":"Request_ResourceNotFound","message":"x"}}',
            ).isResourceNotFound,
            isFalse,
            reason: '$status is not "the object is gone"',
          );
        }
      });

      test('is not confused with a rejected delta token', () {
        final ex = notFoundWith('Request_ResourceNotFound');
        expect(ex.isRejectedDeltaToken, isFalse);
      });
    });
  });
}
