import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_onboarding_store.dart';
import 'package:linthra/data/repositories/onboarding_store_provider.dart';
import 'package:linthra/features/onboarding/onboarding_controller.dart';

void main() {
  test(
    'bootstrap reads completion from the overridden onboarding store',
    () async {
      final store = InMemoryOnboardingStore(initial: true);
      final container = ProviderContainer(
        overrides: [
          onboardingStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);

      final completed =
          await container.read(onboardingBootstrapProvider.future);

      expect(completed, isTrue);
    },
  );
}
