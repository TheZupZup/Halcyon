import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/audiobookshelf_session_store.dart';
import 'in_memory_audiobookshelf_session_store.dart';
import 'secure_audiobookshelf_session_store.dart';

/// The single [AudiobookshelfSessionStore] the app reads/writes the
/// Audiobookshelf session through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins (no `flutter_secure_storage`). The running app overrides
/// this with [secureAudiobookshelfSessionStoreOverride] so the tokens persist,
/// at rest, in encrypted storage.
final audiobookshelfSessionStoreProvider =
    Provider<AudiobookshelfSessionStore>((ref) {
  return InMemoryAudiobookshelfSessionStore();
});

/// Production binding: persists the session tokens in encrypted on-device
/// storage. Applied in `main`.
final secureAudiobookshelfSessionStoreOverride =
    audiobookshelfSessionStoreProvider.overrideWithValue(
  const SecureAudiobookshelfSessionStore(),
);
