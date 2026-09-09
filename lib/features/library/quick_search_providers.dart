import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playlist.dart';
import '../playlists/playlist_providers.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'quick_search.dart';
import 'unified_library_providers.dart';

/// Whether the catalog quick search reads is still loading, so the overlay can
/// say "still loading" instead of "no results" on a cold start.
final quickSearchLoadingProvider = Provider<bool>((ref) {
  return ref.watch(
    libraryControllerProvider.select(
      (LibraryState state) => state.status == LibraryStatus.loading,
    ),
  );
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
