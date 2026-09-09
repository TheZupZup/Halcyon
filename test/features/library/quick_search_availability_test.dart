import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/playlist_store.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/quick_search_providers.dart';
import 'package:linthra/features/library/widgets/quick_search_overlay.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

/// A store whose stream fails, standing in for a playlist backend that cannot
/// be read — the case where an empty playlist list is not a fact about the
/// user's playlists.
class _FailingPlaylistStore implements PlaylistStore {
  @override
  Future<List<Playlist>> load() async => throw StateError('store unavailable');

  @override
  Future<void> save(List<Playlist> playlists) async {}
}

const List<Track> _tracks = <Track>[
  Track(id: '1', title: 'Get Lucky', uri: 'file:///1.mp3'),
];

Future<ProviderContainer> _container(
  WidgetTester tester, {
  Object? catalogError,
  PlaylistStore? playlistStore,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(
        FakeMusicLibraryRepository(
          tracks: catalogError == null ? _tracks : const <Track>[],
          error: catalogError,
        ),
      ),
      playlistStoreProvider
          .overrideWithValue(playlistStore ?? InMemoryPlaylistStore()),
      playbackControllerProvider.overrideWithValue(FakePlaybackController()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('quickSearchAvailabilityProvider', () {
    testWidgets('moves from loading to ready as the sources resolve',
        (tester) async {
      final ProviderContainer container = await _container(tester);
      container.listen(
        quickSearchAvailabilityProvider,
        (_, __) {},
        fireImmediately: true,
      );

      expect(
        container.read(quickSearchAvailabilityProvider),
        QuickSearchAvailability.loading,
        reason: 'a cold start must not answer queries with "no results"',
      );

      await tester.pumpAndSettle();

      expect(
        container.read(quickSearchAvailabilityProvider),
        QuickSearchAvailability.ready,
      );
    });

    testWidgets('reports degraded when the catalog fails to load',
        (tester) async {
      final ProviderContainer container =
          await _container(tester, catalogError: StateError('disk gone'));
      container.listen(
        quickSearchAvailabilityProvider,
        (_, __) {},
        fireImmediately: true,
      );
      await tester.pumpAndSettle();

      expect(
        container.read(quickSearchAvailabilityProvider),
        QuickSearchAvailability.degraded,
        reason: 'an empty catalog after an error is not an empty library',
      );
    });

    testWidgets('reports degraded when the playlist store fails',
        (tester) async {
      final ProviderContainer container =
          await _container(tester, playlistStore: _FailingPlaylistStore());
      container.listen(
        quickSearchAvailabilityProvider,
        (_, __) {},
        fireImmediately: true,
      );
      await tester.pumpAndSettle();

      expect(
        container.read(quickSearchAvailabilityProvider),
        QuickSearchAvailability.degraded,
      );
    });
  });

  group('QuickSearchOverlay when the library is unavailable', () {
    testWidgets('says so instead of claiming there are no results',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            musicLibraryRepositoryProvider.overrideWithValue(
              FakeMusicLibraryRepository(error: StateError('disk gone')),
            ),
            playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
            playbackControllerProvider
                .overrideWithValue(FakePlaybackController()),
          ],
          child: const MaterialApp(home: QuickSearchOverlay()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('quick_search_field')),
        'anything',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('quick_search_unavailable')), findsOneWidget);
      expect(find.byKey(const Key('quick_search_no_results')), findsNothing);
    });
  });
}
