import '../../models/audiobookshelf_session.dart';
import 'audiobookshelf_api.dart';

/// The single seam through which Linthra talks HTTP to an Audiobookshelf
/// server.
///
/// Every request to Audiobookshelf goes through this interface, so the rest
/// of the app (authenticator, future library/playback code) depends only on
/// it — never on `http`, URLs, headers, or JSON. That keeps networking
/// swappable and, crucially, lets tests drive the feature with a fake client
/// and canned responses (no real server).
///
/// Implementations throw an [AudiobookshelfException] (with a friendly
/// message and an [AudiobookshelfErrorKind]) for every failure, and must
/// never put the password or either token into an exception, log, or any
/// other output.
abstract interface class AudiobookshelfClient {
  /// Confirms an address is a reachable Audiobookshelf server and returns its
  /// status. Backs "Test connection"; needs no credentials.
  Future<AudiobookshelfServerStatus> fetchServerStatus(String baseUrl);

  /// Exchanges a username + password for an access token (and, when the
  /// server grants one, a refresh token).
  Future<AudiobookshelfAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
  });

  /// Lists the signed-in user's accessible libraries.
  Future<List<AudiobookshelfLibraryDto>> fetchLibraries(
    AudiobookshelfSession session,
  );
}
