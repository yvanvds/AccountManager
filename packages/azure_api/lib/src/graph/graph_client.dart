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

/// Tests a non-2xx Graph reply for "this is the failure I came prepared for".
///
/// Handed to [GraphClient] by a caller that recovers from a specific shape, so
/// the transport can log that reply as a detail instead of an error (#229).
typedef GraphFailurePredicate = bool Function(GraphException failure);

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
  ///
  /// [expected] declares a failure shape the caller recovers from; see [_send].
  Future<Map<String, dynamic>> getJson(
    Uri url, {
    Map<String, String>? headers,
    GraphFailurePredicate? expected,
  }) async {
    final resp = await _send('GET', url, headers: headers, expected: expected);
    return resp.json;
  }

  /// GET every page of a collection at [url], following `@odata.nextLink`.
  /// Returns the concatenated `value` arrays. [headers] (e.g. the advanced-
  /// query `ConsistencyLevel: eventual`) are sent on every page.
  ///
  /// [onPage], when supplied, is invoked after each page with the running
  /// total of items gathered so far. Callers use it to emit progress while a
  /// large multi-page pull is advancing (issue #177).
  ///
  /// [expected] declares a failure shape the caller recovers from, on every
  /// page; see [_send]. `GroupManager`'s per-group member read uses it to say
  /// that a group deleted mid-walk is a reply it handles (#356), so a pull that
  /// completed does not leave a red line behind (#229).
  Future<List<Map<String, dynamic>>> getCollection(
    Uri url, {
    Map<String, String>? headers,
    void Function(int total)? onPage,
    GraphFailurePredicate? expected,
  }) async {
    final items = <Map<String, dynamic>>[];
    Uri? next = url;
    while (next != null) {
      final body = await getJson(next, headers: headers, expected: expected);
      items.addAll(_values(body));
      onPage?.call(items.length);
      next = _nextLink(body);
    }
    return items;
  }

  /// Walk a delta collection: follows `@odata.nextLink` to gather all changed
  /// resources, then captures the `$deltatoken` from the terminal
  /// `@odata.deltaLink` for the next incremental sync.
  ///
  /// [expected] declares a failure shape the caller recovers from; see [_send].
  Future<DeltaResult> getDelta(
    Uri url, {
    Map<String, String>? headers,
    GraphFailurePredicate? expected,
  }) async {
    final items = <Map<String, dynamic>>[];
    String? deltaToken;
    Uri? next = url;
    while (next != null) {
      final body = await getJson(next, headers: headers, expected: expected);
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

  /// Issues one request and turns a non-2xx reply into a [GraphException].
  ///
  /// The exception is always thrown; [expected] only decides how loudly the
  /// reply is logged. Without it the transport cannot know whether the caller
  /// recovers, so every failure is an error — which is how a delta-token
  /// rejection the connector fully recovers from still painted the operator's
  /// log red (#229). A caller that comes prepared for a shape says so, and that
  /// reply is logged as an ordinary detail beside the caller's own explanation.
  Future<GraphResponse> _send(
    String method,
    Uri url, {
    String? body,
    Map<String, String>? headers,
    GraphFailurePredicate? expected,
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
      final line = '$method ${redactUrl(url)} → $ex';
      if (expected != null && expected(ex)) {
        _log?.addMessage(
          core.Origin.azure,
          // The Graph body stays exactly as Graph sent it; only the clause this
          // client appends to it is the operator's language (#266).
          '$line (afgehandeld — de synchronisatie herstelt hiervan)',
        );
      } else {
        _log?.addError(core.Origin.azure, line);
      }
      throw ex;
    }
    return resp;
  }

  /// Query parameters whose values are opaque resume tokens.
  ///
  /// A Graph delta token runs to kilobytes, means nothing to a human, and is
  /// live state for the tenant — and the operator pastes log lines into issues.
  /// It is stripped from every logged URL at every severity (#229).
  static const Set<String> _opaqueTokenParams = {
    r'$deltatoken',
    r'$skiptoken',
  };

  /// What replaces an opaque token in a logged URL.
  static const String _redactedToken = '<redacted>';

  /// Graph's own sentinel for "mint me a token for right now" — a literal, not
  /// a secret, and the one thing that tells a primed full read apart from a
  /// resume in the log. Kept readable.
  static const String _latestToken = 'latest';

  /// [url] as it should appear in a log line: every opaque resume token
  /// replaced by [_redactedToken], everything else byte-for-byte unchanged.
  static String redactUrl(Uri url) {
    final query = url.query;
    if (query.isEmpty) return url.toString();
    final redacted = _redactQuery(query);
    if (redacted == query) return url.toString();
    // Pure string surgery on the rendered URL: rebuilding through [Uri] would
    // re-encode the placeholder (and re-encode the untouched parts besides).
    final full = url.toString();
    final start = full.indexOf('?') + 1;
    final end = url.hasFragment ? full.indexOf('#', start) : full.length;
    return full.replaceRange(start, end, redacted);
  }

  static String _redactQuery(String query) {
    final pairs = <String>[];
    for (final pair in query.split('&')) {
      final eq = pair.indexOf('=');
      if (eq < 0) {
        pairs.add(pair);
        continue;
      }
      final name = pair.substring(0, eq);
      final value = pair.substring(eq + 1);
      final redact = _opaqueTokenParams
              .contains(Uri.decodeComponent(name).toLowerCase()) &&
          Uri.decodeComponent(value) != _latestToken;
      pairs.add(redact ? '$name=$_redactedToken' : pair);
    }
    return pairs.join('&');
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
  ///
  /// Percent-decodes only — deliberately **not** [Uri.queryParameters], which
  /// form-decodes and so turns a literal `+` inside an opaque Graph token into
  /// a space. A token corrupted that way comes back from Graph as the same
  /// misleading *"DeltaLink older than 30 days is not supported"* 400 as a
  /// genuinely expired one (#213).
  static String? _tokenFrom(String link, String param) {
    for (final pair in Uri.parse(link).query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final name = eq < 0 ? pair : pair.substring(0, eq);
      if (Uri.decodeComponent(name) != param) continue;
      return eq < 0 ? '' : Uri.decodeComponent(pair.substring(eq + 1));
    }
    return null;
  }

  static String _trimLeadingSlash(String path) =>
      path.startsWith('/') ? path.substring(1) : path;
}
