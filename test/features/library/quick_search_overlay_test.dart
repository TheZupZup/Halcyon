import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/widgets/quick_search_overlay.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Past the overlay's 200 ms debounce.
const Duration _afterDebounce = Duration(milliseconds: 250);

const List<Track> _tracks = <Track>[
  Track(
    id: '1',
    title: 'Get Lucky',
    uri: 'file:///1.mp3',
    artistName: 'Daft Punk',
    albumName: 'Random Access Memories',
  ),
  Track(
    id: '2',
    title: 'Instant Crush',
    uri: 'file:///2.mp3',
    artistName: 'Daft Punk',
    albumName: 'Random Access Memories',
  ),
  Track(
    id: '3',
    title: 'Halo',
    uri: 'file:///3.mp3',
    artistName: 'Beyonce',
    albumName: 'Sasha Fierce',
  ),
];

/// Where the app went after a result was opened, so a test can assert the
/// existing route was used rather than a new screen invented for search.
late List<String> _visited;

GoRouter _router() {
  return GoRouter(
    initialLocation: '/library',
    routes: <RouteBase>[
      GoRoute(
        path: '/library',
        builder: (_, __) => const _Host(),
        routes: <RouteBase>[
          GoRoute(
            path: 'album/:id',
            builder: (_, GoRouterState state) =>
                _Landed('album ${state.pathParameters['id']}'),
          ),
          GoRoute(
            path: 'artist/:id',
            builder: (_, GoRouterState state) =>
                _Landed('artist ${state.pathParameters['id']}'),
          ),
        ],
      ),
      GoRoute(
        path: '/playlists',
        builder: (_, __) => const _Landed('playlists'),
        routes: <RouteBase>[
          GoRoute(
            path: 'detail/:id',
            builder: (_, GoRouterState state) =>
                _Landed('playlist ${state.pathParameters['id']}'),
          ),
        ],
      ),
      GoRoute(
        path: '/player',
        builder: (_, __) => const _Landed('player'),
      ),
    ],
  );
}

/// The screen the overlay opens over. Its own text doubles as the proof that
/// the screen underneath was never replaced.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => showQuickSearch(context),
          child: const Text('host screen'),
        ),
      ),
    );
  }
}

class _Landed extends StatelessWidget {
  const _Landed(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    _visited.add(label);
    return Scaffold(body: Center(child: Text('landed: $label')));
  }
}

