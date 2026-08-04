/// The user's theme-mode choice, as persisted.
///
/// Deliberately Flutter-free (like `CustomThemeSettings`) so a lightweight
/// key/value store can persist it as one short string. The mapping onto
/// Material's `ThemeMode` lives with the appearance feature that renders it.
///
/// The stored value is a non-secret display preference: no account, server,
/// library, or playback data is involved.
enum ThemeModePreference {
  /// Follow the phone's light/dark setting. The default, and what most people
  /// expect from an app that offers the choice at all.
  system('system'),

  /// Always light, regardless of the phone.
  light('light'),

  /// Always dark, regardless of the phone. What Linthra did unconditionally
  /// before this preference existed.
  dark('dark');

  const ThemeModePreference(this.storageId);

  /// The stable string written to storage. Never shown to users, and never
  /// renamed — a stored value must keep resolving across app updates.
  final String storageId;

  /// What an absent, empty, or unrecognised stored value resolves to.
  ///
  /// Following the phone is the safe landing spot: it is the documented
  /// default, and it is what a first-run install gets.
  static const ThemeModePreference fallback = ThemeModePreference.system;

  /// Resolves a stored [storageId] back to its preference, falling back to
  /// [fallback] for anything unrecognised — the same "unknown → default" rule
  /// the branding variants use, so a corrupted or downgraded preference can
  /// never leave the app without a theme mode.
  static ThemeModePreference fromStorageId(String? storageId) {
    if (storageId == null || storageId.isEmpty) {
      return fallback;
    }
    for (final ThemeModePreference preference in values) {
      if (preference.storageId == storageId) {
        return preference;
      }
    }
    return fallback;
  }
}
