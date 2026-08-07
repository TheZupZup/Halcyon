import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linthra/data/repositories/in_memory_onboarding_store.dart';
import 'package:linthra/data/repositories/onboarding_store_provider.dart';

List<Override> completedOnboardingOverrides() {
  return <Override>[
    onboardingStoreProvider.overrideWithValue(
      InMemoryOnboardingStore(initial: true),
    ),
  ];
}
