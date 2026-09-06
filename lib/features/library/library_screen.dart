import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_track_actions.dart';
import '../../core/sources/local/folder_location.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/widgets/empty_state.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import 'folder_browser_providers.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_search.dart';
import 'library_state.dart';
import 'library_sync_activity.dart';
import 'selected_folder_controller.dart';
import 'song_actions.dart';
import 'unified_library_providers.dart';
import 'widgets/album_grid.dart';
import 'widgets/alphabet_track_list.dart';
import 'widgets/artist_grid.dart';
import 'widgets/library_search_field.dart';

/// Browse the de-duplicated catalog across Songs, Albums and Artists.
///
/// All three tabs read the same local catalog and share one search box. The
/// server's real directory hierarchy is not here: it lives on its own top-level
/// [FoldersScreen] destination, so it keeps its place in the tree when you
/// leave it.
///
/// Songs keeps the long-press multi-select and the A–Z fast-scroller from
/// before. Switching tabs clears the query, so a search meant for one tab never
/// silently hides another's contents. Search only filters what is shown — it
/// never touches playback, so the mini-player keeps playing while browsing.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  /// Widest the search box gets on a desktop window.
  static const double _searchFieldMaxWidth = 520;

  final Set<String> _selectedUris = <String>{};
  bool _selecting = false;

  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  int _lastTabIndex = 0;

  /// Pending debounce timer. Cancelled and restarted on every keystroke so the
  /// filter re-runs only once the user pauses typing, not on every character.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Clears the search once per real tab change. The setState is also needed
  /// when entering/leaving Folders, where the catalog search field is hidden.
  void _onTabChanged() {
    if (_tabController.index == _lastTabIndex) return;
    _debounce?.cancel();
    setState(() {
      _lastTabIndex = _tabController.index;
      if (_query.isNotEmpty) {
        _query = '';
        _searchController.clear();
      }
    });
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => setState(() => _query = value),
    );
  }

  void _clearSearch() {
    _debounce?.cancel();
    setState(() {
      _query = '';
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final LibraryState state = ref.watch(libraryControllerProvider);
    // The de-duplicated catalog the whole screen renders from: one row per
    // logical song, even when the same track is served by more than one provider.
    final List<Track> songs = ref.watch(libraryUnifiedTracksProvider);
    final bool hasFolderSources =
        ref.watch(folderBrowsableSourcesProvider).isNotEmpty;
    final AsyncValue<String?> selectedFolder =
        ref.watch(selectedFolderControllerProvider);
    // While a first library sync is running, an empty catalog should read as
    // "filling up", not "nothing here" — so the library never looks broken
    // during onboarding. Covers every server source, not just Jellyfin: Plex
    // exposes no folder hierarchy, so before this a scanning Plex library fell
    // through to the local-folder prompt.
    final List<String> syncingSources = ref.watch(syncingSourceNamesProvider);

    // Drop any selected rows no longer in the catalog (e.g. after a removal) so
    // the count and actions stay accurate. Keyed by the provider-namespaced uri,
    // not the bare id, so two different-provider songs sharing an id can't be
    // selected (or bulk-acted on) together.
    final List<Track> selected = <Track>[
      for (final Track track in songs)
        if (_selectedUris.contains(track.uri)) track,
    ];

    if (_selecting) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, _) {
          if (!didPop) _exitSelection();
        },
        child: Scaffold(
          appBar: _selectionAppBar(selected),
          body: _songsList(_filteredSongs(songs)),
        ),
      );
    }

    // A connected folder-capable server is browseable before (or even without)
    // a flat catalog sync, so it is enough to show the Library tabs on its own.
    final bool browsing = state.status == LibraryStatus.loaded &&
        (songs.isNotEmpty || hasFolderSources);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Select music folder',
            onPressed: _pickAndScan,
          ),
        ],
        bottom: browsing ? _tabBar() : null,
      ),
      body: browsing
          ? _browseBody(songs, syncingSources)
          : _statusBody(state, selectedFolder.valueOrNull, syncingSources),
    );
  }

  PreferredSizeWidget _tabBar() {
    final ThemeData theme = Theme.of(context);
    return TabBar(
      key: const Key('library_tabs'),
      controller: _tabController,
      indicatorColor: theme.colorScheme.secondary,
      indicatorSize: TabBarIndicatorSize.label,
      labelColor: theme.colorScheme.secondary,
      unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
      tabs: const <Widget>[
        Tab(text: 'Songs'),
        Tab(text: 'Albums'),
        Tab(text: 'Artists'),
      ],
    );
  }

  /// Loading / error / folder-pick states, shown full-body without tabs.
  Widget _statusBody(
    LibraryState state,
    String? selectedFolder,
    List<String> syncingSources,
  ) {
    switch (state.status) {
      case LibraryStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case LibraryStatus.error:
        return _LibraryError(
          message: state.errorMessage,
          onRetry: () => ref.read(libraryControllerProvider.notifier).refresh(),
        );
      case LibraryStatus.loaded:
        // A first sync in flight — from any connected server — takes precedence
        // over the folder-pick prompt: tell the user their library is on its way
        // rather than implying it's empty, or (for Plex, which has no folder
        // hierarchy to fall back on) asking them for a folder they don't want.
        final String? headline = syncingHeadline(syncingSources);
        if (headline != null) {
          return _LibrarySyncing(headline: headline);
        }
        return _LibraryEmpty(
          selectedFolder: selectedFolder,
          onPick: _pickAndScan,
          onRescan:
              selectedFolder == null ? null : () => _rescan(selectedFolder),
        );
    }
  }

  /// Catalog search + the three browse tabs.
  Widget _browseBody(List<Track> songs, List<String> syncingSources) {
    // A connected folder-capable server (Jellyfin, Navidrome/Subsonic) shows the
    // tabs the moment it connects, so its *first* sync lands here rather than in
    // [_statusBody]. Pass the syncing sources down so the catalog tabs say
    // "still filling" instead of "nothing in the synced catalog".
    final String? syncHeadline = syncingHeadline(syncingSources);
    return Column(
      children: <Widget>[
        // The box is a text input, not content: on a wide window it stops
        // growing and stays left-aligned under the tabs rather than running
        // the width of a monitor.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _searchFieldMaxWidth),
            child: LibrarySearchField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              onClear: _clearSearch,
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: <Widget>[
              _songsTab(songs, syncHeadline),
              _albumsTab(syncHeadline),
              _artistsTab(syncHeadline),
            ],
          ),
        ),
      ],
    );
  }

  // --- Tabs -------------------------------------------------------------

  Widget _songsTab(List<Track> songs, String? syncHeadline) {
    final List<Track> filtered = _filteredSongs(songs);
    if (filtered.isEmpty) {
      if (_query.isNotEmpty) return const _NoResults();
      if (syncHeadline != null) return _CatalogFilling(headline: syncHeadline);
      return const EmptyState(
        icon: Icons.music_note_outlined,
        title: 'No songs in the synced catalog',
        message: 'You can still browse the connected server from Folders.',
      );
    }
    return _songsList(filtered);
  }

  Widget _albumsTab(String? syncHeadline) {
    final List<Album> filtered =
        filterAlbums(ref.watch(libraryAlbumsProvider), _query);
    if (filtered.isEmpty) {
      if (_query.isNotEmpty) return const _NoResults();
      if (syncHeadline != null) return _CatalogFilling(headline: syncHeadline);
      return const EmptyState(
        icon: Icons.album_outlined,
        title: 'No albums in the synced catalog',
        message: 'You can still browse the connected server from Folders.',
      );
    }
    return AlbumGrid(
      albums: filtered,
      onOpen: (Album album) =>
          context.push(AppRoutes.albumDetailPath(album.id)),
    );
  }

  Widget _artistsTab(String? syncHeadline) {
    final List<Artist> filtered =
        filterArtists(ref.watch(libraryArtistsProvider), _query);
    if (filtered.isEmpty) {
      if (_query.isNotEmpty) return const _NoResults();
      if (syncHeadline != null) return _CatalogFilling(headline: syncHeadline);
      return const EmptyState(
        icon: Icons.person_outline,
        title: 'No artists in the synced catalog',
        message: 'You can still browse the connected server from Folders.',
      );
    }
    return ArtistGrid(
      artists: filtered,
      onOpen: (Artist artist) =>
          context.push(AppRoutes.artistDetailPath(artist.id)),
    );
  }

  List<Track> _filteredSongs(List<Track> songs) => filterTracks(songs, _query);

  Widget _songsList(List<Track> tracks) {
    // Song rows are a single column of text: past [maxContentWidth] the title
    // and the trailing menu end up a screen apart, so the column stops growing
    // and centres instead of stretching across a desktop monitor.
    return AdaptiveContentWidth(
      child: AlphabetTrackList(
        tracks: tracks,
        selectable: true,
        selectionActive: _selecting,
        selectedUris: _selectedUris,
        onSelectStart: _enterSelection,
        onSelectToggle: _toggle,
      ),
    );
  }

  // --- Selection --------------------------------------------------------

  PreferredSizeWidget _selectionAppBar(List<Track> selected) {
    final BulkActionAvailability actions =
        bulkActionsFor(selected, inPlaylist: false);
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelection,
      ),
      title: Text('${selected.length} selected'),
      actions: <Widget>[
        if (actions.canAddToPlaylist)
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add to playlist',
            onPressed: selected.isEmpty ? null : () => _addToPlaylist(selected),
          ),
        if (actions.canRemoveOfflineCopy)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove offline copies',
            onPressed: selected.isEmpty ? null : () => _removeOffline(selected),
          ),
        if (actions.canRemoveFromLibrary)
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Remove from Linthra',
            onPressed:
                selected.isEmpty ? null : () => _removeFromLibrary(selected),
          ),
      ],
    );
  }

  void _enterSelection(Track track) {
    setState(() {
      _selecting = true;
      _selectedUris
        ..clear()
        ..add(track.uri);
    });
  }

  void _toggle(Track track) {
    setState(() {
      if (!_selectedUris.add(track.uri)) {
        _selectedUris.remove(track.uri);
      }
      if (_selectedUris.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedUris.clear();
    });
  }

  Future<void> _addToPlaylist(List<Track> selected) async {
    await showAddToPlaylistSheet(context, selected);
    _exitSelection();
  }

  Future<void> _removeFromLibrary(List<Track> selected) async {
    // Removing a logical row forgets every provider copy of the song, so a
    // hidden duplicate can't resurrect the row on the next reload.
    final bool removed = await SongActions.removeFromLibrary(
      context,
      ref,
      selected,
      expandLogicalSources: true,
    );
    if (removed) _exitSelection();
  }

  Future<void> _removeOffline(List<Track> selected) async {
    final bool ran =
        await SongActions.removeOfflineCopies(context, ref, selected);
    if (ran) _exitSelection();
  }

  // --- Scan -------------------------------------------------------------

  /// Open the system folder picker, persist the choice, then scan it. A
  /// cancelled pick leaves everything untouched. The UI only talks to the two
  /// controllers — never to a picker plugin or the file system directly.
  Future<void> _pickAndScan() async {
    final String? path = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndPersist();
    if (path != null) {
      await ref.read(libraryControllerProvider.notifier).scanFolder(path);
    }
  }

  /// Re-scan the folder the user already selected, without opening the picker.
  Future<void> _rescan(String folder) {
    return ref.read(libraryControllerProvider.notifier).scanFolder(folder);
  }
}

