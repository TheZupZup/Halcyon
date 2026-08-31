import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/available_tracks.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_store.dart';
import '../../core/sources/music_provider.dart';
import '../../core/sources/source_availability.dart';
import '../downloads/download_providers.dart';
import '../settings/jellyfin/jellyfin_availability_controller.dart';
import 'library_controller.dart';

/// Live availability per source id — the honest answer to "can Linthra reach
/// this right now?", as opposed to "is it configured?".
///
/// Only Jellyfin reports a real probe today (the source this addresses); the
/// on-device library is always available, and the other servers keep their
/// previous behaviour until they adopt the same probe. Every source that is not
/// listed is treated as available, so adding one is opt-in and can never
/// accidentally hide a library.
final sourceAvailabilityProvider =
    Provider<Map<String, SourceAvailability>>((ref) {
  return <String, SourceAvailability>{
    MusicProviders.jellyfin.sourceId: ref.watch(jellyfinAvailabilityProvider).status,
  };
});

/// The source ids whose streamed tracks are currently held out of the active
/// library. Empty in the ordinary case, which makes the filter below a no-op.
final unavailableSourceIdsProvider = Provider<Set<String>>((ref) {
  final Map<String, SourceAvailability> availability =
      ref.watch(sourceAvailabilityProvider);
  return <String>{
    for (final MapEntry<String, SourceAvailability> entry in availability.entries)
      if (entry.value.hidesTracks) entry.key,
  };
});

/// A predicate for "this track plays without its server", derived from the live
/// offline-cache set. Keyed provider-aware so a downloaded `jellyfin:101` never
/// makes a different provider's `101` look downloaded.
final _offlineAvailabilityProvider =
    Provider<bool Function(Track track)>((ref) {
  final Set<String> keys = ref.watch(offlineAvailableTrackKeysProvider);
  if (keys.isEmpty) return (Track _) => false;
  return (Track track) => keys.contains(CachedTrack.cacheKeyForTrack(track));
});

/// The **active library**: every stored track except those belonging to a source
/// that is currently unreachable and that has no offline copy.
///
/// This is the single seam between "what the catalog holds" and "what the app
/// shows and plays". It sits above the repository and below de-duplication, so:
///
///  * the repository keeps every row, every playlist, every favourite and every
///    download — an unreachable server hides its music, it never loses it;
///  * grouping, search and the playback-candidate map all see the same set, so
///    an Album can't list a track the Songs tab hides;
///  * the moment the server answers again the full catalog is back, with no
///    reconnect and no rescan, because nothing was ever removed to restore.
final activeLibraryTracksProvider = Provider<List<Track>>((ref) {
  final List<Track> tracks = ref.watch(libraryControllerProvider).tracks;
  final Set<String> unavailable = ref.watch(unavailableSourceIdsProvider);
  if (unavailable.isEmpty) return tracks;
  return selectAvailableTracks(
    tracks,
    unavailableSourceIds: unavailable,
    isAvailableOffline: ref.watch(_offlineAvailabilityProvider),
  );
});

/// How many stored tracks the active library is currently holding back. Zero in
/// the ordinary case; reported in diagnostics so a short library explains itself.
final unavailableTrackCountProvider = Provider<int>((ref) {
  final Set<String> unavailable = ref.watch(unavailableSourceIdsProvider);
  if (unavailable.isEmpty) return 0;
  return countUnavailableTracks(
    ref.watch(libraryControllerProvider).tracks,
    unavailableSourceIds: unavailable,
    isAvailableOffline: ref.watch(_offlineAvailabilityProvider),
  );
});
