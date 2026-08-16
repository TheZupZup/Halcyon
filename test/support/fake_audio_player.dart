import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

/// Channel-free AudioPlayer used when a test intentionally builds Linux
/// playback providers without exercising the native plugin bundle.
class FakeAudioPlayer extends Fake implements AudioPlayer {
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {}
}
