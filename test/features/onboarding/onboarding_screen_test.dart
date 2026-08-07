import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/onboarding/onboarding_screen.dart';

void main() {
  testWidgets('welcome moves into the music-source chooser', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: OnboardingScreen(),
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
}
