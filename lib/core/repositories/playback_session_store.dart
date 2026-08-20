import '../models/persisted_playback_session.dart';

/// Durable storage for a crash-safe [PersistedPlaybackSession].
///
/// The persistence seam under [PlaybackSessionPersistence]: it knows nothing
/// about the audio engine — only how to load, save, and clear the session
/// document. Splitting it out lets the backing store swap freely (in-memory for
/// tests, key/value in the app), mirroring [PlayHistoryStore].
///
/// Privacy: only logical track identity, queue/modes, and position are stored —
/// never a token or authenticated stream URL. The document stays on the device.
abstract interface class PlaybackSessionStore {
  /// The last persisted session, or `null` when none / unusable.
  Future<PersistedPlaybackSession?> load();

  /// Replaces the persisted session. Callers must only pass logical, sanitized
  /// sessions.
  Future<void> save(PersistedPlaybackSession session);

  /// Drops any persisted session (explicit stop/clear, or after a failed
  /// restore that should not be retried).
  Future<void> clear();
}
