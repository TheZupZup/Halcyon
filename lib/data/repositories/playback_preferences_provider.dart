import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import '../../core/repositories/playback_preferences.dart';
import '../../core/services/playback_volume_persistence.dart';
import '../../features/player/player_providers.dart';
import 'host_platform_provider.dart';
import 'in_memory_playback_preferences.dart';
import 'shared_preferences_playback_preferences.dart';

/// The user's playback preferences ("Normalize volume" and the desktop playback
/// volume). In-memory by default so tests and dev runs need no plugins; the app
/// persists them via `shared_preferences` through
/// [sharedPreferencesPlaybackPreferencesOverride].
final playbackPreferencesProvider = Provider<PlaybackPreferences>((ref) {
  return InMemoryPlaybackPreferences();
});

final sharedPreferencesPlaybackPreferencesOverride =
    playbackPreferencesProvider.overrideWithValue(
  const SharedPreferencesPlaybackPreferences(),
);

/// Remembers the playback volume across launches, and restores it at startup.
///
/// Desktop only, because the volume controls are: a phone's volume is the
/// system's, set with its hardware keys, so Android and iOS keep playing at the
/// engine's full level exactly as before. Returns `null` elsewhere.
/// Side-effect only; `main` instantiates it once and awaits
/// [PlaybackVolumePersistence.restore].
final playbackVolumePersistenceProvider =
    Provider<PlaybackVolumePersistence?>((ref) {
  if (!ref.watch(hostPlatformProvider).isDesktop) return null;

  final PlaybackVolumePersistence service = PlaybackVolumePersistence(
    preferences: ref.watch(playbackPreferencesProvider),
    // The routing controller, so a level set while casting is still stored and
    // restored — it is the device's own volume either way.
    controller: ref.read(playbackControllerProvider),
    playbackStates: ref.read(playbackControllerProvider).stateStream,
  );
  ref.onDisposeAsync(service.dispose);
  return service;
});
