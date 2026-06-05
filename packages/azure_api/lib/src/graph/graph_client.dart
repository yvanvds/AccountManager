import 'dart:convert';

import 'package:account_core/account_core.dart' as core;

import '../auth/auth_provider.dart';
import 'graph_request.dart';
import 'graph_transport.dart';

/// All values from a `/…/delta` walk, plus the token to resume from next time.
class DeltaResult {
  final List<Map<String, dynamic>> values;

  /// The `$deltatoken` extracted from the final page's `@odata.deltaLink`.
  /// `null` if Graph returned no delta link.
  final String? deltaToken;

  const DeltaResult({required this.values, this.deltaToken});
}

/// Authenticated, paging-aware Microsoft Graph client.
///
/// Sits above the swappable [GraphTransport]: resolves a bearer token from the
/// [AzureAuthProvider] for every request, follows `@odata.nextLink`
/// pagination, and surfaces non-2xx replies as [GraphException]. The managers
/// talk to this, never to the transport directly.
class GraphClient {
  /// Microsoft Graph base URL. `v1.0` is the stable endpoint; `/users/delta`
  /// and `$batch` both live here.
  static final Uri defaultBaseUrl =
      Uri.parse('https://graph.microsoft.com/v1.0');

  final GraphTransport _transport;
  final AzureAuthProvider _auth;
  final Uri baseUrl;
  final core.ILog? _log;

  GraphClient({
    required GraphTransport transport,
    required AzureAuthProvider auth,
    Uri? baseUrl,
    core.ILog? log,
  })  : _transport = transport,
        _auth = auth,
        baseUrl = baseUrl ?? defaultBaseUrl,
        _log = log;

  /// Builds an absolute Graph URL from a path (e.g. `users`) and query
  /// parameters. Query values are passed through unescaped keys such as
  /// `$filter`/`$select`; [Uri] handles percent-encoding of the values.
  Uri uri(String path, {Map<String, String>? query}) {
    final trimmedBase = baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
    final base = Uri.parse('$trimmedBase/${_trimLeadingSlash(path)}');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, ...query});
  }

  /// GET a single resource (or the first page of a collection) and return the
  /// decoded JSON object.
  Future<Map<String, dynamic>> getJson(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    final resp = await _send('GET', url, headers: headers);
    return resp.json;
  }

  /// GET every page of a collection at [url], following `@odata.nextLink`.
  /// Returns the concatenated `value` arrays. [headers] (e.g. the advanced-
  /// query `ConsistencyLevel: eventual`) are sent on every page.
  Future<List<Map<String, dynamic>>> getCollection(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    final items = <Map<String, dynamic>>[];
    Uri? next = url;
    while (next != null) {
      final body = await getJson(next, headers: headers);
      items.addAll(_values(body));
      next = _nextLink(body);
    }
    return items;
  }

  /// Walk a delta collection: follows `@odata.nextLink` to gather all changed
  /// resources, then captures the `$deltatoken` from the terminal
  /// `@odata.deltaLink` for the next incremental sync.
  Future<DeltaResult> getDelta(Uri url, {Map<String, String>? headers}) async {
    final items = <Map<String, dynamic>>[];
    String? deltaToken;
    Uri? next = url;
    while (next != null) {
      final body = await getJson(next, headers: headers);
      items.addAll(_values(body));
      next = _nextLink(body);
      final deltaLink = body['@odata.deltaLink'] as String?;
      if (deltaLink != null) deltaToken = _tokenFrom(deltaLink, r'$deltatoken');
    }
    return DeltaResult(values: items, deltaToken: deltaToken);
  }

  /// POST [body] (a JSON-encodable map) to [url]. Returns the decoded response
  /// (empty map for `204 No Content`).
  Future<Map<String, dynamic>> postJson(
    Uri url,
    Object body, {
    Map<String, String>? headers,
  }) async {
    final resp = await _send(
      'POST',
      url,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json', ...?headers},
    );
    return resp.json;
  }

  /// PATCH [body] to [url] (Graph user/group update). Graph replies `204`.
  Future<void> patchJson(
    Uri url,
    Object body, {
    Map<String, String>? headers,
  }) async {
    await _send(
      'PATCH',
      url,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json', ...?headers},
    );
  }

  /// DELETE [url]. Graph replies `204`.
  Future<void> delete(Uri url, {Map<String, String>? headers}) async {
    await _send('DELETE', url, headers: headers);
  }

  Future<GraphResponse> _send(
    String method,
    Uri url, {
    String? body,
    Map<String, String>? headers,
  }) async {
    final token = await _auth.getAccessToken();
    final request = GraphRequest(
      method: method,
      url: url,
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        ...?headers,
      },
      body: body,
    );
    final resp = await _transport.send(request);
    if (!resp.isSuccess) {
      final ex = GraphException(resp.statusCode, resp.body);
      _log?.addError(core.Origin.azure, '$method $url → $ex');
      throw ex;
    }
    return resp;
  }

  List<Map<String, dynamic>> _values(Map<String, dynamic> body) {
    final value = body['value'];
    if (value is List) return value.cast<Map<String, dynamic>>();
    return const [];
  }

  Uri? _nextLink(Map<String, dynamic> body) {
    final link = body['@odata.nextLink'] as String?;
    return link == null ? null : Uri.parse(link);
  }

  /// Extracts the value of a query parameter (e.g. `$deltatoken`) from a full
  /// Graph link URL.
  static String? _tokenFrom(String link, String param) =>
      Uri.parse(link).queryParameters[param];

  static String _trimLeadingSlash(String path) =>
      path.startsWith('/') ? path.substring(1) : path;
}
