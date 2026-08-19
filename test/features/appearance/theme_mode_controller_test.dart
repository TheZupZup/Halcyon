import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/theme_mode_preference.dart';
import 'package:linthra/core/repositories/theme_mode_store.dart';
import 'package:linthra/data/repositories/in_memory_theme_mode_store.dart';
import 'package:linthra/data/repositories/theme_mode_store_provider.dart';
import 'package:linthra/features/appearance/theme_mode_controller.dart';

/// A store whose reads and writes always fail, standing in for a plugin hiccup
/// or unreadable preferences.
class _ThrowingThemeModeStore implements ThemeModeStore {
  @override
  Future<ThemeModePreference?> read() async => throw StateError('read failed');

  @override
  Future<void> write(ThemeModePreference preference) async =>
      throw StateError('write failed');
}

void main() {
  group('ThemeModePreference', () {
    test('defaults to following the device', () {
      expect(ThemeModePreference.fallback, ThemeModePreference.system);
    });

    test('round-trips every value through its storage id', () {
      for (final ThemeModePreference preference in ThemeModePreference.values) {
        expect(
          ThemeModePreference.fromStorageId(preference.storageId),
          preference,
          reason: '${preference.name} must survive a storage round-trip',
        );
      }
    });

    test('storage ids are stable strings, not enum indices', () {
      // Indices would silently remap if the enum is ever reordered, turning a
      // stored "light" into "dark" on update.
      expect(ThemeModePreference.system.storageId, 'system');
      expect(ThemeModePreference.light.storageId, 'light');
      expect(ThemeModePreference.dark.storageId, 'dark');
    });

    test('an unknown, empty, or absent id falls back to system', () {
      expect(
          ThemeModePreference.fromStorageId(null), ThemeModePreference.system);
      expect(ThemeModePreference.fromStorageId(''), ThemeModePreference.system);
      expect(
        ThemeModePreference.fromStorageId('sepia'),
        ThemeModePreference.system,
      );
    });

    test('maps onto the matching Material ThemeMode', () {
      expect(ThemeModePreference.system.materialThemeMode, ThemeMode.system);
      expect(ThemeModePreference.light.materialThemeMode, ThemeMode.light);
      expect(ThemeModePreference.dark.materialThemeMode, ThemeMode.dark);
    });
  });

  group('ThemeModeController', () {
    ProviderContainer containerWith({
      ThemeModeStore? store,
      ThemeModePreference? seed,
    }) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          if (store != null) themeModeStoreProvider.overrideWithValue(store),
          if (seed != null) initialThemeModeProvider.overrideWithValue(seed),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('starts on system when nothing has been seeded', () {
      final ProviderContainer container = containerWith();
      expect(
        container.read(themeModeControllerProvider),
        ThemeModePreference.system,
      );
    });

    test('starts on the seeded preference, with no async load', () {
      // The seed is what main reads from storage before runApp. Reading the
      // controller synchronously — without pumping — is the assertion that
      // matters: the first frame is already correct, so there is no flash.
      final ProviderContainer container =
          containerWith(seed: ThemeModePreference.light);
      expect(
        container.read(themeModeControllerProvider),
        ThemeModePreference.light,
      );
    });

    test('selecting a mode updates state and persists it', () async {
      final InMemoryThemeModeStore store = InMemoryThemeModeStore();
      final ProviderContainer container = containerWith(store: store);

      await container
          .read(themeModeControllerProvider.notifier)
          .select(ThemeModePreference.dark);

      expect(
        container.read(themeModeControllerProvider),
        ThemeModePreference.dark,
      );
      expect(store.preference, ThemeModePreference.dark);
    });

    test('the persisted choice is what a later launch seeds from', () async {
      // The full restart path: write through one container, read it back the
      // way main does, and seed a fresh container with the result.
      final InMemoryThemeModeStore store = InMemoryThemeModeStore();
      await containerWith(store: store)
          .read(themeModeControllerProvider.notifier)
          .select(ThemeModePreference.light);

      final ProviderContainer relaunched = containerWith(
        store: store,
        seed: await readStoredThemeMode(store),
      );

      expect(
        relaunched.read(themeModeControllerProvider),
        ThemeModePreference.light,
      );
    });

    test('re-selecting the current mode does not rewrite storage', () async {
      final InMemoryThemeModeStore store =
          InMemoryThemeModeStore(ThemeModePreference.dark);
      final ProviderContainer container = containerWith(
        store: store,
        seed: ThemeModePreference.dark,
      );

      await container
          .read(themeModeControllerProvider.notifier)
          .select(ThemeModePreference.dark);

      expect(store.preference, ThemeModePreference.dark);
    });

    test('a failing write never undoes the visible choice', () async {
      final ProviderContainer container =
          containerWith(store: _ThrowingThemeModeStore());

      await container
          .read(themeModeControllerProvider.notifier)
          .select(ThemeModePreference.light);

      expect(
        container.read(themeModeControllerProvider),
        ThemeModePreference.light,
      );
    });
  });

  group('readStoredThemeMode', () {
    test('returns the stored preference', () async {
      expect(
        await readStoredThemeMode(
          InMemoryThemeModeStore(ThemeModePreference.dark),
        ),
        ThemeModePreference.dark,
      );
    });

    test('falls back to system when nothing is stored', () async {
      expect(
        await readStoredThemeMode(InMemoryThemeModeStore()),
        ThemeModePreference.system,
      );
    });

    test('a throwing store never takes startup down', () async {
      // main awaits this before runApp, so it must not be able to throw.
      expect(
        await readStoredThemeMode(_ThrowingThemeModeStore()),
        ThemeModePreference.system,
      );
    });
  });
}
