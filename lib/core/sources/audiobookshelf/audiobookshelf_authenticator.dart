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
  /// [serverStatus], when known from a prior [testConnection], is carried
  /// into the session (server version) for display and diagnostics. When it
  /// is absent, sign-in reads `/status` itself so the session still records
  /// the server's version — best-effort, since the auth call is the real
  /// gate and a status hiccup must not block a valid sign-in.
  ///
  /// Throws [AudiobookshelfException] for a bad URL, missing username, or
  /// rejected credentials.
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

    // Reuse a known server status, else read it now so the session captures
    // the version for diagnostics. Swallow its failure: the auth call below
    // surfaces the real, friendly error for a bad address or down server.
    final AudiobookshelfServerStatus? status =
        serverStatus ?? await _tryFetchServerStatus(baseUrl);

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
      serverVersion: status?.serverVersion,
    );
  }

  Future<AudiobookshelfServerStatus?> _tryFetchServerStatus(
    String baseUrl,
  ) async {
    try {
      return await _client.fetchServerStatus(baseUrl);
    } on AudiobookshelfException {
      return null;
    }
  }
}
