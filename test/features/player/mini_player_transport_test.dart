import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'fake_playback_controller.dart';

/// The bar is the only playback surface on screen while you browse, so on a
/// desktop window it carries the whole transport — previous, next, and the
/// heart — and skipping a track never means opening the full player first.
///
/// It is the same widget on a phone, where that row does not fit, so what it
/// drops as the window narrows is pinned down here too: the controls disappear
/// in order of how easily they are reached elsewhere, and play/pause never
/// goes.
const _track = Track(
  id: '1',
  title: 'Song One',
  uri: 'subsonic:1',
  artistName: 'Artist A',
  albumName: 'Album B',
);

const _next = Track(id: '2', title: 'Song Two', uri: 'subsonic:2');

/// Pumps the bar at [width], the way the shell hosts it: pinned below a page
/// that fills the rest of the window.
Future<void> _pump(
  WidgetTester tester, {
  required PlaybackState state,
  required double width,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider
            .overrideWithValue(FakePlaybackController(initial: state)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(),
          bottomNavigationBar: MiniPlayer(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The controller behind the pumped bar, for asserting what a tap reached.
FakePlaybackController _controller(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(MiniPlayer)),
  ).read(playbackControllerProvider) as FakePlaybackController;
}

void main() {
  group('MiniPlayer transport', () {
    testWidgets('a desktop window carries favorite, previous and next',
        (tester) async {
      await _pump(
        tester,
        width: 1280,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
          upNext: <Track>[_next],
          hasPrevious: true,
        ),
      );

      expect(find.byTooltip('Favorite'), findsOneWidget);
      expect(find.byTooltip('Previous'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);
      expect(find.byTooltip('Queue'), findsOneWidget);
    });

    testWidgets('previous and next delegate to the controller', (tester) async {
      await _pump(
        tester,
        width: 1280,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
          upNext: <Track>[_next],
          hasPrevious: true,
        ),
      );
      final FakePlaybackController controller = _controller(tester);

      await tester.tap(find.byTooltip('Next'));
      expect(controller.skipCount, 1);

      await tester.tap(find.byTooltip('Previous'));
      expect(controller.previousCount, 1);
    });

    testWidgets('at the ends of the queue they grey out instead of vanishing',
        (tester) async {
      // A single track played on its own: nothing before it, nothing after.
      await _pump(
        tester,
        width: 1280,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );

      // Still on the bar, so the layout does not shift as a queue plays out.
      expect(find.byTooltip('Previous'), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.skip_previous),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.skip_next),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('the heart likes the copy that is actually playing',
        (tester) async {
      await _pump(
        tester,
        width: 1280,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MiniPlayer)),
      );

      await tester.tap(find.byTooltip('Favorite'));
      await tester.pumpAndSettle();

      // Written against the provider-namespaced uri, not the bare id.
      expect(
        container.read(favoritesRepositoryProvider).isFavorite('subsonic:1'),
        isTrue,
      );
      // And the bar now offers the other half of the toggle.
      expect(find.byTooltip('Remove from favorites'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove from favorites'));
      await tester.pumpAndSettle();
      expect(
        container.read(favoritesRepositoryProvider).isFavorite('subsonic:1'),
        isFalse,
      );
    });

    testWidgets('a phone-width bar keeps the heart but drops the skips',
        (tester) async {
      await _pump(
        tester,
        width: 411,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
          upNext: <Track>[_next],
          hasPrevious: true,
        ),
      );

      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Favorite'), findsOneWidget);
      expect(find.byTooltip('Previous'), findsNothing);
      expect(find.byTooltip('Next'), findsNothing);
      expect(find.byTooltip('Queue'), findsNothing);
    });

    testWidgets('a very narrow bar is play/pause alone, as it always was',
        (tester) async {
      await _pump(
        tester,
        width: 320,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
          upNext: <Track>[_next],
          hasPrevious: true,
        ),
      );

      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Favorite'), findsNothing);
      expect(find.byTooltip('Previous'), findsNothing);
      expect(find.byTooltip('Next'), findsNothing);
    });

    testWidgets('the metadata still fits beside a full transport row',
        (tester) async {
      await _pump(
        tester,
        width: 1280,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(
            id: '3',
            title: 'A Title That Runs On Well Past Any Reasonable Length',
            uri: 'subsonic:3',
            artistName: 'An Artist With A Similarly Unreasonable Name',
            albumName: 'And An Album To Match It',
          ),
          upNext: <Track>[_next],
          hasPrevious: true,
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
