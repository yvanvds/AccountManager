import 'dart:convert';

import 'cosmos_config.dart';
import 'cosmos_token_provider.dart';
import 'cosmos_transport.dart';

/// The result of a write that may be conditioned on an `If-Match` ETag (#121).
///
/// An unconditioned write (no `ifMatch`) is always [applied]. A conditioned
/// write is [applied] when the ETag still matched, carrying the document's new
/// [etag] for chaining the next write in a read → mutate → write loop; it is
/// [stale] when Cosmos rejected it with **412 Precondition Failed** because the
/// document changed since it was read — the signal to reload and retry.
class WriteOutcome {
  const WriteOutcome._(this.applied, this.etag);

  /// The write was accepted; [etag] is the document's new ETag (when Cosmos
  /// returned one) for the next conditioned write in a read-modify-write chain.
  const WriteOutcome.applied(String? etag) : this._(true, etag);

  /// The conditioned write was rejected: the `If-Match` ETag was stale. The
  /// caller must reload the document and retry.
  const WriteOutcome.stale() : this._(false, null);

  /// Whether the write was accepted (`true`) or rejected as stale (`false`).
  final bool applied;

  /// The document's new ETag after an [applied] write, or `null` when the write
  /// was [stale] or Cosmos returned no ETag.
  final String? etag;

  /// The inverse of [applied]: the conditioned write lost the race and must be
  /// retried against a fresh read.
  bool get stale => !applied;
}

/// The typed document surface the Cosmos-backed stores and resolver plug into.
///
/// The seam the three Phase B adapters (`CosmosSettingsStore`,
/// `CosmosPasswordQueueStore`, `CosmosPersonIdResolver`) read and write through
/// instead of touching HTTP directly — the Cosmos counterpart of the retired
/// `SqlConnection`. Keeping it document-shaped (point read / create / upsert /
/// delete / query) rather than SQL-shaped means the adapters express their
/// intent directly and are unit-testable against a hand-written in-memory fake,
/// while only [HttpCosmosClient] binds the wire protocol.
abstract interface class CosmosClient {
  /// Point-reads the document [id] in [container] from logical partition
  /// [partitionKey]. Returns `null` on 404 (no such document), so first-run has
  /// no special case; throws [CosmosException] on any other non-2xx.
  ///
  /// The returned map carries the document's Cosmos `_etag`, so a caller doing
  /// a read → mutate → conditioned-write loop can pass `doc['_etag']` back as
  /// [upsertDocument]'s `ifMatch` (#121).
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  });

  /// Creates [document] in [container] under [partitionKey]. Returns `true` when
  /// Cosmos accepted it (201) and `false` when it was rejected for an id or
  /// unique-key **conflict** (409) — the signal the resolver uses to adopt a
  /// concurrently-minted id. Throws [CosmosException] on any other non-2xx.
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  });

  /// Creates-or-replaces [document] in [container] under [partitionKey]
  /// (`x-ms-documentdb-is-upsert`). A single-document write is atomic, so this
  /// is how the settings and password-queue stores "replace the whole value".
  ///
  /// When [ifMatch] is given the write is conditioned on that ETag (`If-Match`):
  /// Cosmos applies it only if the stored document still carries that ETag, and
  /// rejects it with **412** — surfaced as [WriteOutcome.stale] — when another
  /// writer changed it first. This is the per-document optimistic-concurrency
  /// guard the concurrent apply / password write path uses so two operators
  /// writing the *same* doc can't clobber each other (#121); an unconditioned
  /// write (no [ifMatch]) is always [WriteOutcome.applied].
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  });

  /// Deletes the document [id] in [container] from [partitionKey]. A 404 is
  /// treated as success (already gone), so delete is idempotent.
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  });

  /// Runs the SQL [query] against [container] and returns every matching
  /// document, following `x-ms-continuation` across pages so the caller never
  /// sees a truncated result. [parameters] are bound (never interpolated), so a
  /// value can never be read as query text. When [partitionKey] is given the
  /// query is scoped to that one logical partition (cheaper); when omitted it
  /// runs cross-partition.
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters,
    String? partitionKey,
  });
}

/// The default [CosmosClient], speaking the Cosmos DB SQL-API data plane over a
/// swappable [CosmosTransport] (mirroring `KeyVaultSecretProvider` over
/// `KeyVaultTransport`).
///
/// **Auth.** The account is AAD-only, so every request carries an
/// `authorization` header built from a bearer token for `https://cosmos.azure.com`
/// in Cosmos's `type=aad&ver=1.0&sig=<token>` scheme (URL-encoded), plus the
/// required `x-ms-date` (RFC 1123) and `x-ms-version` headers. The token is read
/// fresh from [CosmosTokenProvider] per request, so a request never outlives its
/// short-lived bearer token.
///
/// The wire details (URL layout, partition-key header, upsert/query headers,
/// continuation paging, status→outcome mapping) live here and are exercised by
/// the fake-transport unit tests; the adapters above see only [CosmosClient].
class HttpCosmosClient implements CosmosClient {
  HttpCosmosClient({
    required CosmosConfig config,
    required CosmosTransport transport,
    required CosmosTokenProvider tokens,
    DateTime Function()? now,
  })  : _config = config,
        _transport = transport,
        _tokens = tokens,
        _now = now ?? DateTime.now;

  final CosmosConfig _config;
  final CosmosTransport _transport;
  final CosmosTokenProvider _tokens;
  final DateTime Function() _now;

