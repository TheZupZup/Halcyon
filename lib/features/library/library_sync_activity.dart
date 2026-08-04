import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sources/music_provider.dart';
import '../settings/jellyfin/jellyfin_sync_controller.dart';
import '../settings/plex/plex_sync_controller.dart';
import '../settings/subsonic/subsonic_sync_controller.dart';

/// The display names of every music source whose library sync is running right
/// now, in a stable order (Jellyfin, Navidrome/Subsonic, Plex).
///
/// The Library screen uses this to tell a filling-up catalog apart from an
/// empty one, so a first sync never reads as "you have no music" — and, for
/// Plex, never as the local-folder prompt (Plex exposes no folder hierarchy, so
/// before this the screen fell all the way through to "No music folder
/// selected" while the library was actively scanning).
///
/// It reads the three existing sync controllers and nothing else: no provider
/// API changes, no new state. Each is `select`ed down to its own boolean, so a
/// sync's status *message* changing mid-run never rebuilds the Library.
///
/// Scope note: every provider's state exposes "a sync is running", not "the
/// *first* sync is running" — that distinction lives in the controllers' own
/// auto-sync fingerprints and isn't reachable from a state object. The Library
/// only consults this while its catalog is still empty, which makes the two
/// equivalent in practice: a re-sync of a library that already has tracks never
/// reaches these call sites.
final syncingSourceNamesProvider = Provider<List<String>>((ref) {
  final bool jellyfin = ref.watch(
    jellyfinSyncControllerProvider.select((state) => state.isSyncing),
  );
  final bool subsonic = ref.watch(
    subsonicSyncControllerProvider.select((state) => state.isSyncing),
  );
  // Plex's `isSyncing` spans both of its phases — scanning the server and
  // writing the results — which is exactly the window the catalog is empty in.
  final bool plex = ref.watch(
    plexSyncControllerProvider.select((state) => state.isSyncing),
  );

  return <String>[
    if (jellyfin) MusicProviders.jellyfin.displayName,
    if (subsonic) MusicProviders.subsonic.displayName,
    if (plex) MusicProviders.plex.displayName,
  ];
});

/// The headline for a catalog that is filling up, given the sources currently
/// syncing. Named per-provider when exactly one is running ("Your Jellyfin
/// library is syncing") and kept general when several are, so the line is
/// always true without listing servers.
///
/// Returns null when nothing is syncing, so callers can fall through to their
/// normal empty state.
String? syncingHeadline(List<String> sourceNames) {
  if (sourceNames.isEmpty) return null;
  if (sourceNames.length == 1) {
    return 'Your ${sourceNames.single} library is syncing';
  }
  return 'Your libraries are syncing';
}
