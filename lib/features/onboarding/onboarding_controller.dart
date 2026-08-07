import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/onboarding_store_provider.dart';

/// Seeded before the first frame by main.dart so the router never flashes the
/// wrong destination at startup.
final initialOnboardingCompletedProvider = Provider<bool>((ref) => false);

class OnboardingController extends Notifier<bool> {
  @override
  bool build() => ref.read(initialOnboardingCompletedProvider);

  Future<void> complete() async {
    if (state) return;
    state = true;
    try {
      await ref.read(onboardingStoreProvider).writeCompleted(true);
    } catch (_) {
      // The visible transition should never be rolled back because a preference
      // write failed. Worst case, onboarding may be offered again next launch.
    }
  }
}

final onboardingControllerProvider =
    NotifierProvider<OnboardingController, bool>(OnboardingController.new);
