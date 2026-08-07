import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/onboarding_store.dart';

/// Production onboarding persistence.
///
/// The key is intentionally versionless: completing the welcome flow is an
/// install-level choice, not something that resets on every release.
class SharedPreferencesOnboardingStore implements OnboardingStore {
  const SharedPreferencesOnboardingStore();

  static const String _key = 'onboarding_completed';

  @override
  Future<bool?> readCompleted() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_key)) return null;
    return prefs.getBool(_key);
  }

  @override
  Future<void> writeCompleted(bool completed) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, completed);
  }
}