/// The catalog-tab counterpart to [_LibrarySyncing], for the case where a
/// folder-capable server is connected (so the tabs are already showing) but its
/// first sync hasn't landed any tracks yet. Says the catalog is still filling
/// rather than that it is empty, and still points at Folders — which *is*
/// browseable right now, ahead of the sync.
class _CatalogFilling extends StatelessWidget {
  const _CatalogFilling({required this.headline});

  final String headline;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.sync_outlined,
      title: headline,
      message: 'Your songs will appear here as soon as they’re in. '
          'You can browse the connected server from Folders meanwhile.',
    );
  }
}

/// The "no search matches" state, shown when a query filters every row out of
/// the active tab. Deliberately friendly and identical across tabs.
class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.search_off,
      title: 'No results found.',
      message: 'Try a different search.',
    );
  }
}

/// Shown when the catalog is still empty but a first library sync is running,
/// so onboarding reads as "your library is on its way" rather than "nothing
/// here". Replaced automatically once the synced tracks land.
///
/// [headline] names the syncing source when exactly one is running and stays
/// general when several are — see `syncingHeadline`.
class _LibrarySyncing extends StatelessWidget {
  const _LibrarySyncing({required this.headline});

  final String headline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              headline,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'This may take a moment. Your songs will appear here as soon as '
              "they're in.",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// The empty state, split by which local source is selected so the user always
/// sees the right next step:
///  - nothing chosen → invite them to pick a folder;
///  - a folder chosen but nothing found → show the folder and offer a re-scan
///    or a change of folder;
///  - Android's device-wide MediaStore library chosen → there is no folder to
///    reselect, so say the device reported no music and offer a rescan.
class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({
    required this.selectedFolder,
    required this.onPick,
    this.onRescan,
  });

