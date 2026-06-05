import 'dart:io';

import 'auth_provider.dart';
import 'oauth_auth_provider.dart';

/// Opens [url] in the user's browser. The Flutter app wires this to
/// `url_launcher` (or `Process.start` on desktop); the package stays free of
/// platform plugins.
typedef BrowserLauncher = Future<void> Function(Uri url);

/// Desktop [InteractiveAuthorizer]: launches the system browser and captures
/// the redirect on a loopback HTTP server (RFC 8252).
///
/// This is the one code path that genuinely needs a browser and a real socket,
/// so it is exercised by the live flow rather than unit tests — its untested
/// status is documented in the README. The pure token-exchange and refresh
/// logic lives in [OAuthAuthProvider] and is fully covered with a fake
/// authorizer.
class LoopbackAuthorizer {
  final BrowserLauncher launchBrowser;

  /// HTML returned to the browser once the redirect is captured.
  final String successHtml;

  const LoopbackAuthorizer({
    required this.launchBrowser,
    this.successHtml = '<html><body><h2>Signed in.</h2>'
        'You can close this window and return to the app.</body></html>',
  });

  /// Implements [InteractiveAuthorizer]. Binds the loopback port from
  /// [redirectUri], opens [authorizationUrl], and returns the query parameters
  /// from the single redirect request.
  Future<Map<String, String>> call(
    Uri authorizationUrl,
    Uri redirectUri,
  ) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirectUri.port,
    );
    try {
      await launchBrowser(authorizationUrl);
      final request = await server.first;
      final params = request.uri.queryParameters;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(successHtml);
      await request.response.close();
      if (params.containsKey('error')) {
        throw AzureAuthException(
          'authorization error: ${params['error']} '
                  '${params['error_description'] ?? ''}'
              .trim(),
        );
      }
      return params;
    } finally {
      await server.close(force: true);
    }
  }
}
