import '../../core/repositories/onboarding_store.dart';

class InMemoryOnboardingStore implements OnboardingStore {
  InMemoryOnboardingStore({bool? initial}) : _completed = initial;

  bool? _completed;

  @override
  Future<bool?> readCompleted() async => _completed;

  @override
  Future<void> writeCompleted(bool completed) async {
    _completed = completed;
  }
}
