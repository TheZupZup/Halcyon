import '../models/audiobookshelf_session.dart';

/// Persists the single [AudiobookshelfSession] across app restarts.
///
/// Deliberately separate from authentication (which *produces* a session) and
/// from library fetching (which *uses* one), exactly like the music providers'
/// session stores: this contract owns only the storage of the signed-in
/// session, so the tokens have one persistence path that can be made secure in
/// isolation.
///
/// The production binding encrypts on-device; tests and dev use an in-memory
/// implementation. The user's password is never given to this store — only the
/// session (server, user, access/refresh tokens) is.
abstract interface class AudiobookshelfSessionStore {
  /// The persisted session, or `null` if the user isn't signed in (or the
  /// stored record was missing/corrupt).
  Future<AudiobookshelfSession?> read();

  /// Persists [session], replacing any previous one.
  Future<void> write(AudiobookshelfSession session);

  /// Forgets the signed-in session (sign out).
  Future<void> clear();
}
