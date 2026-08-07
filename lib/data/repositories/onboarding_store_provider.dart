import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/onboarding_store.dart';
import 'in_memory_onboarding_store.dart';
import 'shared_preferences_onboarding_store.dart';

final onboardingStoreProvider = Provider<OnboardingStore>((ref) {
  return InMemoryOnboardingStore();
});

final sharedPreferencesOnboardingStoreOverride =
    onboardingStoreProvider.overrideWithValue(
  const SharedPreferencesOnboardingStore(),
);

Future<bool?> readStoredOnboardingCompleted([
  OnboardingStore store = const SharedPreferencesOnboardingStore(),
]) async {
  try {
    return await store.readCompleted();
  } catch (_) {
    return null;
  }
}
