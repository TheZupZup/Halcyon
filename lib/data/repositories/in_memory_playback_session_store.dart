import '../../core/models/persisted_playback_session.dart';
import '../../core/repositories/playback_session_store.dart';

/// A non-persistent [PlaybackSessionStore] for development and tests.
class InMemoryPlaybackSessionStore implements PlaybackSessionStore {
  InMemoryPlaybackSessionStore([this._session]);

  PersistedPlaybackSession? _session;

  @override
  Future<PersistedPlaybackSession?> load() async => _session;

  @override
  Future<void> save(PersistedPlaybackSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}
