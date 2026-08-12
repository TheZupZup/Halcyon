import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/wavy_seek_bar.dart';

import 'fake_playback_controller.dart';

Future<void> _pumpScreen(
  WidgetTester tester,
  PlaybackController controller,
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

const _localTrack = Track(
  id: '1',
  title: 'Song One',
  uri: '/music/song1.mp3',
  artistName: 'Artist A',
  albumName: 'Album B',
);

FakePlaybackController _controllerWith({
  required bool playing,
  required bool hasNext,
  required bool hasPrevious,
  required bool shuffleEnabled,
  required RepeatMode repeatMode,
  Duration position = Duration.zero,
  Duration duration = Duration.zero,
}) {
  return FakePlaybackController(
    initial: PlaybackState(
      status: playing ? PlaybackStatus.playing : PlaybackStatus.paused,
      currentTrack: _localTrack,
      source: PlaybackSource.localFile,
      hasPrevious: hasPrevious,
      upNext: hasNext
          ? const <Track>[Track(id: '2', title: 'Next Song', uri: '/next.mp3')]
          : const <Track>[],
      position: position,
      duration: duration,
      shuffleEnabled: shuffleEnabled,
      repeatMode: repeatMode,
    ),
  );
}

void main() {
  group('Now Playing TalkBack Accessibility Tests', () {
    testWidgets('Play/Pause button exposes correct semantics', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();

      // Case 1: Paused (Play button)
      final controller = _controllerWith(
        playing: false,
        hasNext: false,
        hasPrevious: false,
        shuffleEnabled: false,
        repeatMode: RepeatMode.off,
      );
      await _pumpScreen(tester, controller);

      // Find the InkWell descendant of the Tooltip widget to get the semantics node.
      final playFinder = find.descendant(
        of: find.byTooltip('Play'),
        matching: find.byType(InkWell),
      );
      expect(playFinder, findsOneWidget);
      expect(
        tester.getSemantics(playFinder),
        matchesSemantics(
          tooltip: 'Play',
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );

      // Tap to play
      await tester.tap(playFinder);
      expect(controller.playCount, 1);

      // Case 2: Playing (Pause button)
      controller.emit(controller.state.copyWith(
        status: PlaybackStatus.playing,
      ));
      await tester.pumpAndSettle();

      final pauseFinder = find.descendant(
        of: find.byTooltip('Pause'),
        matching: find.byType(InkWell),
      );
      expect(pauseFinder, findsOneWidget);
      expect(
        tester.getSemantics(pauseFinder),
        matchesSemantics(
          tooltip: 'Pause',
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );

      // Tap to pause
      await tester.tap(pauseFinder);
      expect(controller.pauseCount, 1);

      handle.dispose();
    });

    testWidgets('Next/Previous buttons expose correct semantics',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();

      // Case 1: Enabled
      final controller = _controllerWith(
        playing: true,
        hasNext: true,
        hasPrevious: true,
        shuffleEnabled: false,
        repeatMode: RepeatMode.off,
      );
      await _pumpScreen(tester, controller);

      final nextFinder = find.byTooltip('Next');
      final prevFinder = find.byTooltip('Previous');

      expect(
        tester.getSemantics(nextFinder),
        matchesSemantics(
          tooltip: 'Next',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(
        tester.getSemantics(prevFinder),
        matchesSemantics(
          tooltip: 'Previous',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );

      // Tap next
      await tester.tap(nextFinder);
      expect(controller.skipCount, 1);

      // Tap previous
      await tester.tap(prevFinder);
      expect(controller.previousCount, 1);

      // Case 2: Disabled
      controller.emit(controller.state.copyWith(
        hasPrevious: false,
        upNext: const <Track>[],
      ));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(nextFinder),
        matchesSemantics(
          tooltip: 'Next',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      expect(
        tester.getSemantics(prevFinder),
        matchesSemantics(
          tooltip: 'Previous',
          isButton: true,
          hasEnabledState: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('Shuffle button exposes correct semantics', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();

      // Case 1: Shuffle off
      final controller = _controllerWith(
        playing: true,
        hasNext: false,
        hasPrevious: false,
        shuffleEnabled: false,
        repeatMode: RepeatMode.off,
      );
      await _pumpScreen(tester, controller);

      final shuffleFinder = find.byTooltip('Shuffle');
      expect(
        tester.getSemantics(shuffleFinder),
        matchesSemantics(
          tooltip: 'Shuffle',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasSelectedState: true,
          isSelected: false,
        ),
      );

      // Tap to toggle
      await tester.tap(shuffleFinder);
      expect(controller.state.shuffleEnabled, isTrue);

      // Case 2: Shuffle on
      controller.emit(controller.state.copyWith(shuffleEnabled: true));
      await tester.pumpAndSettle();

      final shuffleOnFinder = find.byTooltip('Shuffle on');
      expect(
        tester.getSemantics(shuffleOnFinder),
        matchesSemantics(
          tooltip: 'Shuffle on',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasSelectedState: true,
          isSelected: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('Repeat button exposes correct semantics', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();

      // Case 1: Repeat off
      final controller = _controllerWith(
        playing: true,
        hasNext: false,
        hasPrevious: false,
        shuffleEnabled: false,
        repeatMode: RepeatMode.off,
      );
      await _pumpScreen(tester, controller);

      final repeatFinder = find.byTooltip('Repeat');
      expect(
        tester.getSemantics(repeatFinder),
        matchesSemantics(
          tooltip: 'Repeat',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasSelectedState: true,
          isSelected: false,
        ),
      );

      // Case 2: Repeat all
      controller.emit(controller.state.copyWith(repeatMode: RepeatMode.all));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.byTooltip('Repeat all')),
        matchesSemantics(
          tooltip: 'Repeat all',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasSelectedState: true,
          isSelected: true,
        ),
      );

      // Case 3: Repeat one
      controller.emit(controller.state.copyWith(repeatMode: RepeatMode.one));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.byTooltip('Repeat one')),
        matchesSemantics(
          tooltip: 'Repeat one',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasSelectedState: true,
          isSelected: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('Seek slider exposes correct semantics and value actions',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();

      final controller = _controllerWith(
        playing: true,
        hasNext: false,
        hasPrevious: false,
        shuffleEnabled: false,
        repeatMode: RepeatMode.off,
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 4),
      );
      await _pumpScreen(tester, controller);

      final seekFinder = find.byType(WavySeekBar);
      expect(
        tester.getSemantics(seekFinder),
        matchesSemantics(
          label: 'Playback position',
          value: '1:00 of 4:00',
          isSlider: true,
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );

      // Perform semantic increase action
      // 5% of 4 minutes (240s) is 12s. Position is 1:00 (60s).
      // Increased position: 60s + 12s = 72s (1:12).
      tester.semantics.increase(find.semantics.byLabel('Playback position'));
      await tester.pumpAndSettle();
      expect(controller.seeks, isNotEmpty);
      expect(controller.seeks.last.inSeconds, 72);

      // Perform semantic decrease action
      // Decreased position: 60s - 12s = 48s (0:48).
      tester.semantics.decrease(find.semantics.byLabel('Playback position'));
      await tester.pumpAndSettle();
      expect(controller.seeks.last.inSeconds, 48);

      handle.dispose();
    });
  });
}
