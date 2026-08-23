import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

/// Channel-free [AudioPlayer] that records lifecycle calls for shutdown tests.
///
/// Pass [disposeGate] to make teardown *observably* asynchronous: [dispose]
/// then parks until the test completes the gate, so a test can prove that
/// `ApplicationHandle.shutdown()` is still waiting rather than relying on
/// timing.
class CountingAudioPlayer extends Fake implements AudioPlayer {
  CountingAudioPlayer({this.disposeGate});

  /// When set, [dispose] does not finish until this completer completes.
  final Completer<void>? disposeGate;

  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast(sync: true);
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast(sync: true);
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast(sync: true);

  int disposeCount = 0;
  int stopCount = 0;
  int playCount = 0;

  /// Set the moment [dispose] is entered, before it awaits [disposeGate].
  bool disposeStarted = false;

  /// Set only once [dispose] has run to completion.
  bool disposeFinished = false;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    playCount++;
    _states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    _states.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _states.add(PlayerState(false, ProcessingState.idle));
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {
    disposeStarted = true;
    disposeCount++;
    final Completer<void>? gate = disposeGate;
    if (gate != null) await gate.future;
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _events.close();
    disposeFinished = true;
  }
}
