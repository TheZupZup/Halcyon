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
  FakePlaybackController controller, {
  TextScaler? textScaler,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp(
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          return MediaQuery(
            data: mediaQuery.copyWith(
              textScaler: textScaler ?? mediaQuery.textScaler,
            ),
            child: child!,
          );
        },
        home: const PlayerScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FakePlaybackController _streamingController() {
  return FakePlaybackController(
    initial: const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track,
      source: PlaybackSource.streamingDirect,
      duration: Duration(minutes: 4),
    ),
  );
}

void main() {
  testWidgets('status changes do not move the track metadata', (tester) async {
    final controller = _streamingController();
    await _pumpPlayer(tester, controller);

    final title = find.text('Remote song');
    final directStreamY = tester.getTopLeft(title).dy;
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
      tester.getTopLeft(title).dy,
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
      tester.getTopLeft(title).dy,
      moreOrLessEquals(directStreamY, epsilon: 0.01),
    );
  });

  testWidgets('status slot grows with the system text scale', (tester) async {
    await _pumpPlayer(
      tester,
      _streamingController(),
      textScaler: const TextScaler.linear(2),
    );

    final statusSlot = find.byKey(const ValueKey('player-status-slot'));
    expect(statusSlot, findsOneWidget);
    expect(tester.getSize(statusSlot).height, greaterThan(24));
    expect(find.text('Playing from Navidrome'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
