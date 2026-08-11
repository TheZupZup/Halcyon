import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/wavy_progress_indicator.dart';

Future<void> _pump(
  WidgetTester tester, {
  required double value,
  bool active = true,
  bool reduceMotion = false,
  double thumbRadius = 0,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data:
              MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: Directionality(
            textDirection: textDirection,
            child: Center(
              child: SizedBox(
                width: 300,
                height: 44,
                child: WavyProgressIndicator(
                  value: value,
                  activeColor: const Color(0xFFFF9F43),
                  inactiveColor: const Color(0x26FFFFFF),
                  thumbRadius: thumbRadius,
                  active: active,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('WavyProgressIndicator', () {
    testWidgets('renders at rest without scheduling frames', (tester) async {
      await _pump(tester, value: 0.4);
      await tester.pumpAndSettle();

      expect(find.byType(WavyProgressIndicator), findsOneWidget);
      // A static bar must not animate perpetually — this is what keeps the
      // mini-player free on every screen.
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not animate on first build', (tester) async {
      // Opening a screen should not replay an entrance swell — the wave is
      // already at the amplitude matching its initial state.
      await _pump(tester, value: 0.4);
      await tester.pump();

      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('swells once when active flips, then stops', (tester) async {
      await _pump(tester, value: 0.4);
      await tester.pumpAndSettle();

      await _pump(tester, value: 0.4, active: false);
      await tester.pump();
      // The one-shot ease is running…
      expect(tester.binding.hasScheduledFrame, isTrue);

      // …and it lands, rather than looping forever. pumpAndSettle returning at
      // all is the assertion: a perpetual animation would hang here.
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('snaps instead of easing when reduce-motion is requested',
        (tester) async {
      await _pump(tester, value: 0.4, reduceMotion: true);
      await tester.pumpAndSettle();

      await _pump(tester, value: 0.4, active: false, reduceMotion: true);
      await tester.pump();

      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('paints the extremes and out-of-range values safely',
        (tester) async {
      for (final double value in <double>[0.0, 1.0, -3.0, 4.2, double.nan]) {
        await _pump(tester, value: value, thumbRadius: 6);
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'value $value should paint without throwing',
        );
      }
    });

    testWidgets('paints in a right-to-left layout', (tester) async {
      await _pump(
        tester,
        value: 0.5,
        thumbRadius: 6,
        textDirection: TextDirection.rtl,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('sits on its own repaint boundary', (tester) async {
      await _pump(tester, value: 0.4);
      await tester.pumpAndSettle();

      // The bar must not force whatever it is drawn over (on Now Playing, the
      // blurred artwork backdrop) to re-rasterize as it repaints.
      expect(
        find.descendant(
          of: find.byType(WavyProgressIndicator),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
    });
  });

  group('WavyProgressIndicator.trackInset', () {
    test('reserves room for the marker when one is drawn', () {
      expect(
        WavyProgressIndicator.trackInset(thumbRadius: 6, strokeWidth: 3),
        6,
      );
    });

    test('falls back to half the stroke with no marker', () {
      expect(
        WavyProgressIndicator.trackInset(thumbRadius: 0, strokeWidth: 3),
        1.5,
      );
    });
  });
}
