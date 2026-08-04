import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/theme_mode_preference.dart';
import '../../core/repositories/theme_mode_store.dart';
import 'in_memory_theme_mode_store.dart';
import 'shared_preferences_theme_mode_store.dart';

/// The single [ThemeModeStore] the app reads/writes the System/Light/Dark
/// choice through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesThemeModeStoreOverride] so the choice persists across
/// restarts.
final themeModeStoreProvider = Provider<ThemeModeStore>((ref) {
  return InMemoryThemeModeStore();
});

/// Production binding: persists the theme mode via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesThemeModeStoreOverride =
    themeModeStoreProvider.overrideWithValue(
  const SharedPreferencesThemeModeStore(),
);

/// Reads the stored theme mode before the first frame is built.
///
/// `main` awaits this and seeds `initialThemeModeProvider` with the result, so
/// the very first frame already renders in the user's chosen mode. Loading it
/// asynchronously *after* startup would work too, but a user who picked Light
/// on a dark phone would watch the app flash dark and then flip — the exact
/// glitch this preference is supposed to remove.
///
/// Defensive by design: a store that throws (a plugin hiccup, unreadable
/// preferences) resolves to [ThemeModePreference.fallback] rather than taking
/// startup down. A theme preference must never be able to stop the app booting.
Future<ThemeModePreference> readStoredThemeMode([
  ThemeModeStore store = const SharedPreferencesThemeModeStore(),
]) async {
  try {
    return await store.read() ?? ThemeModePreference.fallback;
  } catch (_) {
    return ThemeModePreference.fallback;
  }
}
