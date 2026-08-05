import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_track_actions.dart';
import '../../shared/widgets/empty_state.dart';
import '../library/song_actions.dart';
import '../library/track_selection.dart';
import '../library/widgets/alphabet_track_list.dart';
import '../player/player_providers.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import 'favorites_controller.dart';

/// The Favorites library view: every track the user has liked, local or from a
/// connected server. Reads entirely from [favoriteTracksProvider] and reuses the
/// same [AlphabetTrackList]/`TrackTile` rows as the main library, so tapping a
/// favourite plays it and queues the rest behind it — unchanged from the
/// library.
///
/// Brought to parity with Album and Playlist detail: a Play / Shuffle header
/// over the list, and the same long-press multi-select the rest of the app has.
/// Selection bookkeeping comes from [TrackSelectionMixin] and the available
/// actions from [bulkActionsFor], so this screen adds no selection rules of its
/// own — a favourite behaves in a bulk action exactly as it does in the library.
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen>
    with TrackSelectionMixin<FavoritesScreen> {
  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Track>> favorites =
        ref.watch(favoriteTracksProvider);

    return favorites.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Favorites')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => Scaffold(
        appBar: AppBar(title: const Text('Favorites')),
        body: const _FavoritesError(),
      ),
      data: (List<Track> tracks) => _body(tracks),
    );
  }

  Widget _body(List<Track> tracks) {
    if (tracks.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Favorites')),
        body: const EmptyState(
          icon: Icons.favorite_border,
          title: 'No favorites yet',
          // Accurate as of the visible heart on every track row: this is the
          // control the sentence points at, not the overflow menu it used to
          // mean.
          message: 'Tap the heart on any song to save it here.',
        ),
      );
    }

    // The order the rows actually appear in. Play / Shuffle queue this, not the
    // catalog order the provider returned, so the header agrees with the list
    // beneath it — and with what tapping a row already does.
    final List<Track> ordered = AlphabetTrackList.sortedByTitle(tracks);

    // Resolve against the live list, so a track that stops being a favourite
    // (or leaves the catalog) while selected simply drops out of the count and
    // the available actions.
    final List<Track> selected = selectedFrom(ordered);

    final Widget scaffold = Scaffold(
      appBar: selectionActive
          ? _selectionAppBar(selected)
          : AppBar(title: const Text('Favorites')),
      body: Column(
        children: <Widget>[
          if (!selectionActive)
            _FavoritesHeader(
              trackCount: ordered.length,
              onPlay: () => _play(ordered),
              onShuffle: () => _shuffle(ordered),
            ),
          Expanded(
            child: AlphabetTrackList(
              tracks: ordered,
              selectable: true,
              selectionActive: selectionActive,
              selectedUris: selectedUris,
              onSelectStart: startSelection,
              onSelectToggle: toggleSelection,
            ),
          ),
        ],
      ),
    );

    if (!selectionActive) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) exitSelection();
      },
      child: scaffold,
    );
  }

  /// The same selection app bar the Library offers, driven by the shared
  /// [bulkActionsFor] rules so a mixed-source selection automatically hides any
  /// action that wouldn't be safe for all of it.
  PreferredSizeWidget _selectionAppBar(List<Track> selected) {
    final BulkActionAvailability actions =
        bulkActionsFor(selected, inPlaylist: false);
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: exitSelection,
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

  void _play(List<Track> tracks) {
    ref.read(playbackControllerProvider).playTracks(tracks);
    context.push(AppRoutes.player);
  }

  void _shuffle(List<Track> tracks) {
    final controller = ref.read(playbackControllerProvider);
    controller.setShuffleEnabled(true);
    controller.playTracks(tracks);
    context.push(AppRoutes.player);
  }

  Future<void> _addToPlaylist(List<Track> selected) async {
    await showAddToPlaylistSheet(context, selected);
    exitSelection();
  }

  Future<void> _removeOffline(List<Track> selected) async {
    final bool ran =
        await SongActions.removeOfflineCopies(context, ref, selected);
    if (ran) exitSelection();
  }

  Future<void> _removeFromLibrary(List<Track> selected) async {
    // Same shared, confirmed action the Library uses — including expanding a
    // logical row to every provider copy, so a hidden duplicate can't resurrect
    // the row (and its heart) on the next reload.
    final bool removed = await SongActions.removeFromLibrary(
      context,
      ref,
      selected,
      expandLogicalSources: true,
    );
    if (removed) exitSelection();
  }
}

/// The Play / Shuffle header, matching Album and Playlist detail so the three
/// list screens start playback the same way.
class _FavoritesHeader extends StatelessWidget {
  const _FavoritesHeader({
    required this.trackCount,
    required this.onPlay,
    required this.onShuffle,
  });

  final int trackCount;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String count = trackCount == 1 ? '1 song' : '$trackCount songs';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            count,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onShuffle,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FavoritesError extends StatelessWidget {
  const _FavoritesError();

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
              "Couldn't load your favorites",
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
