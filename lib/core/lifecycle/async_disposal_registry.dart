import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Collects the futures produced by *asynchronous* provider teardown so the
/// owner of a [ProviderContainer] can await them.
///
/// `ProviderContainer.dispose()` runs every `ref.onDispose` callback
/// synchronously and returns `void`: a callback that starts an asynchronous
/// close — `db.close()`, a WebSocket `stop()`, an `AudioPlayer.dispose()` —
/// is fire-and-forget as far as Riverpod is concerned. That is fine while a
/// process is exiting anyway, and wrong for the shutdown lifecycle Linthra
/// promises: `await ApplicationHandle.shutdown()` must mean *the database file
/// is closed and the sockets are gone*, so a restart in the same process gets
/// a clean slate instead of racing the previous container's cleanup.
///
/// The registry closes that gap without adding delays or a bespoke teardown
/// path per resource: a provider registers its teardown with
/// [AsyncDisposalRef.onDisposeAsync] instead of `ref.onDispose`, Riverpod still
/// starts it at exactly the same moment, and the returned future is parked here
/// until [settle] observes it.
///
/// Teardown failures are swallowed on purpose — shutdown must never throw, and
/// one resource that cannot close must not strand the ones behind it. They stay
/// observable through [failures] for tests and diagnostics.
class AsyncDisposalRegistry {
  final List<Future<void>> _pending = <Future<void>>[];
  final List<Object> _failures = <Object>[];

  /// Errors thrown by tracked teardowns, in completion order.
  List<Object> get failures => List<Object>.unmodifiable(_failures);

  /// Whether every teardown tracked so far has completed.
  bool get isSettled => _pending.isEmpty;

  /// Number of teardowns still running.
  int get pendingCount => _pending.length;

  /// Tracks one teardown. A synchronous teardown (`void`) is already complete
  /// by the time it returns and is not tracked.
  void track(FutureOr<void> disposal) {
    if (disposal is! Future<void>) return;
    late final Future<void> tracked;
    tracked = disposal
        .then<void>(
          (_) {},
          onError: _failures.add,
        )
        .whenComplete(() => _pending.remove(tracked));
    _pending.add(tracked);
  }

  /// Completes once every tracked teardown has finished, including teardowns
  /// started *by* another teardown (a repository that closes its store, which
  /// closes its client) — hence the loop rather than a single [Future.wait].
  Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_pending));
    }
  }
}

/// The container-wide [AsyncDisposalRegistry].
///
/// One per [ProviderContainer], so two containers — the one being shut down and
/// the one replacing it — never wait on each other.
final asyncDisposalRegistryProvider = Provider<AsyncDisposalRegistry>((ref) {
  return AsyncDisposalRegistry();
});

/// Registers asynchronous teardown that the container's owner can await.
extension AsyncDisposalRef on Ref {
  /// Like `ref.onDispose`, but the future [dispose] returns is awaited by
  /// [AsyncDisposalRegistry.settle] — which `ApplicationHandle.shutdown()`
  /// awaits after disposing the container.
  ///
  /// Use this for anything whose close is observable from outside the process
  /// image: a database connection, a socket, a file handle, a platform player.
  /// Purely in-memory teardown (cancelling a timer, closing a broadcast
  /// controller nothing else waits on) can stay on plain `ref.onDispose`.
  void onDisposeAsync(FutureOr<void> Function() dispose) {
    // Resolved during build, not during teardown: reading a provider from
    // inside an onDispose callback is not allowed.
    final AsyncDisposalRegistry registry = read(asyncDisposalRegistryProvider);
    onDispose(() => registry.track(dispose()));
  }
}
