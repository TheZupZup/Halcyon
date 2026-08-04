import '../../core/models/theme_mode_preference.dart';
import '../../core/repositories/theme_mode_store.dart';

/// Test-friendly [ThemeModeStore] that keeps one value in memory.
class InMemoryThemeModeStore implements ThemeModeStore {
  InMemoryThemeModeStore([this._preference]);

  ThemeModePreference? _preference;

  /// The last written value, for assertions.
  ThemeModePreference? get preference => _preference;

  @override
  Future<ThemeModePreference?> read() async => _preference;

  @override
  Future<void> write(ThemeModePreference preference) async {
    _preference = preference;
  }
}
