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
  });
}
