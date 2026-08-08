import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/onboarding_store.dart';
import 'shared_preferences_onboarding_store.dart';

/// Onboarding is install state, so production uses SharedPreferences directly.
/// Tests that exercise persistence can override this provider with an in-memory
/// store; calls from ordinary widget tests are still failure-soft in the
/// controller and never block navigation.
final onboardingStoreProvider = Provider<OnboardingStore>((ref) {
  return const SharedPreferencesOnboardingStore();
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
