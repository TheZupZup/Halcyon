import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/playlists/playlist_detail_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
  Track(id: 'c', title: 'Song C', uri: 'file:///c.mp3'),
];

GoRouter _router() {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, __) => const PlaylistDetailScreen(playlistId: 'p1'),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const Scaffold(body: Text('player-screen')),
      ),
    ],
  );
}

/// A playlist long enough to scroll, as in the report behind #582.
final List<Track> _long = <Track>[
  for (int i = 0; i < 60; i++)
    Track(
      id: 'song-$i',
      title: 'Song ${i.toString().padLeft(2, '0')}',
      uri: 'file:///song-$i.mp3',
    ),
];

Future<void> _pump(
  WidgetTester tester, {
  required InMemoryPlaylistStore store,
  required FakePlaybackController controller,
  List<Track> tracks = _tracks,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<InMemoryPlaylistStore> _seededStore({
  List<String> trackIds = const <String>['file:///a.mp3', 'file:///b.mp3'],
}) async {
  final InMemoryPlaylistStore store = InMemoryPlaylistStore();
  await store.save(<Playlist>[
    Playlist(id: 'p1', name: 'Road Trip', trackIds: trackIds),
  ]);
  return store;
}

/// Drags the track row at [from] by its handle past the end of the list.
///
/// Overshoots deliberately — the drop index clamps to the last slot — so the
/// gesture reads as "drag it to the bottom" and does not depend on row metrics.
Future<void> _dragToEnd(WidgetTester tester, {required int from}) async {
  final Finder handles = find.byIcon(Icons.drag_handle);
  final int rows = handles.evaluate().length;
  final double rowHeight =
      tester.getCenter(handles.at(1)).dy - tester.getCenter(handles.at(0)).dy;
  final double travel = rowHeight * (rows + 1);
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(handles.at(from)));
  // Start moving promptly. Holding still past the long-press timeout hands the
  // gesture to the row's selection-mode recognizer, and the drag never happens.
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('entering selection keeps the playlist where it was (#582)',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _long) track.uri],
    );
    await _pump(
      tester,
      store: store,
      controller: FakePlaybackController(),
      tracks: _long,
    );

    final Finder scrollable = find.byType(Scrollable).last;
    await tester.drag(scrollable, const Offset(0, -900));
    await tester.pumpAndSettle();
    final double before =
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0), reason: 'the drag should have scrolled');

    // Long-press a visible row to enter selection. The list widget changes
    // here (no drag handles while selecting), so the offset has to be carried
    // across rather than kept in one Scrollable.
    await tester.longPress(find.byType(ListTile).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    final Finder selectionScrollable = find.byType(Scrollable).last;
    expect(
      tester.state<ScrollableState>(selectionScrollable).position.pixels,
      before,
    );
  });

  testWidgets('renders the playlist tracks', (tester) async {
    await _pump(
      tester,
      store: await _seededStore(),
      controller: FakePlaybackController(),
    );
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
  });

  testWidgets('dragging a track to the end persists the new order',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>['file:///a.mp3', 'file:///b.mp3', 'file:///c.mp3'],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    // The screen converts between the reorder callback's destination index and
    // the pre-removal index the repository normalises from. The two conversions
    // cancel out, so only an end-to-end drag proves the pair is still in step:
    // dropping either one silently files the track one slot off.
    await _dragToEnd(tester, from: 0);

    final List<Playlist> saved = await store.load();
    expect(
      saved.single.trackIds,
      <String>['file:///b.mp3', 'file:///c.mp3', 'file:///a.mp3'],
    );
  });

  testWidgets('Play queues the playlist and opens the player', (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.first.id, 'a');
    // The rest of the playlist is queued behind the first track.
    expect(controller.state.upNext.map((Track t) => t.id), <String>['b']);
    expect(find.text('player-screen'), findsOneWidget);
  });

  testWidgets('tapping a track plays from there and queues the playlist',
      (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.first.id, 'b');
    expect(find.text('player-screen'), findsOneWidget);
  });

  testWidgets(
      'track row menu toggles favorite without playing or changing the queue',
      (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.byTooltip('Track actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Add to favorites'), findsOneWidget);

    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();

    // Favoriting is a pure like: no playback, no queue change.
    expect(controller.playedTracks, isEmpty);
    expect(controller.state.upNext, isEmpty);

    // Reopening the row's menu now offers the filled-heart remove action.
    await tester.tap(find.byTooltip('Track actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove from favorites'), findsOneWidget);
  });

  testWidgets('long-press enters selection mode and shows the count',
      (tester) async {
    await _pump(
      tester,
      store: await _seededStore(),
      controller: FakePlaybackController(),
    );

    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // Selecting another track updates the count.
    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });
}
