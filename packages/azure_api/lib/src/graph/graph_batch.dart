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
  final Map<String, dynamic>? body;

  const BatchResponse({required this.id, required this.status, this.body});

  bool get isSuccess => status >= 200 && status < 300;
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
            body: r['body'] as Map<String, dynamic>?,
          ),
        );
      }
    }
    return results;
  }
}
