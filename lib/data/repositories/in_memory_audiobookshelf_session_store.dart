import '../../core/models/audiobookshelf_session.dart';
import '../../core/repositories/audiobookshelf_session_store.dart';

/// A non-persistent [AudiobookshelfSessionStore] for development and tests.
///
/// Holds the session in a single field, so it's forgotten when the instance is
/// dropped. This is the default binding (mirroring the other session stores);
/// the running app swaps in `SecureAudiobookshelfSessionStore` so the tokens
/// survive restarts in encrypted storage.
class InMemoryAudiobookshelfSessionStore implements AudiobookshelfSessionStore {
  InMemoryAudiobookshelfSessionStore({AudiobookshelfSession? initialSession})
      : _session = initialSession;

  AudiobookshelfSession? _session;

  @override
  Future<AudiobookshelfSession?> read() async => _session;

  @override
  Future<void> write(AudiobookshelfSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}
