import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/theme_mode_preference.dart';
import '../../core/repositories/theme_mode_store.dart';

/// Persists the theme-mode choice as a single non-secret string.
class SharedPreferencesThemeModeStore implements ThemeModeStore {
  const SharedPreferencesThemeModeStore();

  static const String _key = 'theme_mode_v1';

  @override
  Future<ThemeModePreference?> read() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? stored = preferences.getString(_key);
    if (stored == null) {
      return null;
    }
    // An unrecognised value (a downgrade, or a hand-edited preference file)
    // resolves to the default rather than throwing.
    return ThemeModePreference.fromStorageId(stored);
  }

  @override
  Future<void> write(ThemeModePreference preference) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key, preference.storageId);
  }
}
