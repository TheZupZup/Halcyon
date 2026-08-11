import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/player/widgets/playback_progress_bar.dart';
import 'package:linthra/features/player/widgets/wavy_seek_bar.dart';

/// The bar is pumped at a fixed 300dp so the tap/drag maths below are exact:
/// the painter insets the track by the marker radius (6) at each end, leaving a
/// 288dp travel, and the widget is centred in an 800dp-wide test window.
const double _barWidth = 300;
const Duration _total = Duration(minutes: 4);

Future<List<Duration>> _pumpBar(
  WidgetTester tester, {
  Duration position = Duration.zero,
  Duration duration = _total,
  bool seekable = true,
  bool playing = false,
  PlaybackProgressStyle style = PlaybackProgressStyle.wave,
}) async {
  final List<Duration> seeks = <Duration>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _barWidth,
            child: PlaybackProgressBar(
              position: position,
              duration: duration,
              playing: playing,
              style: style,
              onSeek: seekable ? seeks.add : null,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return seeks;
}

void main() {
  group('PlaybackProgressBar (wave)', () {
    testWidgets('is the default style', (tester) async {
      await _pumpBar(tester);

      expect(find.byType(WavySeekBar), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('renders the elapsed and total times', (tester) async {
      await _pumpBar(tester, position: const Duration(seconds: 75));

      expect(find.text('1:15'), findsOneWidget);
      expect(find.text('4:00'), findsOneWidget);
    });

    testWidgets('reads --:-- and does not seek without a duration',
        (tester) async {
      final seeks = await _pumpBar(tester, duration: Duration.zero);

      expect(find.text('--:--'), findsOneWidget);

      await tester.tap(find.byType(WavySeekBar));
      await tester.pump();
      expect(seeks, isEmpty);
    });

    testWidgets('a tap seeks to the touched point', (tester) async {
      final seeks = await _pumpBar(tester);

      // The centre of the track is half of a four-minute song.
      await tester.tap(find.byType(WavySeekBar));
      await tester.pump();

      expect(seeks, hasLength(1));
      expect(seeks.single.inSeconds, closeTo(120, 1));
    });

    testWidgets('a drag previews the elapsed label and seeks once on release',
        (tester) async {
      final seeks = await _pumpBar(tester);

      final Offset centre = tester.getCenter(find.byType(WavySeekBar));
      final TestGesture gesture = await tester.startGesture(centre);
      await tester.pump();
      // Quarter of the 288dp travel is 25% of the song…
      await gesture.moveTo(centre - const Offset(72, 0));
      await tester.pump();

      // …shown live in the label, with nothing committed yet.
      expect(find.text('1:00'), findsOneWidget);
      expect(seeks, isEmpty);

      await gesture.up();
      await tester.pump();

      // Exactly one seek, at the released position.
      expect(seeks, hasLength(1));
      expect(seeks.single.inSeconds, closeTo(60, 1));
    });

    testWidgets('renders progress but never seeks with no onSeek handler',
        (tester) async {
      final seeks = await _pumpBar(
        tester,
        position: const Duration(minutes: 1),
        seekable: false,
      );

      expect(find.text('1:00'), findsOneWidget);
      await tester.tap(find.byType(WavySeekBar));
      await tester.pump();
      expect(seeks, isEmpty);
    });

    testWidgets('never animates perpetually, playing or paused',
        (tester) async {
      // The bar lives on the screen users leave open longest, so it must settle
      // in both states — pumpAndSettle returning is the whole assertion.
      await _pumpBar(tester, playing: true);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      await _pumpBar(tester, playing: false);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('PlaybackProgressBar (wave) accessibility', () {
    testWidgets('announces the position as a slider', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpBar(tester, position: const Duration(seconds: 75));

      final SemanticsNode node = tester.getSemantics(find.byType(WavySeekBar));
      expect(node.label, 'Playback position');
      expect(node.value, '1:15 of 4:00');
      expect(
        node.hasFlag(SemanticsFlag.isSlider),
        isTrue,
        reason: 'replacing Slider must not drop the slider role',
      );

      handle.dispose();
    });

    testWidgets('increase and decrease seek by a step', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final seeks =
          await _pumpBar(tester, position: const Duration(minutes: 1));

      // 5% of a four-minute track is 12s, comfortably over the 5s floor.
      tester.semantics.increase(find.semantics.byLabel('Playback position'));
      await tester.pump();
      expect(seeks.single, const Duration(seconds: 72));

      seeks.clear();
      tester.semantics.decrease(find.semantics.byLabel('Playback position'));
      await tester.pump();
      expect(seeks.single, const Duration(seconds: 48));

      handle.dispose();
    });

    testWidgets('is read-only, not a slider, without a duration',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpBar(tester, duration: Duration.zero);

      final SemanticsNode node = tester.getSemantics(find.byType(WavySeekBar));
      expect(node.value, 'Unknown');
      expect(node.hasFlag(SemanticsFlag.isSlider), isFalse);

      handle.dispose();
    });
  });

  group('PlaybackProgressBar (slider fallback)', () {
    testWidgets('still renders a Material slider and seeks', (tester) async {
      final seeks = await _pumpBar(
        tester,
        style: PlaybackProgressStyle.slider,
      );

      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(WavySeekBar), findsNothing);

      await tester.tap(find.byType(Slider));
      await tester.pump();

      expect(seeks, hasLength(1));
      expect(seeks.single, greaterThan(Duration.zero));
    });

    testWidgets('shows the same labels as the wave', (tester) async {
      await _pumpBar(
        tester,
        position: const Duration(seconds: 75),
        style: PlaybackProgressStyle.slider,
      );

      expect(find.text('1:15'), findsOneWidget);
      expect(find.text('4:00'), findsOneWidget);
    });
  });
}
