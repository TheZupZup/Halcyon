import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';

import 'fake_playback_controller.dart';

Track _track(String id) =>
    Track(id: id, title: 'Song $id', uri: '/$id.mp3', artistName: 'Artist $id');

/// Pumps a host with a button that opens the Queue sheet over the given
/// [controller], faithfully exercising it as the modal bottom sheet it is.
Future<void> _open(
  WidgetTester tester,
  FakePlaybackController controller, {
  InMemoryPlaylistStore? store,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        if (store != null) playlistStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQueueSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Drags the up-next row at [from] by its handle to one end of the list:
/// [toEnd] true drags it past the last row, false past the first.
///
/// Goes through a real pointer sequence rather than calling the reorder
/// callback directly, so the framework's own index bookkeeping is part of what
/// is under test. The travel deliberately overshoots the list — the drop index
/// clamps to the end — which keeps the gesture readable and independent of row
/// metrics, rather than tuned to land on a particular pixel.
Future<void> _dragToEdge(
  WidgetTester tester, {
  required int from,
  required bool toEnd,
}) async {
  final Finder handles = find.byIcon(Icons.drag_handle);
  final int rows = handles.evaluate().length;
  final double rowHeight =
      tester.getCenter(handles.at(1)).dy - tester.getCenter(handles.at(0)).dy;
  final double travel = rowHeight * (rows + 1) * (toEnd ? 1 : -1);
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(handles.at(from)));
  await tester.pumpAndSettle();
  // Two steps rather than one jump, so the list's gap bookkeeping keeps up.
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pumpAndSettle();
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('QueueSheet', () {
    testWidgets('renders the current track and the up-next tracks',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);

      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      // Current track + both up-next tracks are listed.
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
    });

    testWidgets('removing an up-next entry keeps the current track playing',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      // Remove the first up-next track (Song B).
      await tester.tap(find.byTooltip('Remove from queue').first);
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, [_track('C')]);
      expect(find.text('Song B'), findsNothing);
    });

    testWidgets('Clear empties up next but keeps the current track',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(controller.clearCount, 1);
      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, isEmpty);
      expect(find.text('Song B'), findsNothing);
    });

    testWidgets('tapping an up-next track plays it now', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      await tester.tap(find.text('Song C'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('C'));
    });

    testWidgets('shows a drag handle for each upcoming track', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);

      // One handle per up-next track (B and C), not the current one.
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
      expect(find.byType(ReorderableDragStartListener), findsNWidgets(2));
    });

    testWidgets('dragging an upcoming track to the end lands it last',
        (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);
      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['B', 'C', 'D']);

      // Drag B (the first up-next row) past C and D. A downward move is where
      // the reorder index convention bites: the framework reports the
      // destination *after* the removal, which is what
      // PlaybackQueue.reorderUpNext documents, so the sheet passes it straight
      // through. Re-adding the old adjustment here would leave B second.
      await _dragToEdge(tester, from: 0, toEnd: true);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'D', 'B']);
    });

    testWidgets('dragging an upcoming track to the top lands it first',
        (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);

      // An upward move needs no adjustment in any Flutter version, so it pins
      // the half of the convention the downward case cannot.
      await _dragToEdge(tester, from: 2, toEnd: false);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['D', 'B', 'C']);
    });

    testWidgets('history is shown and tapping it steps back', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);
      await controller.skipToNext(); // current B, history [A], up next [C]

      await _open(tester, controller);

      expect(find.text('Previously played'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);

      await tester.tap(find.text('Song A'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('A'));
    });

    testWidgets('save queue as playlist creates a local playlist',
        (tester) async {
      final store = InMemoryPlaylistStore();
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller, store: store);
      await tester.tap(find.byTooltip('Save queue as playlist'));
      await tester.pumpAndSettle();

      // The shared create-playlist dialog: enter a name, then Create.
      await tester.enterText(find.byType(TextField).first, 'My Queue');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final List<Playlist> saved = await store.load();
      expect(saved, hasLength(1));
      expect(saved.single.name, 'My Queue');
      // Order is history + current + up-next, stored by provider uri.
      expect(saved.single.trackIds, <String>['/A.mp3', '/B.mp3', '/C.mp3']);
      expect(saved.single.source, PlaylistSource.local);
      expect(find.textContaining('Saved 3 songs to'), findsOneWidget);
    });

    testWidgets('never renders a track uri / authenticated source string',
        (tester) async {
      final controller = FakePlaybackController();
      // A remote track whose source reference would carry a token if leaked.
      await controller.playTracks(const <Track>[
        Track(
          id: 'r1',
          title: 'Remote One',
          uri: 'https://host/stream?api_key=SECRETTOKEN123',
          artistName: 'Artist R',
        ),
        Track(
          id: 'r2',
          title: 'Remote Two',
          uri: 'jellyfin:r2',
          artistName: 'Artist R',
        ),
      ]);

      await _open(tester, controller);

      // Titles/artists render; the raw uri and any token never do.
      expect(find.text('Remote One'), findsOneWidget);
      expect(find.text('Remote Two'), findsOneWidget);
      expect(find.textContaining('SECRETTOKEN'), findsNothing);
      expect(find.textContaining('api_key'), findsNothing);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('jellyfin:'), findsNothing);
    });
  });
}
