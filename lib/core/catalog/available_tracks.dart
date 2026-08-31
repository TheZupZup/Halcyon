import '../models/track.dart';
import 'track_identity.dart';

/// Narrows the stored catalog to the tracks that are actually usable right now,
/// by holding back the rows that belong to a source Linthra currently cannot
/// reach.
///
/// This is the *source-availability layer* the rest of the app filters at — one
/// pure function over the catalog, applied once before de-duplication, so every
/// browse surface (Songs, Albums, Artists, search, the detail screens, the
/// playback-candidate map) agrees without any of them knowing what a "Jellyfin"
/// is. It is deliberately not a UI concern: filtering in a widget would leave
/// the grouping, search index, and fallback candidates disagreeing with what is
/// on screen.
///
/// Three properties matter, and are what the tests pin down:
///
///  * **Nothing is deleted.** This returns a view. The repository still holds
///    every row, and the moment [unavailableSourceIds] empties the full catalog
///    is back — no re-sync, no re-scan, no reconnect.
///  * **Local music is untouched.** Only the named sources are held back, so a
///    device library stays complete while a server is away.
///  * **A downloaded copy still counts.** A track from an unreachable source
///    that has been made available offline plays fine without the server, so
///    [isAvailableOffline] keeps it — hiding it would take away music the user
///    downloaded precisely for this situation.
///
/// When [unavailableSourceIds] is empty the input list is returned as-is, so the
/// everyday path costs nothing.
List<Track> selectAvailableTracks(
  List<Track> tracks, {
  required Set<String> unavailableSourceIds,
  required bool Function(Track track) isAvailableOffline,
}) {
  if (unavailableSourceIds.isEmpty) return tracks;
  return <Track>[
    for (final Track track in tracks)
      if (!unavailableSourceIds.contains(trackSourceId(track)) ||
          isAvailableOffline(track))
        track,
  ];
}

/// How many of [tracks] [selectAvailableTracks] would hold back — the count
/// diagnostics reports so a bug report shows *why* a library looks short,
/// instead of leaving the user to guess.
int countUnavailableTracks(
  List<Track> tracks, {
  required Set<String> unavailableSourceIds,
  required bool Function(Track track) isAvailableOffline,
}) {
  if (unavailableSourceIds.isEmpty) return 0;
  int hidden = 0;
  for (final Track track in tracks) {
    if (unavailableSourceIds.contains(trackSourceId(track)) &&
        !isAvailableOffline(track)) {
      hidden++;
    }
  }
  return hidden;
}
