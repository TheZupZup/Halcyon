import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/theme_mode_preference.dart';
import '../../data/repositories/theme_mode_store_provider.dart';

/// The theme mode the controller starts from on its very first build.
///
/// Defaults to following the device. `main` overrides it with the value read
/// from storage *before* `runApp`, so the first frame is already correct and
/// there is no dark-then-light flash on launch.
///
/// This seam is why the controller has no async load of its own: the value is
/// known before any frame exists, which also removes the race where a stored
/// value lands after the user has already tapped a different option.
final initialThemeModeProvider = Provider<ThemeModePreference>((ref) {
  return ThemeModePreference.fallback;
});

/// Holds the user's System / Light / Dark choice and persists every change.
class ThemeModeController extends Notifier<ThemeModePreference> {
  @override
  ThemeModePreference build() => ref.read(initialThemeModeProvider);

  /// Applies [preference] immediately and persists it best-effort.
  ///
  /// The UI updates from [state] rather than from the write completing, so the
  /// theme switches on tap even if storage is slow or unavailable.
  Future<void> select(ThemeModePreference preference) async {
    if (preference == state) {
      return;
    }
    state = preference;
    try {
      await ref.read(themeModeStoreProvider).write(preference);
    } catch (_) {
      // A failed preference write must never surface as an error or undo the
      // user's visible choice; it just will not survive the next restart.
    }
  }
}

/// The app's theme mode. `LinthraApp` watches this, so a change repaints every
/// screen at once.
final themeModeControllerProvider =
    NotifierProvider<ThemeModeController, ThemeModePreference>(
  ThemeModeController.new,
);

/// Maps the persisted preference onto Material's [ThemeMode].
///
/// Kept out of the model itself so `ThemeModePreference` stays Flutter-free and
/// storable by a plain key/value store.
extension ThemeModePreferenceMaterial on ThemeModePreference {
  ThemeMode get materialThemeMode => switch (this) {
        ThemeModePreference.system => ThemeMode.system,
        ThemeModePreference.light => ThemeMode.light,
        ThemeModePreference.dark => ThemeMode.dark,
      };

  /// The user-facing option label.
  String get label => switch (this) {
        ThemeModePreference.system => 'System',
        ThemeModePreference.light => 'Light',
        ThemeModePreference.dark => 'Dark',
      };

  /// The icon shown beside [label] in the picker.
  IconData get icon => switch (this) {
        ThemeModePreference.system => Icons.brightness_auto_outlined,
        ThemeModePreference.light => Icons.light_mode_outlined,
        ThemeModePreference.dark => Icons.dark_mode_outlined,
      };
}
