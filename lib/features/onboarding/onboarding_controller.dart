import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/install_history.dart';
import '../../data/repositories/onboarding_store_provider.dart';

/// Resolves first-install state before the router is built.
///
/// A persisted completion flag wins. When v0.2.0 first lands, older installs do
/// not have that key yet, so Android's own install/update timestamps distinguish
/// an update from a true fresh install. This keeps onboarding first-install-only
/// even for an existing user who never configured a music source.
final onboardingBootstrapProvider = FutureProvider<bool>((ref) async {
  final bool? stored = await readStoredOnboardingCompleted();
  if (stored != null) return stored;

  final InstallHistory? history = await readPlatformInstallHistory();
  return history?.isUpdate ?? false;
});

class OnboardingController extends Notifier<bool> {
  @override
  bool build() {
    return ref.watch(onboardingBootstrapProvider).valueOrNull ?? false;
  }

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