  /// The data-plane REST API version. Any recent value works for the operations
  /// used here; pinned so behaviour does not drift under the account.
  static const String apiVersion = '2018-12-31';

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    final resp = await _send(
      'GET',
      _docPath(container, id),
      partitionKey: partitionKey,
    );
    if (resp.isNotFound) return null;
    _ensureSuccess(resp);
    final doc = resp.json;
    // Cosmos returns `_etag` in the document body; fall back to the `etag`
    // response header so a conditioned-write caller always finds it under the
    // well-known `_etag` key (#121).
    if (doc['_etag'] == null && resp.etag != null) doc['_etag'] = resp.etag;
    return doc;
  }

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async {
    final resp = await _send(
      'POST',
      _docsPath(container),
      partitionKey: partitionKey,
      body: jsonEncode(document),
    );
    if (resp.isConflict) return false;
    _ensureSuccess(resp);
    return true;
  }

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async {
    final resp = await _send(
      'POST',
      _docsPath(container),
      partitionKey: partitionKey,
      body: jsonEncode(document),
      extraHeaders: {
        'x-ms-documentdb-is-upsert': 'true',
        if (ifMatch != null) 'If-Match': ifMatch,
      },
    );
    // A conditioned write that lost the race: reload and retry, don't throw.
    if (ifMatch != null && resp.isPreconditionFailed) {
      return const WriteOutcome.stale();
    }
    _ensureSuccess(resp);
    // Cosmos echoes the stored document (with its new `_etag`) and sets the
    // `etag` header; surface it for the next write in a read-modify-write chain.
    return WriteOutcome.applied(resp.etag ?? resp.json['_etag'] as String?);
  }

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    final resp = await _send(
      'DELETE',
      _docPath(container, id),
      partitionKey: partitionKey,
    );
    if (resp.isNotFound) return;
    _ensureSuccess(resp);
  }

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async {
    final body = jsonEncode({
      'query': query,
      'parameters': [
        for (final entry in parameters.entries)
          {'name': entry.key, 'value': entry.value},
      ],
    });
    final results = <Map<String, dynamic>>[];
    String? continuation;
    do {
      final resp = await _send(
        'POST',
        _docsPath(container),
        partitionKey: partitionKey,
        body: body,
        // application/query+json + the isquery header tell Cosmos to parse the
        // body as a query, not a document. -1 lifts the per-page item cap so a
        // batch read pages by size limit, not by Cosmos's default of 100.
        extraHeaders: {
          'x-ms-documentdb-isquery': 'true',
          'x-ms-max-item-count': '-1',
          if (partitionKey == null)
            'x-ms-documentdb-query-enablecrosspartition': 'true',
          if (continuation != null) 'x-ms-continuation': continuation,
        },
        contentType: 'application/query+json',
      );
      _ensureSuccess(resp);
      final documents = resp.json['Documents'];
      if (documents is List) {
        for (final doc in documents) {
          if (doc is Map<String, dynamic>) results.add(doc);
        }
      }
      continuation = resp.continuation;
    } while (continuation != null);
    return results;
  }

  Future<CosmosResponse> _send(
    String method,
    String path, {
    String? partitionKey,
    String? body,
    Map<String, String> extraHeaders = const {},
    String contentType = 'application/json',
  }) async {
    final token = await _tokens.cosmosAccessToken();
    final headers = <String, String>{
      'authorization': _authHeader(token),
      'x-ms-date': _rfc1123(_now().toUtc()),
      'x-ms-version': apiVersion,
      if (body != null) 'Content-Type': contentType,
      if (partitionKey != null)
        'x-ms-documentdb-partitionkey': jsonEncode([partitionKey]),
      ...extraHeaders,
    };
    return _transport.send(CosmosRequest(
      method: method,
      url: Uri.parse('${_base()}$path'),
      headers: headers,
      body: body,
    ));
  }

  /// The account endpoint without a trailing slash, so `$base$path` joins
  /// cleanly regardless of how the endpoint was configured.
  String _base() {
    final e = _config.endpoint;
    return e.endsWith('/') ? e.substring(0, e.length - 1) : e;
  }

  String _docsPath(String container) =>
      '/dbs/${_config.database}/colls/$container/docs';

  String _docPath(String container, String id) =>
      '${_docsPath(container)}/${Uri.encodeComponent(id)}';

  void _ensureSuccess(CosmosResponse resp) {
    if (!resp.isSuccess) throw CosmosException(resp.statusCode, resp.body);
  }

  /// Builds the Cosmos AAD `authorization` header value: the whole
  /// `type=aad&ver=1.0&sig=<token>` string URL-encoded as one component. The
  /// bearer token is already URL-safe (base64url with `.` separators), so only
  /// the `=`/`&` separators are escaped.
  static String _authHeader(String token) =>
      Uri.encodeComponent('type=aad&ver=1.0&sig=$token');
}

const List<String> _weekdays = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats [utc] as an RFC 1123 date, e.g. `Sat, 04 Jul 2026 10:04:38 GMT`, the
/// shape Cosmos requires for `x-ms-date`. Built by hand (fixed English day/month
/// names, always GMT) so the client needs no `intl` dependency and never depends
/// on the host locale. [utc] must already be in UTC.
String _rfc1123(DateTime utc) {
  String two(int n) => n.toString().padLeft(2, '0');
  final wd = _weekdays[utc.weekday - 1];
  final mon = _months[utc.month - 1];
  return '$wd, ${two(utc.day)} $mon ${utc.year} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
}
