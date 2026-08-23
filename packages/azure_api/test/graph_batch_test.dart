import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

/// A refused sub-request the way Graph answers one inside a `$batch`: the
/// status, and the same `error` envelope a single call would have carried.
BatchResponse refused(
  String id, {
  int status = 400,
  String code = 'Request_BadRequest',
  String message = 'Adding members is not supported for this group.',
}) =>
    BatchResponse(
      id: id,
      status: status,
      body: <String, dynamic>{
        'error': <String, dynamic>{'code': code, 'message': message},
      },
    );

BatchResponse ok(String id) => BatchResponse(id: id, status: 204);

void main() {
  group('BatchResponse carries Graph\'s reason (#330)', () {
    test('status, error code and message read as one line', () {
      final r = refused(
        '0',
        status: 403,
        code: 'Authorization_RequestDenied',
        message: 'Insufficient privileges to complete the operation.',
      );
      expect(r.errorCode, 'Authorization_RequestDenied');
      expect(
          r.errorMessage,
          'Insufficient privileges to complete the '
          'operation.');
      expect(
        r.reason,
        '403 Authorization_RequestDenied: Insufficient privileges to '
        'complete the operation.',
      );
    });

    test('a refusal with no envelope still reports its status', () {
      // Nothing to quote, but the number is what an operator searches on.
      expect(const BatchResponse(id: '0', status: 429).reason, '429');
    });

    test('a body that is not a Graph error envelope is not mistaken for one',
        () {
      const r = BatchResponse(
        id: '0',
        status: 400,
        body: <String, dynamic>{'error': 'nope'},
      );
      expect(r.errorCode, isNull);
      expect(r.reason, '400');
    });
  });

  group('BatchReport (#330)', () {
    test('counts both halves of a partly refused batch', () {
      final report = BatchReport([ok('0'), refused('1'), ok('2')]);
      expect(report.total, 3);
      expect(report.failureCount, 1);
      expect(report.successCount, 2);
      expect(report.hasFailures, isTrue);
    });

    test('an all-success batch has nothing to report', () {
      final report = BatchReport([ok('0'), ok('1')]);
      expect(report.hasFailures, isFalse);
      expect(report.reasons, isEmpty);
      expect(report.failureLines(), isEmpty);
    });

    test('a wholesale refusal collapses to the one reason Graph gave', () {
      // The #331 shape: every sub-request refused for the same reason, which
      // must not read as 38 different problems.
      final report = BatchReport([
        for (var i = 0; i < 38; i++) refused('$i'),
      ]);
      expect(report.reasons, hasLength(1));
      expect(
        report.reasons.single,
        '400 Request_BadRequest: Adding members is not supported for this '
        'group.',
      );
    });

    test('mixed failures keep every distinct reason, in order', () {
      final report = BatchReport([
        ok('0'),
        refused('1',
            status: 404,
            code: 'Request_ResourceNotFound',
            message: 'Resource does not exist.'),
        refused('2'),
        refused('3',
            status: 404,
            code: 'Request_ResourceNotFound',
            message: 'Resource does not exist.'),
      ]);
      expect(report.reasons, [
        '404 Request_ResourceNotFound: Resource does not exist.',
        '400 Request_BadRequest: Adding members is not supported for this '
            'group.',
      ]);
    });

    test('failure lines name the member, not the sub-request index', () {
      final report = BatchReport([ok('0'), refused('1'), refused('2')]);
      expect(
        report.failureLines(
            labels: const {'0': 'az-a', '1': 'az-b', '2': 'az-c'}),
        [
          'az-b → 400 Request_BadRequest: Adding members is not supported '
              'for this group.',
          'az-c → 400 Request_BadRequest: Adding members is not supported '
              'for this group.',
        ],
        reason: 'only the refusals, and traceable to the accounts they hit',
      );
    });

    test('an unlabelled sub-request stands for itself', () {
      expect(
        BatchReport([refused('7')]).failureLines().single,
        startsWith('7 → 400 Request_BadRequest'),
      );
    });
  });
}
