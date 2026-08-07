/// Persists whether the first-run welcome flow has been completed.
///
/// This flag is deliberately independent from the app version: once a user has
/// completed (or skipped) onboarding, a normal update must never make it appear
/// again.
abstract interface class OnboardingStore {
  Future<bool?> readCompleted();
  Future<void> writeCompleted(bool completed);
}
