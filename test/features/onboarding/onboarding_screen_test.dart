import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/onboarding/onboarding_screen.dart';

void main() {
  testWidgets('welcome moves into the music-source chooser', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          // Turn animations off so the tour settles in a single pump, but keep
          // the surrounding metrics: building MediaQueryData from scratch would
          // describe a zero-size screen, which is a viewport no device has.
          home: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const OnboardingScreen(),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Welcome to Linthra'), findsOneWidget);
    expect(find.text('Your music. Your servers. Your choice.'), findsOneWidget);

    await tester.tap(find.text('Get started'));
    await tester.pump();

    expect(find.text('Where is your music?'), findsOneWidget);
    expect(find.text('Local music'), findsOneWidget);
    expect(find.text('Jellyfin'), findsOneWidget);
    expect(find.text('Navidrome / Subsonic'), findsOneWidget);
    expect(find.text('Plex'), findsOneWidget);
  });

  testWidgets('welcome survives a viewport shorter than its own padding',
      (tester) async {
    // A split-screen window — or any embedding that reports a viewport smaller
    // than the page's vertical padding — used to drive the welcome's minimum
    // height negative, and a non-normalized BoxConstraints asserts on build.
    // The page must lay out and stay readable instead.
    tester.view.physicalSize = const Size(400, 40);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const OnboardingScreen(),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Welcome to Linthra'), findsOneWidget);
  });
}
