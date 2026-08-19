/// Every Audiobookshelf REST path and URL Linthra builds, in one place.
///
/// Centralizing the endpoints means:
///  - the HTTP client never embeds raw path strings, so a path can't quietly
///    drift between two call sites;
///  - the exact set of endpoints Linthra depends on is auditable from this
///    one file.
///
/// All builders are pure: they take a clean base URL (no trailing slash, as
/// produced by [AudiobookshelfServerUrl.normalize]) plus the ids/params they
/// need and return a [Uri]. Nothing here performs I/O, logs, or holds state.
///
/// Paths confirmed directly against Audiobookshelf's own server source
/// (`server/Server.js`, `server/Auth.js`, `server/routers/ApiRouter.js`) —
/// see PR description for the exact references.
abstract final class AudiobookshelfEndpoints {
  static const String _statusPath = '/status';
  static const String _loginPath = '/login';
  static const String _librariesPath = '/api/libraries';

  /// `GET /status` — public, unauthenticated. Confirms the address is a
  /// reachable Audiobookshelf server (the response includes `app:
  /// "audiobookshelf"`) and returns its version, without needing credentials.
  /// Backs "Test connection".
  static Uri status(String baseUrl) => _join(baseUrl, _statusPath);

  /// `POST /login` — exchanges a username + password for an access token
  /// (and, when the request carries the `x-return-tokens: true` header, a
  /// refresh token in the response body instead of only as an httpOnly
  /// cookie a mobile client can't use).
  static Uri login(String baseUrl) => _join(baseUrl, _loginPath);

  /// `GET /api/libraries` — the signed-in user's accessible libraries.
  /// Requires the `Authorization: Bearer <accessToken>` header.
  static Uri libraries(String baseUrl) => _join(baseUrl, _librariesPath);

  /// `GET /api/libraries/{id}/items` — the items in one library. Requires
  /// the `Authorization: Bearer <accessToken>` header.
  static Uri libraryItems(String baseUrl, String libraryId) =>
      _join(baseUrl, '/api/libraries/$libraryId/items');

  static Uri _join(String baseUrl, String path) => Uri.parse('$baseUrl$path');
}