  final String? selectedFolder;
  final VoidCallback onPick;
  final VoidCallback? onRescan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFolder = selectedFolder != null;
    final FolderLocation? location =
        hasFolder ? FolderLocation.parse(selectedFolder!) : null;
    final bool isDeviceLibrary = location?.isAndroidMediaStore ?? false;
    // A folder selected as a plain filesystem path on Android is the legacy/
    // broken case: scoped storage won't let Linthra read it, so it turns up
    // empty. Nudge the user to pick it again, which now returns a SAF grant.
    // The MediaStore sentinel is not a path, so it must not land here.
    final bool needsRepick =
        hasFolder && Platform.isAndroid && location!.isFilesystemPath;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasFolder
                  ? Icons.library_music_outlined
                  : Icons.folder_off_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              hasFolder ? 'No music found' : 'No music folder selected',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              isDeviceLibrary
                  ? "Android's music library reported no audio on this device."
                  : hasFolder
                      ? 'Nothing playable turned up in:\n'
                          '${location!.displayLabel}'
                      : 'Choose a folder on your device to scan for music.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
            if (needsRepick) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Choose the folder again so Linthra can read it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            if (hasFolder) ...[
              FilledButton.tonal(
                onPressed: onRescan,
                child: Text(
                  isDeviceLibrary ? 'Rescan this device' : 'Rescan folder',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: onPick,
                child: Text(
                  isDeviceLibrary ? 'Use a folder instead' : 'Change folder',
                ),
              ),
            ] else
              FilledButton(
                onPressed: onPick,
                child: const Text('Select a folder'),
              ),
          ],
        ),
      ),
    );
  }
}

class _LibraryError extends StatelessWidget {
  const _LibraryError({required this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: AppSpacing.md),
            Text(
              "Couldn't load your library",
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
