import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'cast/fake_cast_service.dart';
import 'fake_playback_controller.dart';

/// The mini-player is on screen on every tab, so what it announces is the most
/// frequently heard thing in the app. Its icon-only states (casting, buffering)
/// have to name themselves, and the metadata beside them should read as one
/// line rather than three fragments.
const _track = Track(
  id: '1',
  title: 'Song One',
  uri: '/music/song1.mp3',
  artistName: 'Artist A',
  albumName: 'Album B',
);

Future<void> _pump(
  WidgetTester tester, {
  required PlaybackState state,
  CastState? cast,
}) async {
  // The fake only publishes on demand, so the cast state is pushed after the
  // first frame the way a real session would arrive.
  final FakeCastService castService =
      FakeCastService(initial: cast ?? CastState.unavailable);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider
            .overrideWithValue(FakePlaybackController(initial: state)),
        castServiceProvider.overrideWithValue(castService),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(),
          bottomNavigationBar: MiniPlayer(),
        ),
      ),
    ),
  );
  await tester.pump();
  if (cast != null) {
    castService.emit(cast);
    // One frame to deliver the stream event, one to rebuild on it.
    await tester.pump();
    await tester.pump();
  }
}

void main() {
  group('MiniPlayer semantics', () {
    testWidgets('the metadata reads as one node, without the cover',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );

      // Title and subtitle are merged, so the bar announces the song once.
      expect(
        tester
            .getSemantics(find.text('Song One'))
            .label
            .replaceAll('\n', ' ')
            .trim(),
        contains('Song One'),
      );
      expect(
        tester.getSemantics(find.text('Song One')).label,
        contains('Artist A'),
      );

      // The artwork adds nothing the lines already say.
      expect(find.bySemanticsLabel('Album artwork'), findsNothing);
      handle.dispose();
    });

    testWidgets('the play/pause button names the action it performs',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );

      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(
        tester.getSemantics(find.byTooltip('Pause')),
        matchesSemantics(
          tooltip: 'Pause',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a buffering transport says so instead of going quiet',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        state: const PlaybackState(
          status: PlaybackStatus.loading,
          currentTrack: _track,
        ),
      );

      // The spinner stands in for play/pause; unnamed it would read as the
      // control having disappeared.
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.bySemanticsLabel('Buffering'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the casting indicator is named', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
        cast: const CastState(
          availability: CastAvailability.connected,
          connectedDevice: CastDevice(id: 'd1', name: 'Living Room'),
        ),
      );

      expect(find.bySemanticsLabel('Casting'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('no casting indicator when nothing is casting', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );

      expect(find.bySemanticsLabel('Casting'), findsNothing);
      handle.dispose();
    });
  });
}
