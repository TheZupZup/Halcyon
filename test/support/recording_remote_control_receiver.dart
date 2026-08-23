import 'dart:async';

import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/services/remote_control_receiver.dart';

/// A [RemoteControlReceiver] test double that records its transport lifecycle.
///
/// Stands in for the Jellyfin control socket: the real receiver's teardown is
/// asynchronous (cancel the socket subscription, close the WebSocket), which is
/// exactly the shape of cleanup `ApplicationHandle.shutdown()` has to wait for.
/// Pass [disposeGate] to hold [dispose] open until the test releases it.
class RecordingRemoteControlReceiver implements RemoteControlReceiver {
  RecordingRemoteControlReceiver({this.disposeGate});

  /// When set, [dispose] does not finish until this completer completes.
  final Completer<void>? disposeGate;

  final StreamController<RemoteCommand> _commands =
      StreamController<RemoteCommand>.broadcast(sync: true);

  int startCount = 0;
  int stopCount = 0;
  int disposeCount = 0;

  /// Set the moment [dispose] is entered, before it awaits [disposeGate].
  bool disposeStarted = false;

  /// Set only once [dispose] has run to completion.
  bool disposeFinished = false;

  /// Whether the command stream has been closed — the observable proof that
  /// the transport is really gone rather than merely asked to go.
  bool get commandsClosed => _commands.isClosed;

  @override
  Stream<RemoteCommand> get commands => _commands.stream;

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> dispose() async {
    disposeStarted = true;
    disposeCount++;
    final Completer<void>? gate = disposeGate;
    if (gate != null) await gate.future;
    await _commands.close();
    disposeFinished = true;
  }
}
