import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/favorites/favorites_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.favorites,
    routes: [
      GoRoute(
        path: AppRoutes.favorites,
        builder: (_, __) => const FavoritesScreen(),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const PlayerScreen(),
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<Track> tracks,
  required FavoritesData favorites,
  FakePlaybackController? playback,
  Object? libraryError,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: tracks, error: libraryError),
        ),
        favoritesStoreProvider
            .overrideWithValue(InMemoryFavoritesStore(favorites)),
        if (playback != null)
          playbackControllerProvider.overrideWithValue(playback),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('FavoritesScreen', () {
    testWidgets('lists only favourited tracks, local and Jellyfin', (
      tester,
    ) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'local1', title: 'Alpha', uri: 'file:///a.mp3'),
          Track(id: 'remote1', title: 'Bravo', uri: 'jellyfin:remote1'),
          Track(id: 'other', title: 'Charlie', uri: 'file:///c.mp3'),
        ],
        favorites: const FavoritesData(
          localIds: {'file:///a.mp3'},
          remoteIds: {'jellyfin:remote1'},
        ),
      );

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      // A non-favourited track from the catalog is not shown.
      expect(find.text('Charlie'), findsNothing);
    });

    testWidgets('shows an empty state when nothing is favourited', (
      tester,
    ) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'local1', title: 'Alpha', uri: 'file:///a.mp3'),
        ],
        favorites: FavoritesData.empty,
      );

      expect(find.text('No favorites yet'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      // The instruction must name a control that actually exists on a row.
      expect(
        find.text('Tap the heart on any song to save it here.'),
        findsOneWidget,
      );
      // Nothing to play, so the header doesn't appear either.
      expect(find.text('Play'), findsNothing);
      expect(find.text('Shuffle'), findsNothing);
    });

    testWidgets('shows a friendly error state when the catalog fails to load', (
      tester,
    ) async {
      // A non-empty favourite set forces the catalog read, which then fails.
      await _pump(
        tester,
        tracks: const <Track>[],
        favorites: const FavoritesData(remoteIds: {'jellyfin:j1'}),
        libraryError: Exception('boom'),
      );

      expect(find.text("Couldn't load your favorites"), findsOneWidget);
      // The raw error is never surfaced.
      expect(find.textContaining('boom'), findsNothing);
    });

    testWidgets('tapping a favourite plays it and queues the rest', (
      tester,
    ) async {
      final controller = FakePlaybackController();
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'a', title: 'Alpha', uri: 'file:///a.mp3'),
          Track(id: 'b', title: 'Bravo', uri: 'file:///b.mp3'),
          Track(id: 'c', title: 'Charlie', uri: 'file:///c.mp3'),
        ],
        favorites: const FavoritesData(
            localIds: {'file:///a.mp3', 'file:///b.mp3', 'file:///c.mp3'}),
        playback: controller,
      );

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      // The tapped track plays and the rest of the list (sorted by title)
      // follows it in the up-next queue.
      expect(controller.state.currentTrack?.id, 'a');
      expect(
        controller.state.upNext.map((t) => t.id).toList(),
        ['b', 'c'],
      );
    });
  });

  group('FavoritesScreen Play / Shuffle', () {
    testWidgets('Play starts the whole list in order and opens the player',
        (tester) async {
      final controller = FakePlaybackController();
      await _pump(
        tester,
        tracks: _threeTracks,
        favorites: _allThreeFavorited,
        playback: controller,
      );

      expect(find.text('3 songs'), findsOneWidget);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.state.upNext.map((t) => t.id).toList(), ['b', 'c']);
      expect(controller.state.shuffleEnabled, isFalse);
      // Matches Album and Playlist detail, which both push the player.
      expect(find.byType(PlayerScreen), findsOneWidget);
    });

    testWidgets('Shuffle enables shuffle before playing', (tester) async {
      final controller = FakePlaybackController();
      await _pump(
        tester,
        tracks: _threeTracks,
        favorites: _allThreeFavorited,
        playback: controller,
      );

      await tester.tap(find.text('Shuffle'));
      await tester.pumpAndSettle();

      expect(controller.state.shuffleEnabled, isTrue);
      // Shuffle randomises the queue, so assert the mode and that something
      // started — not which specific track won.
      expect(controller.playedTracks, isNotEmpty);
      expect(find.byType(PlayerScreen), findsOneWidget);
    });

    testWidgets('a single favourite reads "1 song"', (tester) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'a', title: 'Alpha', uri: 'file:///a.mp3'),
        ],
        favorites: const FavoritesData(localIds: {'file:///a.mp3'}),
      );

      expect(find.text('1 song'), findsOneWidget);
    });
  });

  group('FavoritesScreen multi-select', () {
    testWidgets('long-press enters selection and shows the count',
        (tester) async {
      await _pump(
        tester,
        tracks: _threeTracks,
        favorites: _allThreeFavorited,
      );

      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byTooltip('Add to playlist'), findsOneWidget);
      expect(find.byTooltip('Cancel selection'), findsOneWidget);
      // The Play/Shuffle header steps aside while selecting.
      expect(find.text('Play'), findsNothing);
      expect(find.text('Shuffle'), findsNothing);
    });

    testWidgets('tapping more rows while selecting extends the selection',
        (tester) async {
      await _pump(
        tester,
        tracks: _threeTracks,
        favorites: _allThreeFavorited,
      );

      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bravo'));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
      // A tap during selection must not start playback.
      expect(find.byType(PlayerScreen), findsNothing);
    });

    testWidgets('deselecting the last row leaves selection mode',
        (tester) async {
      await _pump(
        tester,
        tracks: _threeTracks,
        favorites: _allThreeFavorited,
      );

      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsNothing);
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
    });

    testWidgets('Cancel selection restores the normal app bar', (tester) async {
      await _pump(
        tester,
        tracks: _threeTracks,
        favorites: _allThreeFavorited,
      );

      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsNothing);
      expect(find.text('Favorites'), findsOneWidget);
    });
  });

  group('FavoritesScreen heart', () {
    testWidgets('rows show a filled heart, and unfavoriting drops the row',
        (tester) async {
      await _pump(
        tester,
        tracks: _threeTracks,
        favorites: _allThreeFavorited,
      );

      // Everything here is a favourite by definition.
      expect(find.byTooltip('Remove from favorites'), findsNWidgets(3));

      await tester.tap(find.byTooltip('Remove from favorites').first);
      await tester.pumpAndSettle();

      // Alpha sorts first, so the first heart is Alpha's; it leaves the list.
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('2 songs'), findsOneWidget);
    });

    testWidgets('unfavoriting the last row falls back to the empty state',
        (tester) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'a', title: 'Alpha', uri: 'file:///a.mp3'),
        ],
        favorites: const FavoritesData(localIds: {'file:///a.mp3'}),
      );

      await tester.tap(find.byTooltip('Remove from favorites'));
      await tester.pumpAndSettle();

      expect(find.text('No favorites yet'), findsOneWidget);
      expect(
        find.text('Tap the heart on any song to save it here.'),
        findsOneWidget,
      );
    });
  });
}

/// Deliberately *not* in alphabetical order: the list sorts by title, so this
/// catches a Play button that queues the raw catalog order instead of the order
/// the user is looking at.
const List<Track> _threeTracks = <Track>[
  Track(id: 'c', title: 'Charlie', uri: 'file:///c.mp3'),
  Track(id: 'a', title: 'Alpha', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Bravo', uri: 'file:///b.mp3'),
];

const FavoritesData _allThreeFavorited = FavoritesData(
  localIds: <String>{'file:///a.mp3', 'file:///b.mp3', 'file:///c.mp3'},
);
