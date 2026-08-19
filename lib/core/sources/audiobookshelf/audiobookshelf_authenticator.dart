import '../../models/audiobookshelf_session.dart';
import 'audiobookshelf_api.dart';
import 'audiobookshelf_client.dart';
import 'audiobookshelf_exception.dart';
import 'audiobookshelf_server_url.dart';

/// Turns a raw address + credentials into a usable [AudiobookshelfSession].
///
/// This is the "authentication" concern, kept separate from settings storage
/// (a future `AudiobookshelfSessionStore`, out of scope for this PR) and from
/// library fetching (the client's `fetchLibraries`): it validates the URL and
/// asks the [AudiobookshelfClient] to authenticate. It does not persist
/// anything — the caller decides whether/where to store the session — so
/// this stays a pure coordinator that's trivial to test with a fake client.
///
/// The password is passed straight through to the one auth call and is never
/// held, copied into the session, or logged.
class AudiobookshelfAuthenticator {
  AudiobookshelfAuthenticator(this._client);

  final AudiobookshelfClient _client;

  /// Validates [rawUrl] and confirms it points at an Audiobookshelf server,
  /// returning its status. Throws [AudiobookshelfException] on a bad URL or
  /// unreachable/non-Audiobookshelf server.
  Future<AudiobookshelfServerStatus> testConnection(String rawUrl) async {
    final String baseUrl = AudiobookshelfServerUrl.normalize(rawUrl);
    return _client.fetchServerStatus(baseUrl);
  }

  /// Signs in and returns a session.
  ///
  /// [serverStatus], when known from a prior [testConnection] against this
  /// same [rawUrl], is reused instead of fetching it again. When it is
  /// absent, sign-in fetches `/status` itself first. Credentials are only
  /// ever sent to [baseUrl] once that address has confirmed it's an
  /// Audiobookshelf server, never on a status-fetch failure. A caller must
  /// not pass a [serverStatus] obtained for a different address.
  ///
  /// Throws [AudiobookshelfException] for a bad URL, an unconfirmed server,
  /// a missing username, or rejected credentials.
  Future<AudiobookshelfSession> signIn({
    required String rawUrl,
    required String username,
    required String password,
    AudiobookshelfServerStatus? serverStatus,
  }) async {
    final String baseUrl = AudiobookshelfServerUrl.normalize(rawUrl);
    final String trimmedUsername = username.trim();
    if (trimmedUsername.isEmpty) {
      throw const AudiobookshelfException(
        'Enter your Audiobookshelf username.',
        kind: AudiobookshelfErrorKind.unauthorized,
      );
    }

    // Reuse a status already confirmed for this address, else confirm it
    // now. Left to throw on failure: credentials must never reach an
    // address that hasn't confirmed it's an Audiobookshelf server.
    final AudiobookshelfServerStatus status =
        serverStatus ?? await _client.fetchServerStatus(baseUrl);

    final AudiobookshelfAuthResult result = await _client.authenticateByName(
      baseUrl: baseUrl,
      username: trimmedUsername,
      password: password,
    );

    return AudiobookshelfSession(
      baseUrl: baseUrl,
      userId: result.userId,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
      userName: result.userName ?? trimmedUsername,
      defaultLibraryId: result.defaultLibraryId,
      serverVersion: status.serverVersion,
    );
  }
}
