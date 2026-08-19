import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_client.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';

/// A configurable [AudiobookshelfClient] that returns canned responses (or
/// throws) and records what it was asked, so the authenticator can be tested
/// without a real server or HTTP.
class FakeAudiobookshelfClient implements AudiobookshelfClient {
  FakeAudiobookshelfClient({
    this.serverStatus,
    this.authResult,
    this.libraries = const <AudiobookshelfLibraryDto>[],
    this.serverStatusError,
    this.authError,
    this.librariesError,
  });

  AudiobookshelfServerStatus? serverStatus;
  AudiobookshelfAuthResult? authResult;
  List<AudiobookshelfLibraryDto> libraries;
  AudiobookshelfException? serverStatusError;
  AudiobookshelfException? authError;
  AudiobookshelfException? librariesError;

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastUsername;
  String? lastPassword;
  AudiobookshelfSession? lastSession;

  /// How many times [fetchServerStatus] was called, so a test can prove the
  /// authenticator reuses a status the caller already fetched instead of
  /// asking again.
  int serverStatusCallCount = 0;

  @override
  Future<AudiobookshelfServerStatus> fetchServerStatus(
    String baseUrl,
  ) async {
    lastBaseUrl = baseUrl;
    serverStatusCallCount++;
    if (serverStatusError != null) throw serverStatusError!;
    final AudiobookshelfServerStatus? status = serverStatus;
    if (status == null) {
      throw AudiobookshelfException.notReachable();
    }
    return status;
  }

  @override
  Future<AudiobookshelfAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    lastBaseUrl = baseUrl;
    lastUsername = username;
    lastPassword = password;
    if (authError != null) throw authError!;
    final AudiobookshelfAuthResult? result = authResult;
    if (result == null) {
      throw AudiobookshelfException.unauthorized();
    }
    return result;
  }

  @override
  Future<List<AudiobookshelfLibraryDto>> fetchLibraries(
    AudiobookshelfSession session,
  ) async {
    lastSession = session;
    if (librariesError != null) throw librariesError!;
    return libraries;
  }
}
