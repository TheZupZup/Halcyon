import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/models/theme_mode_preference.dart';
import 'package:linthra/data/repositories/in_memory_theme_mode_store.dart';
import 'package:linthra/data/repositories/theme_mode_store_provider.dart';
import 'package:linthra/features/appearance/theme_mode_controller.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../features/player/fake_playback_controller.dart';
import '../support/onboarding_test_overrides.dart';

/// End-to-end theme-mode behaviour, driven through the real [LinthraApp] so the
/// wiring (controller → `MaterialApp.themeMode`) is covered, not just the
/// controller in isolation.
void main() {
  /// The brightness Linthra is *actually rendering*, read from the resolved
  /// theme inside the app rather than from the `themeMode` we passed in.
  Brightness renderedBrightness(WidgetTester tester) {
    final BuildContext context = tester.element(find.byType(Navigator).first);
    return Theme.of(context).brightness;
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    ThemeModePreference? seed,
    InMemoryThemeModeStore? store,
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...completedOnboardingOverrides(),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
        if (store != null) themeModeStoreProvider.overrideWithValue(store),
        if (seed != null) initialThemeModeProvider.overrideWithValue(seed),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LinthraApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Sets the phone's light/dark setting for this test.
  void setPhoneBrightness(WidgetTester tester, Brightness brightness) {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  group('theme mode follows the phone by default', () {
    testWidgets('defaults to ThemeMode.system', (tester) async {
      setPhoneBrightness(tester, Brightness.dark);
      await pumpApp(tester);

      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system,
      );
    });

    testWidgets('renders light on a light phone', (tester) async {
      setPhoneBrightness(tester, Brightness.light);
      await pumpApp(tester);

      expect(renderedBrightness(tester), Brightness.light);
    });

    testWidgets('renders dark on a dark phone', (tester) async {
      setPhoneBrightness(tester, Brightness.dark);
      await pumpApp(tester);

      expect(renderedBrightness(tester), Brightness.dark);
    });

    testWidgets('flips live when the phone theme changes while open',
        (tester) async {
      // The "update immediately" requirement: no relaunch, no navigation, no
      // listener of our own — just the OS setting changing under a running app.
      setPhoneBrightness(tester, Brightness.light);
      await pumpApp(tester);
      expect(renderedBrightness(tester), Brightness.light);

      setPhoneBrightness(tester, Brightness.dark);
      await tester.pumpAndSettle();
      expect(renderedBrightness(tester), Brightness.dark);

      // And back again, so this is a live binding rather than a one-way latch.
      setPhoneBrightness(tester, Brightness.light);
      await tester.pumpAndSettle();
      expect(renderedBrightness(tester), Brightness.light);
    });
  });

  group('an explicit choice overrides the phone', () {
    testWidgets('Light stays light on a dark phone', (tester) async {
      setPhoneBrightness(tester, Brightness.dark);
      await pumpApp(tester, seed: ThemeModePreference.light);

      expect(renderedBrightness(tester), Brightness.light);
    });

    testWidgets('Dark stays dark on a light phone', (tester) async {
      setPhoneBrightness(tester, Brightness.light);
      await pumpApp(tester, seed: ThemeModePreference.dark);

      expect(renderedBrightness(tester), Brightness.dark);
    });

    testWidgets('a pinned mode ignores a live phone theme change',
        (tester) async {
      setPhoneBrightness(tester, Brightness.light);
      await pumpApp(tester, seed: ThemeModePreference.dark);
      expect(renderedBrightness(tester), Brightness.dark);

      setPhoneBrightness(tester, Brightness.dark);
      await tester.pumpAndSettle();
      expect(renderedBrightness(tester), Brightness.dark);

      setPhoneBrightness(tester, Brightness.light);
      await tester.pumpAndSettle();
      expect(
        renderedBrightness(tester),
        Brightness.dark,
        reason: 'pinning Dark must survive the phone flipping to light',
      );
    });
  });

  group('the stored choice is applied without a flash', () {
    testWidgets('the seeded preference is live on the very first frame',
        (tester) async {
      // Seeded the way main does: read from storage before runApp. The
      // assertion is that the *first* pump already renders light on a dark
      // phone — no intermediate dark frame to flash through.
      setPhoneBrightness(tester, Brightness.dark);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ...completedOnboardingOverrides(),
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
          initialThemeModeProvider.overrideWithValue(ThemeModePreference.light),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const LinthraApp(),
        ),
      );

      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light,
        reason: 'the stored mode must be applied before the first frame, '
            'not loaded asynchronously afterwards',
      );
    });

    testWidgets('changing the mode at runtime repaints the app',
        (tester) async {
      final InMemoryThemeModeStore store = InMemoryThemeModeStore();
      setPhoneBrightness(tester, Brightness.dark);
      final ProviderContainer container = await pumpApp(tester, store: store);
      expect(renderedBrightness(tester), Brightness.dark);

      await container
          .read(themeModeControllerProvider.notifier)
          .select(ThemeModePreference.light);
      await tester.pumpAndSettle();

      expect(renderedBrightness(tester), Brightness.light);
      expect(store.preference, ThemeModePreference.light);
    });
  });
}
