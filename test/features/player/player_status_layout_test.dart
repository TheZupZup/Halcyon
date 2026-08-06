import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'fake_playback_controller.dart';

const _track = Track(
  id: 'remote-1',
  title: 'Remote song',
  uri: 'subsonic:remote-1',
  artistName: 'Artist',
  albumName: 'Album',
);

Future<void> _pumpPlayer(
  WidgetTester tester,
  FakePlaybackController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('status changes do not move the progress controls', (tester) async {
    final controller = FakePlaybackController(
      initial: const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track,
        source: PlaybackSource.streamingDirect,
        duration: Duration(minutes: 4),
      ),
    );
    await _pumpPlayer(tester, controller);

    final slider = find.byType(Slider);
    final directStreamY = tester.getTopLeft(slider).dy;
    expect(find.text('Playing from Navidrome'), findsOneWidget);

    controller.emit(
      const PlaybackState(
        status: PlaybackStatus.buffering,
        currentTrack: _track,
        duration: Duration(minutes: 4),
        position: Duration(minutes: 2),
      ),
    );
    await tester.pump();

    expect(find.text('Buffering…'), findsOneWidget);
    expect(
      tester.getTopLeft(slider).dy,
      moreOrLessEquals(directStreamY, epsilon: 0.01),
    );

    controller.emit(
      const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track,
        source: PlaybackSource.offlineCache,
        duration: Duration(minutes: 4),
        position: Duration(minutes: 2),
      ),
    );
    await tester.pump();

    expect(find.text('Playing from Cache'), findsOneWidget);
    expect(
      tester.getTopLeft(slider).dy,
      moreOrLessEquals(directStreamY, epsilon: 0.01),
    );
  });
}
