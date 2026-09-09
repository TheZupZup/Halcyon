import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/replay_gain.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';

/// A channel-free engine that records the volumes the controller pushes, so the
/// listener's level can be checked where it actually lands.
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<double> volumes = <double>[];

  @override
  Stream<PlayerState> get playerStateStream =>
      const Stream<PlayerState>.empty();
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      const Stream<PlaybackEvent>.empty();

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// Flushes the unawaited `setVolume` the controller fires.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Track track({ReplayGain gain = ReplayGain.none}) =>
      Track(id: 't', title: 'T', uri: 'file:///t.flac', replayGain: gain);

  group('JustAudioPlaybackController.volumeFor', () {
    test('full volume when normalization is off, whatever the gain', () {
      final loud = track(gain: const ReplayGain(trackGainDb: -12.0));
      expect(
        JustAudioPlaybackController.volumeFor(loud, normalizeVolume: false),
        1.0,
      );
    });

    test('full volume when there is no track', () {
      expect(
        JustAudioPlaybackController.volumeFor(null, normalizeVolume: true),
        1.0,
      );
    });

    test('full volume for a track with no ReplayGain even when on', () {
      expect(
        JustAudioPlaybackController.volumeFor(track(), normalizeVolume: true),
        1.0,
      );
    });

    test('attenuates a loud track when normalization is on', () {
      final loud = track(gain: const ReplayGain(trackGainDb: -6.0));
      final v =
          JustAudioPlaybackController.volumeFor(loud, normalizeVolume: true);
      expect(v, lessThan(1.0));
      expect(v, closeTo(0.501, 0.01));
    });

    test('never amplifies a quiet track (clamped to full)', () {
      final quiet = track(gain: const ReplayGain(trackGainDb: 6.0));
      expect(
        JustAudioPlaybackController.volumeFor(quiet, normalizeVolume: true),
        1.0,
      );
    });
  });

  group('JustAudioPlaybackController volume and mute', () {
    ({JustAudioPlaybackController controller, _RecordingPlayer player})
        build() {
      final _RecordingPlayer player = _RecordingPlayer();
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: player);
      addTearDown(controller.dispose);
      return (controller: controller, player: player);
    }

    test('starts at full volume, unmuted', () {
      final built = build();

      expect(built.controller.state.volume, 1.0);
      expect(built.controller.state.muted, isFalse);
      expect(built.controller.state.effectiveVolume, 1.0);
    });

    test('setVolume reaches the engine and the emitted state', () async {
      final built = build();

      final List<double> emitted = <double>[];
      final sub =
          built.controller.stateStream.listen((s) => emitted.add(s.volume));

      built.controller.setVolume(0.25);
      await _settle();

      expect(built.controller.state.volume, 0.25);
      expect(built.player.volumes.last, 0.25);
      expect(emitted, contains(0.25));
      await sub.cancel();
    });

    test('a volume outside 0-1 is clamped, never passed on', () async {
      final built = build();

      // From half volume, so a clamped value is a real change the engine sees.
      built.controller.setVolume(0.5);
      await _settle();

      built.controller.setVolume(4.2);
      await _settle();
      expect(built.controller.state.volume, 1.0);
      expect(built.player.volumes.last, 1.0);

      built.controller.setVolume(-3);
      await _settle();
      expect(built.controller.state.volume, 0.0);
      expect(built.player.volumes.last, 0.0);
    });

    test(
        'a non-finite volume falls back to full rather than reaching the '
        'engine', () async {
      final built = build();

      built.controller.setVolume(double.nan);
      await _settle();

      expect(built.controller.state.volume, 1.0);
      expect(built.player.volumes, everyElement(isNot(isNaN)));
    });

    test('a redundant setVolume does not emit', () async {
      final built = build();

      var emissions = 0;
      final sub = built.controller.stateStream.listen((_) => emissions++);

      built.controller.setVolume(1.0); // already full
      await _settle();

      expect(emissions, 0);
      await sub.cancel();
    });

    test('mute silences the engine and unmute restores the same level',
        () async {
      final built = build();

      built.controller.setVolume(0.4);
      await _settle();

      built.controller.setMuted(true);
      await _settle();
      expect(built.player.volumes.last, 0.0);
      expect(built.controller.state.muted, isTrue);
      // The level is kept, not overwritten by the mute.
      expect(built.controller.state.volume, 0.4);
      expect(built.controller.state.effectiveVolume, 0.0);

      built.controller.setMuted(false);
      await _settle();
      expect(built.player.volumes.last, 0.4);
      expect(built.controller.state.effectiveVolume, 0.4);
    });

    test('raising the volume while muted unmutes', () async {
      final built = build();

      built.controller.setVolume(0.8);
      built.controller.setMuted(true);
      await _settle();

      built.controller.setVolume(0.3);
      await _settle();

      expect(built.controller.state.muted, isFalse);
      expect(built.player.volumes.last, 0.3);
    });

    test('setting the volume to zero leaves the mute flag alone', () async {
      final built = build();

      built.controller.setMuted(true);
      built.controller.setVolume(0);
      await _settle();

      expect(built.controller.state.muted, isTrue,
          reason: 'zero is already silent; it is not an unmute');
    });

    test('the listener level reaches the engine on its own', () async {
      final built = build();

      built.controller.setVolume(0.5);
      await _settle();

      expect(built.player.volumes.last, 0.5);
    });
  });

  group('JustAudioPlaybackController.engineVolumeFor', () {
    double engine(
      Track? t, {
      bool normalizeVolume = false,
      double volume = 1.0,
      bool muted = false,
      bool ducked = false,
    }) =>
        JustAudioPlaybackController.engineVolumeFor(
          t,
          normalizeVolume: normalizeVolume,
          volume: volume,
          muted: muted,
          ducked: ducked,
        );

    test('full volume with nothing attenuating', () {
      expect(engine(track()), 1.0);
    });

    test('the listener level and ReplayGain multiply', () {
      final loud = track(gain: const ReplayGain(trackGainDb: -6.0));
      final double normalized =
          JustAudioPlaybackController.volumeFor(loud, normalizeVolume: true);

      expect(
        engine(loud, normalizeVolume: true, volume: 0.5),
        closeTo(normalized * 0.5, 0.0001),
      );
    });

    test('mute silences whatever else is applied', () {
      final loud = track(gain: const ReplayGain(trackGainDb: -6.0));

      expect(
          engine(loud, normalizeVolume: true, volume: 0.8, muted: true), 0.0);
    });

    test('a duck attenuates the listener level without replacing it', () {
      final double ducked = engine(track(), volume: 0.6, ducked: true);

      expect(ducked, lessThan(0.6),
          reason: 'a duck lowers whatever the listener chose');
      expect(ducked, greaterThan(0.0),
          reason: 'ducking stays audible, it never silences');
    });

    test('never exceeds full volume', () {
      final quiet = track(gain: const ReplayGain(trackGainDb: 6.0));

      expect(engine(quiet, normalizeVolume: true), lessThanOrEqualTo(1.0));
    });
  });

  group('PlaybackState.sanitizeVolume', () {
    test('passes an in-range level through', () {
      expect(PlaybackState.sanitizeVolume(0.35), 0.35);
    });

    test('clamps out-of-range levels', () {
      expect(PlaybackState.sanitizeVolume(1.5), 1.0);
      expect(PlaybackState.sanitizeVolume(-0.5), 0.0);
    });

    test('falls back to full volume for a non-finite level', () {
      expect(PlaybackState.sanitizeVolume(double.nan), 1.0);
      expect(PlaybackState.sanitizeVolume(double.infinity), 1.0);
    });
  });
}
