import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import '../../core/platform/host_platform.dart';
import '../../core/repositories/playback_session_store.dart';
import '../../core/services/playback_session_persistence.dart';
import '../../core/sources/music_provider.dart';
import '../../features/player/player_providers.dart';
import '../../features/settings/jellyfin/jellyfin_settings_controller.dart';
import '../../features/settings/plex/plex_settings_controller.dart';
import '../../features/settings/subsonic/subsonic_settings_controller.dart';
import 'host_platform_provider.dart';
import 'in_memory_playback_session_store.dart';
import 'shared_preferences_playback_session_store.dart';

/// Durable store of the crash-safe playback session. Defaults to in-memory so
/// tests and non-Linux hosts need no plugins; Linux production overrides it
/// with the `shared_preferences` binding below.
final playbackSessionStoreProvider = Provider<PlaybackSessionStore>((ref) {
  return InMemoryPlaybackSessionStore();
});

/// Production binding: persist the playback session via `shared_preferences`
/// so an unexpected restart can restore the logical queue. Applied in `main`
/// on Linux only; other platforms keep the in-memory default (no restore).
final sharedPreferencesPlaybackSessionStoreOverride =
    playbackSessionStoreProvider.overrideWithValue(
  const SharedPreferencesPlaybackSessionStore(),
);

/// Crash-safe playback session persistence + restore.
///
/// Constructed only on Linux: it listens to the local engine's state stream,
/// writes logical sessions, and restores them paused on startup. Returns
/// `null` on other platforms so Android behaviour is unchanged. Side-effect
/// only; `main` instantiates it once and awaits
/// [PlaybackSessionPersistence.restore].
final playbackSessionPersistenceProvider =
    Provider<PlaybackSessionPersistence?>((ref) {
  if (ref.watch(hostPlatformProvider) != HostPlatform.linux) {
    return null;
  }

  final PlaybackSessionPersistence service = PlaybackSessionPersistence(
    store: ref.watch(playbackSessionStoreProvider),
    controller: ref.read(localPlaybackControllerProvider),
    playbackStates: ref.read(localPlaybackControllerProvider).stateStream,
    isRemoteProviderAvailable: (MusicProvider provider) {
      if (identical(provider, MusicProviders.jellyfin)) {
        return ref.read(jellyfinMusicSourceProvider) != null;
      }
      if (identical(provider, MusicProviders.subsonic)) {
        return ref.read(subsonicMusicSourceProvider) != null;
      }
      if (identical(provider, MusicProviders.plex)) {
        return ref.read(plexMusicSourceProvider) != null;
      }
      return true;
    },
  );
  ref.onDisposeAsync(service.dispose);
  return service;
});
