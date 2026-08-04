import '../models/theme_mode_preference.dart';

/// Persists the user's System / Light / Dark choice.
///
/// The value is a non-secret display preference only. No account, server,
/// library, or playback data is stored here.
abstract interface class ThemeModeStore {
  /// Returns the stored preference, or `null` when the user has never chosen
  /// one — which the caller resolves to [ThemeModePreference.fallback].
  Future<ThemeModePreference?> read();

  /// Persists [preference].
  Future<void> write(ThemeModePreference preference);
}
