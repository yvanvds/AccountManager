import 'graph_client.dart';

/// One entry in a Graph `$batch` request. [url] is relative to the Graph
/// version root (e.g. `/groups/{id}/members/$ref`), as `$batch` requires.
class BatchRequest {
  final String id;
  final String method;
  final String url;
  final Map<String, String>? headers;
  final Object? body;

  const BatchRequest({
    required this.id,
    required this.method,
    required this.url,
    this.headers,
    this.body,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'method': method,
        'url': url,
        if (headers != null && headers!.isNotEmpty) 'headers': headers,
        if (body != null) 'body': body,
      };
}

/// One result from a Graph `$batch` response.
class BatchResponse {
  final String id;
  final int status;

  /// The sub-response body, when Graph sent a JSON object — for a refusal, the
  /// standard `{"error": {"code": …, "message": …}}` envelope. `null` for the
  /// bodiless `204`s a membership write answers with, and for the rare
  /// non-object body (Graph base64-encodes binary sub-responses), which is
  /// dropped rather than crashing the parse: a refusal whose envelope we cannot
  /// read is still reported by [reason], on its status alone.
  final Map<String, dynamic>? body;

  const BatchResponse({required this.id, required this.status, this.body});

  bool get isSuccess => status >= 200 && status < 300;

  Map<String, dynamic>? get _error {
    final error = body?['error'];
    return error is Map<String, dynamic> ? error : null;
  }

  /// Graph's `error.code` for a refused sub-request, when it sent one.
  String? get errorCode => _error?['code'] as String?;

  /// Graph's `error.message` for a refused sub-request, when it sent one.
  String? get errorMessage => _error?['message'] as String?;

  /// What Graph said, as one line — `403 Authorization_RequestDenied:
  /// Insufficient privileges to complete the operation.` (#330).
  ///
  /// The status is always there, because a refusal with no envelope is still a
  /// refusal and the number is the part an operator can search on.
  String get reason {
    final buffer = StringBuffer('$status');
    final code = errorCode;
    if (code != null && code.isNotEmpty) buffer.write(' $code');
    final message = errorMessage;
    if (message != null && message.isNotEmpty) buffer.write(': $message');
    return buffer.toString();
  }
}

/// What a `$batch` run did, in the words an operator needs (#330).
///
/// Graph answers a batch **per sub-request**, so a batch can half-succeed and no
/// layer above can tell without walking the list. Both callers used to walk it
/// badly: the connector not at all — it logged an unconditional
/// *"N leden in batch toegevoegd"* even when every sub-request had been refused
/// — and the action only to count, discarding [BatchResponse.status] and the
/// error envelope. That is how a class whose Office 365 group Graph will never
/// manage (a mail-enabled security group, #331) reached the operator as
/// *"38 of 38 membership change(s) failed"* with no cause, contradicted by a log
/// claiming success.
///
/// This is the one place a `List<BatchResponse>` becomes words; each call site
/// phrases the sentence around them in its own language.
class BatchReport {
  final List<BatchResponse> responses;

  BatchReport(List<BatchResponse> responses)
      : responses = List<BatchResponse>.unmodifiable(responses);

  int get total => responses.length;

  List<BatchResponse> get failures => [
        for (final r in responses)
          if (!r.isSuccess) r
      ];

  int get failureCount => failures.length;

  int get successCount => total - failureCount;

  bool get hasFailures => failureCount > 0;

  /// Graph's own words for the refusals, de-duplicated, in the order they came
  /// back. One entry for a wholesale refusal — every sub-request turned down for
  /// the same reason, the [BatchReport] class comment's case — and more when a
  /// batch failed for mixed reasons, which is what stops a mixed batch from
  /// being reported as if the first failure explained all of them.
  ///
  /// Empty when nothing failed.
  List<String> get reasons {
    final seen = <String>{};
    return [
      for (final r in failures)
        if (seen.add(r.reason)) r.reason,
    ];
  }

  /// One line per refused sub-request — `<label> → <reason>` — for the log, so a
  /// partial failure can be traced to the accounts it hit. [labels] maps a
  /// sub-request id onto something the operator recognises (the member's object
  /// id); an id with no label stands for itself.
  ///
  /// Successful sub-requests are deliberately left out: 36 "ok" lines bury the
  /// two that matter.
  List<String> failureLines({Map<String, String>? labels}) => [
        for (final r in failures) '${labels?[r.id] ?? r.id} → ${r.reason}',
      ];
}

/// Coalesces multiple writes into Graph `$batch` calls.
///
/// Graph caps a batch at 20 sub-requests, so [execute] chunks larger inputs.
/// Used to fold many membership add/remove operations into few round-trips —
/// something the legacy connector never did (one HTTP call per member).
class GraphBatch {
  /// Microsoft Graph's per-batch sub-request ceiling.
  static const int maxBatchSize = 20;

  final GraphClient _graph;

  const GraphBatch(this._graph);

  Future<List<BatchResponse>> execute(List<BatchRequest> requests) async {
    final results = <BatchResponse>[];
    for (var i = 0; i < requests.length; i += maxBatchSize) {
      final chunk = requests.sublist(
        i,
        i + maxBatchSize > requests.length ? requests.length : i + maxBatchSize,
      );
      final payload = {'requests': chunk.map((r) => r.toJson()).toList()};
      final json = await _graph.postJson(_graph.uri(r'$batch'), payload);
      final responses = (json['responses'] as List<dynamic>?) ?? const [];
      for (final r in responses.cast<Map<String, dynamic>>()) {
        results.add(
          BatchResponse(
            id: r['id'] as String,
            status: (r['status'] as num).toInt(),
            body: r['body'] is Map<String, dynamic>
                ? r['body'] as Map<String, dynamic>
                : null,
          ),
        );
      }
    }
    return results;
  }
}
