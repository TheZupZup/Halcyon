import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/library_tab_store.dart';

/// A [LibraryTabStore] backed by `shared_preferences`.
///
/// One non-secret string under one key. An absent or empty value reads as
/// `null` (the first tab) rather than throwing, so a storage problem degrades
/// to today's behaviour instead of breaking the Library screen.
class SharedPreferencesLibraryTabStore implements LibraryTabStore {
  const SharedPreferencesLibraryTabStore();

  static const String _key = 'library_tab_v1';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> write(String? tabName) async {
    final prefs = await SharedPreferences.getInstance();
    if (tabName == null || tabName.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, tabName);
  }
}
