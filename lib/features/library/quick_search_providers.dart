import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playlist.dart';
import '../playlists/playlist_providers.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'quick_search.dart';
import 'unified_library_providers.dart';

/// How much of what quick search reads is actually there right now.
///
/// Zero results mean three very different things, and saying the wrong one is
/// what makes a user think their music is gone: [loading] is "ask again in a
/// moment", [degraded] is "we couldn't read part of your library", and only
/// [ready] earns an honest "nothing matched".
enum QuickSearchAvailability {
  /// Everything quick search searches is loaded.
  ready,

  /// The catalog or the playlist list has not resolved yet.
  loading,

  /// Something failed to load, so an empty result set is not evidence of
  /// anything. The results that *did* load are still shown.
  degraded,
}

/// Whether the catalog and playlists quick search reads are available.
///
/// Both sources count: the catalog is the bulk of it, but a playlist-name query
/// during startup would otherwise be answered "no results" from a playlist
/// stream that simply had not emitted yet — and after a store failure it would
/// answer that forever.
final quickSearchAvailabilityProvider =
    Provider<QuickSearchAvailability>((ref) {
  final LibraryStatus catalog = ref.watch(
    libraryControllerProvider.select((LibraryState state) => state.status),
  );
  final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);

  if (catalog == LibraryStatus.error || playlists.hasError) {
    return QuickSearchAvailability.degraded;
  }
  if (catalog == LibraryStatus.loading || playlists.isLoading) {
    return QuickSearchAvailability.loading;
  }
  return QuickSearchAvailability.ready;
});

/// Ranked quick-search results for one query.
///
/// It reads the same providers the Library screen browses — the unified
/// (de-duplicated) catalog, the albums and artists derived from it, and the
/// user's playlists — so quick search can never disagree with what the Library
/// shows, and no second catalog exists to keep in sync.
///
/// Auto-disposing keeps one query's ranking alive only while the overlay is
/// showing it: the results are cached across rebuilds (resize, theme change,
/// focus moving) but a session's worth of typed prefixes is not retained after
/// the overlay closes.
///
/// A source that failed or has not arrived contributes nothing here rather than
/// blocking the ones that did load — a Jellyfin outage should not hide the local
/// songs. [quickSearchAvailabilityProvider] is what keeps that honest, by
/// telling the overlay not to call the shortfall "no results".
final quickSearchResultsProvider =
    Provider.autoDispose.family<QuickSearchResults, String>((ref, query) {
  if (query.trim().isEmpty) return QuickSearchResults.empty;
  return runQuickSearch(
    query: query,
    tracks: ref.watch(libraryUnifiedTracksProvider),
    albums: ref.watch(libraryAlbumsProvider),
    artists: ref.watch(libraryArtistsProvider),
    playlists: ref.watch(playlistsProvider).valueOrNull ?? const <Playlist>[],
  );
});
