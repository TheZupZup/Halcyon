import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/lifecycle/async_disposal_registry.dart';

void main() {
  group('AsyncDisposalRegistry', () {
    test('settles only once every tracked teardown has completed', () async {
      final AsyncDisposalRegistry registry = AsyncDisposalRegistry();
      final Completer<void> first = Completer<void>();
      final Completer<void> second = Completer<void>();

      registry.track(first.future);
      registry.track(second.future);
      expect(registry.pendingCount, 2);
      expect(registry.isSettled, isFalse);

      bool settled = false;
      unawaited(registry.settle().then((_) => settled = true));

      first.complete();
      await pumpEventQueue();
      expect(settled, isFalse);

      second.complete();
      await pumpEventQueue();
      expect(settled, isTrue);
      expect(registry.isSettled, isTrue);
    });

    test('waits for teardown started by another teardown', () async {
      final AsyncDisposalRegistry registry = AsyncDisposalRegistry();
      final Completer<void> outer = Completer<void>();
      final Completer<void> inner = Completer<void>();

      registry.track(outer.future.then((_) => registry.track(inner.future)));

      bool settled = false;
      unawaited(registry.settle().then((_) => settled = true));

      outer.complete();
      await pumpEventQueue();
      expect(settled, isFalse, reason: 'the nested teardown is still running');

      inner.complete();
      await pumpEventQueue();
      expect(settled, isTrue);
    });

    test('a failing teardown is recorded, not rethrown', () async {
      final AsyncDisposalRegistry registry = AsyncDisposalRegistry();
      final Exception failure = Exception('close failed');

      registry.track(Future<void>.error(failure));
      await registry.settle();

      expect(registry.isSettled, isTrue);
      expect(registry.failures, <Object>[failure]);
    });

    test('synchronous teardown needs no tracking', () {
      final AsyncDisposalRegistry registry = AsyncDisposalRegistry();
      registry.track(null);
      expect(registry.isSettled, isTrue);
    });

    test('onDisposeAsync hands provider teardown to the container registry',
        () async {
      final Completer<void> gate = Completer<void>();
      bool finished = false;
      final Provider<Object> resource = Provider<Object>((Ref<Object> ref) {
        ref.onDisposeAsync(() async {
          await gate.future;
          finished = true;
        });
        return Object();
      });

      final ProviderContainer container = ProviderContainer();
      final AsyncDisposalRegistry registry =
          container.read(asyncDisposalRegistryProvider);
      container.read(resource);

      container.dispose();
      expect(finished, isFalse,
          reason:
              'ProviderContainer.dispose only starts asynchronous teardown');
      expect(registry.isSettled, isFalse);

      bool settled = false;
      unawaited(registry.settle().then((_) => settled = true));
      gate.complete();
      await pumpEventQueue();

      expect(finished, isTrue);
      expect(settled, isTrue);
    });

    test('each container gets its own registry', () {
      final ProviderContainer first = ProviderContainer();
      final ProviderContainer second = ProviderContainer();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(
        first.read(asyncDisposalRegistryProvider),
        isNot(same(second.read(asyncDisposalRegistryProvider))),
      );
    });
  });
}