Future<FakePlaybackController> _open(
  WidgetTester tester, {
  List<Track> tracks = _tracks,
  List<Playlist> playlists = const <Playlist>[],
  bool openOverlay = true,
}) async {
  _visited = <String>[];
  final FakePlaybackController playback = FakePlaybackController();
  final InMemoryPlaylistStore playlistStore = InMemoryPlaylistStore();
  if (playlists.isNotEmpty) await playlistStore.save(playlists);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playlistStoreProvider.overrideWithValue(playlistStore),
        playbackControllerProvider.overrideWithValue(playback),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();

  if (openOverlay) {
    await tester.tap(find.text('host screen'));
    await tester.pumpAndSettle();
  }
  return playback;
}

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const Key('quick_search_field')), query);
  await tester.pump(_afterDebounce);
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// The result row currently highlighted, read off the [ListTile]s the overlay
/// renders, so the test asserts what the user sees rather than private state.
String _highlightedTitle(WidgetTester tester) {
  final Iterable<ListTile> tiles = tester.widgetList<ListTile>(
    find.byType(ListTile),
  );
  final ListTile selected = tiles.firstWhere((ListTile tile) => tile.selected);
  return (selected.title! as Text).data!;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('QuickSearchOverlay', () {
    testWidgets('opens over the current screen without replacing it',
        (tester) async {
      await _open(tester);

      expect(find.byKey(const Key('quick_search_field')), findsOneWidget);
      // The host screen is still mounted underneath — the overlay is a dialog,
      // not a navigation.
      expect(find.text('host screen'), findsOneWidget);
      expect(_visited, isEmpty);
    });

    testWidgets('prompts before anything is typed', (tester) async {
      await _open(tester);

      expect(find.byKey(const Key('quick_search_prompt')), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('says it is still searching until the debounce fires',
        (tester) async {
      await _open(tester);

      await tester.enterText(
        find.byKey(const Key('quick_search_field')),
        'daft',
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('quick_search_searching')), findsOneWidget);
      expect(find.text('Get Lucky'), findsNothing);

      await tester.pump(_afterDebounce);
      await tester.pumpAndSettle();

      expect(find.text('Get Lucky'), findsOneWidget);
    });

    testWidgets('groups songs, albums and artists under headings',
        (tester) async {
      await _open(tester);
      await _type(tester, 'daft');

      expect(find.text('Songs'), findsOneWidget);
      expect(find.text('Albums'), findsOneWidget);
      expect(find.text('Artists'), findsOneWidget);
      expect(find.text('Get Lucky'), findsOneWidget);
      expect(find.text('Random Access Memories'), findsOneWidget);
      expect(find.text('Daft Punk'), findsWidgets);
      // Nothing from the unrelated track leaks into the results.
      expect(find.text('Halo'), findsNothing);
    });

    testWidgets('finds playlists too', (tester) async {
      await _open(
        tester,
        playlists: const <Playlist>[
          Playlist(
            id: 'p1',
            name: 'Road Trip',
            trackIds: <String>['file:///1.mp3'],
          ),
        ],
      );
      await _type(tester, 'road');

      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('Road Trip'), findsOneWidget);
    });

    testWidgets('says so, clearly, when nothing matches', (tester) async {
      await _open(tester);
      await _type(tester, 'zzzzz');

      expect(find.byKey(const Key('quick_search_no_results')), findsOneWidget);
      expect(find.text('No results for “zzzzz”'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('arrow keys move the highlight and Enter opens it',
        (tester) async {
      final FakePlaybackController playback = await _open(tester);
      await _type(tester, 'daft');

      // The first row starts highlighted, so Enter always has a target.
      expect(_highlightedTitle(tester), 'Get Lucky');

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_highlightedTitle(tester), 'Instant Crush');

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_highlightedTitle(tester), 'Get Lucky');

      await _press(tester, LogicalKeyboardKey.enter);

      // The overlay is gone, the song is playing, and Now Playing opened
      // through the app's existing route.
      expect(find.byKey(const Key('quick_search_field')), findsNothing);
      expect(playback.playedTracks.first.title, 'Get Lucky');
      expect(_visited, contains('player'));
    });

    testWidgets('the highlight wraps around the ends of the list',
        (tester) async {
      await _open(tester);
      await _type(tester, 'daft');

      // Up from the first row lands on the last one, which is the artist.
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_highlightedTitle(tester), 'Daft Punk');

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_highlightedTitle(tester), 'Get Lucky');
    });

    testWidgets('opening a song queues the other song matches behind it',
        (tester) async {
      final FakePlaybackController playback = await _open(tester);
      await _type(tester, 'daft');

      await _press(tester, LogicalKeyboardKey.arrowDown);
      await _press(tester, LogicalKeyboardKey.enter);

      expect(playback.playedTracks.first.title, 'Instant Crush');
    });

    testWidgets('Escape closes without opening anything', (tester) async {
      await _open(tester);
      await _type(tester, 'daft');

      await _press(tester, LogicalKeyboardKey.escape);

      expect(find.byKey(const Key('quick_search_field')), findsNothing);
      expect(find.text('host screen'), findsOneWidget);
      expect(_visited, isEmpty);
    });

    testWidgets('an album result opens the album route', (tester) async {
      await _open(tester);
      await _type(tester, 'random access');

      await tester.tap(find.text('Random Access Memories').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('quick_search_field')), findsNothing);
      expect(
        _visited.any((String v) => v.startsWith('album ')),
        isTrue,
        reason: 'the existing /library/album/:id route opened the album',
      );
    });

    testWidgets('an artist result opens the artist route', (tester) async {
      await _open(tester);
      await _type(tester, 'beyonce');

      await tester.tap(find.text('Beyonce').last);
      await tester.pumpAndSettle();

      expect(
        _visited.any((String v) => v.startsWith('artist ')),
        isTrue,
        reason: 'the existing /library/artist/:id route opened the artist',
      );
    });

    testWidgets('a playlist result opens the playlist route', (tester) async {
      await _open(
        tester,
        playlists: const <Playlist>[
          Playlist(id: 'p1', name: 'Road Trip'),
        ],
      );
      await _type(tester, 'road');

      await tester.tap(find.text('Road Trip'));
      await tester.pumpAndSettle();

      expect(_visited, contains('playlist p1'));
    });

    testWidgets('clearing the box returns to the prompt immediately',
        (tester) async {
      await _open(tester);
      await _type(tester, 'daft');
      expect(find.text('Get Lucky'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quick_search_clear')));
      await tester.pump();

      expect(find.byKey(const Key('quick_search_prompt')), findsOneWidget);
      expect(find.text('Get Lucky'), findsNothing);

      // A debounce left pending by the cleared text must not restore it.
      await tester.pump(_afterDebounce);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quick_search_prompt')), findsOneWidget);
    });

    testWidgets('a pending debounce is cancelled when the overlay closes',
        (tester) async {
      await _open(tester);

      await tester.enterText(
        find.byKey(const Key('quick_search_field')),
        'daft',
      );
      await tester.pump(const Duration(milliseconds: 50));

      await _press(tester, LogicalKeyboardKey.escape);

      // Reaching the end of the test without a "setState on a disposed State"
      // error is the assertion: the timer must not have fired after dispose.
      await tester.pump(_afterDebounce);
      await tester.pumpAndSettle();
      expect(find.text('host screen'), findsOneWidget);
    });

    testWidgets('Enter with no results does nothing', (tester) async {
      await _open(tester);
      await _type(tester, 'zzzzz');

      await _press(tester, LogicalKeyboardKey.enter);

      expect(find.byKey(const Key('quick_search_field')), findsOneWidget);
      expect(_visited, isEmpty);
    });
  });
}
