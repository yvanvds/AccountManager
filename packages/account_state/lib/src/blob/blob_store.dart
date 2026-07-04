import 'blob_token_provider.dart';
import 'blob_transport.dart';

/// The overflow store for cold snapshot payloads too large for a Cosmos
/// document (Cosmos caps a document at 2 MB; a whole-school WISA or Azure
/// snapshot can exceed that).
///
/// The seam the `SnapshotStore` writes the raw payload through when it does not
/// fit inline. Kept deliberately small — a keyed put / get / delete of an
/// opaque UTF-8 string — so it is unit-testable against an in-memory fake and
/// only [HttpBlobStore] binds the Blob REST protocol. The `SnapshotStore`
/// records the returned reference in its Cosmos metadata document and hands it
/// back to [read] to fetch the payload on the next sync.
abstract interface class BlobStore {
  /// Uploads [content] (UTF-8 JSON) under the deterministic [name], overwriting
  /// any previous blob of that name, and returns the reference to persist. The
  /// reference is what [read]/[delete] take back — callers treat it as opaque.
  Future<String> write(String name, String content);

  /// Reads the blob referenced by [ref] (as returned by [write]), or `null`
  /// when it no longer exists.
  Future<String?> read(String ref);

  /// Removes the blob referenced by [ref]. Idempotent — a missing blob is a
  /// success, so a snapshot that shrank back under the inline limit can drop
  /// its overflow blob without a pre-check.
  Future<void> delete(String ref);
}

/// The connection target for the centralized Blob Storage account.
///
/// Names *where* the overflow container lives — the blob endpoint and the
/// container — and nothing more. Carries no credential: authentication is the
/// separate [BlobTokenProvider] seam, so the target can round-trip through
/// settings or a log line without leaking a secret (the same discipline
/// [CosmosConfig] applies).
class BlobConfig {
  const BlobConfig({required this.endpoint, required this.container});

  /// The account's blob endpoint, e.g.
  /// `https://accountmanagerarcadia.blob.core.windows.net`. A trailing slash is
  /// tolerated — [HttpBlobStore] normalizes it when building request URLs.
  final String endpoint;

  /// The container holding the snapshot overflow blobs, e.g. `snapshots`. The
  /// container is provisioned out of band (data-plane RBAC cannot create it).
  final String container;

  @override
  bool operator ==(Object other) =>
      other is BlobConfig &&
      other.endpoint == endpoint &&
      other.container == container;

  @override
  int get hashCode => Object.hash(endpoint, container);

  @override
  String toString() => 'BlobConfig($endpoint/$container)';
}

/// The default [BlobStore], speaking the Azure Blob Storage REST data plane over
/// a swappable [BlobTransport] (mirroring [HttpCosmosClient] over
/// [CosmosTransport]).
///
/// **Auth.** The account is AAD-only, so every request carries a
/// `Bearer` token for `https://storage.azure.com` from [BlobTokenProvider],
/// plus the required `x-ms-date` (RFC 1123) and `x-ms-version` headers. A write
/// is a single block-blob `PUT` (`x-ms-blob-type: BlockBlob`); a read is a
/// `GET`; a delete is a `DELETE`. The token is read fresh per request so a
/// request never outlives its short-lived bearer token.
class HttpBlobStore implements BlobStore {
  HttpBlobStore({
    required BlobConfig config,
    required BlobTransport transport,
    required BlobTokenProvider tokens,
    DateTime Function()? now,
  })  : _config = config,
        _transport = transport,
        _tokens = tokens,
        _now = now ?? DateTime.now;

  final BlobConfig _config;
  final BlobTransport _transport;
  final BlobTokenProvider _tokens;
  final DateTime Function() _now;

  /// The Blob REST API version. Any recent value works for the operations used
  /// here; pinned so behaviour does not drift under the account.
  static const String apiVersion = '2021-12-02';

  @override
  Future<String> write(String name, String content) async {
    final resp = await _send(
      'PUT',
      name,
      body: content,
      extraHeaders: const {
        'x-ms-blob-type': 'BlockBlob',
        'Content-Type': 'application/json',
      },
    );
    _ensureSuccess(resp);
    return name;
  }

  @override
  Future<String?> read(String ref) async {
    final resp = await _send('GET', ref);
    if (resp.isNotFound) return null;
    _ensureSuccess(resp);
    return resp.body;
  }

  @override
  Future<void> delete(String ref) async {
    final resp = await _send('DELETE', ref);
    if (resp.isNotFound) return;
    _ensureSuccess(resp);
  }

  Future<BlobResponse> _send(
    String method,
    String blob, {
    String? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    final token = await _tokens.blobAccessToken();
    final headers = <String, String>{
      'authorization': 'Bearer $token',
      'x-ms-date': _rfc1123(_now().toUtc()),
      'x-ms-version': apiVersion,
      ...extraHeaders,
    };
    return _transport.send(BlobRequest(
      method: method,
      url: Uri.parse('${_base()}/${_config.container}/'
          '${Uri.encodeComponent(blob)}'),
      headers: headers,
      body: body,
    ));
  }

  /// The endpoint without a trailing slash, so `$base/$container/$blob` joins
  /// cleanly regardless of how the endpoint was configured.
  String _base() {
    final e = _config.endpoint;
    return e.endsWith('/') ? e.substring(0, e.length - 1) : e;
  }

  void _ensureSuccess(BlobResponse resp) {
    if (!resp.isSuccess) throw BlobException(resp.statusCode, resp.body);
  }
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

/// Formats [utc] as an RFC 1123 date, the shape Blob Storage requires for
/// `x-ms-date`. Built by hand (fixed English day/month names, always GMT) so the
/// library needs no `intl` dependency and never depends on the host locale.
/// [utc] must already be in UTC.
String _rfc1123(DateTime utc) {
  String two(int n) => n.toString().padLeft(2, '0');
  final wd = _weekdays[utc.weekday - 1];
  final mon = _months[utc.month - 1];
  return '$wd, ${two(utc.day)} $mon ${utc.year} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
}
