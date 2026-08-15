import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/unsupported_playback_controller.dart';

Track _track(String id) => Track(
      id: id,
      title: 'Song $id',
      uri: 'file:///music/$id.mp3',
      artistName: 'Artist',
      albumName: 'Album',
      duration: const Duration(minutes: 3),
    );

void main() {
  late UnsupportedPlaybackController controller;

  setUp(() {
    controller = UnsupportedPlaybackController();
  });

  tearDown(() async {
    await controller.dispose();
  });

  test('starts idle and silent', () {
    expect(controller.state.status, PlaybackStatus.idle);
    expect(controller.state.currentTrack, isNull);
    expect(controller.isSuspended, isFalse);
  });

  group('a request to play', () {
    test('fails explicitly and names the track that was asked for', () async {
      await controller.playTrack(_track('a'));

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.state.errorMessage,
          UnsupportedPlaybackController.defaultReason);
    });

    test('never reports playing, buffering, or a position', () async {
      await controller.playTracks(<Track>[_track('a'), _track('b')]);
      await controller.play();
      await controller.skipToNext();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, Duration.zero);
      expect(controller.state.duration, Duration.zero);
    });

    test('keeps no queue — the failure is not dressed up as playback',
        () async {
      await controller.playTracks(
        <Track>[_track('a'), _track('b'), _track('c')],
      );

      expect(controller.state.upNext, isEmpty);
      expect(controller.state.previous, isEmpty);
      expect(controller.state.hasPrevious, isFalse);
    });

    test('playTracks reports the track at startIndex', () async {
      await controller.playTracks(
        <Track>[_track('a'), _track('b'), _track('c')],
        startIndex: 2,
      );

      expect(controller.state.currentTrack?.id, 'c');
    });

    test('an out-of-range startIndex still fails cleanly', () async {
      await controller.playTracks(<Track>[_track('a')], startIndex: 9);

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack, isNull);
    });

    test('the failure reaches listeners on the state stream', () async {
      final Future<PlaybackState> next = controller.stateStream.first;

      await controller.playTrack(_track('a'));

      expect((await next).status, PlaybackStatus.error);
    });

    test('a custom reason is used verbatim', () async {
      final custom = UnsupportedPlaybackController(reason: 'No audio here.');
      addTearDown(custom.dispose);

      await custom.playTrack(_track('a'));

      expect(custom.reason, 'No audio here.');
      expect(custom.state.errorMessage, 'No audio here.');
    });
  });

  group('modes and transport that do not need audio', () {
    test('shuffle and repeat are remembered without erroring', () {
      controller.setShuffleEnabled(true);
      controller.setRepeatMode(RepeatMode.all);

      expect(controller.state.shuffleEnabled, isTrue);
      expect(controller.state.repeatMode, RepeatMode.all);
      expect(controller.state.status, PlaybackStatus.idle,
          reason: 'setting a mode is not a request to play');
    });

    test('a mode set after a failure keeps the failure visible', () async {
      await controller.playTrack(_track('a'));
      controller.setRepeatMode(RepeatMode.one);

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.errorMessage,
          UnsupportedPlaybackController.defaultReason);
      expect(controller.state.repeatMode, RepeatMode.one);
    });

    test('pause, seek and queue edits are quiet no-ops', () async {
      await controller.pause();
      await controller.seek(const Duration(seconds: 30));
      controller.removeFromQueue(0);
      controller.reorderQueue(0, 1);
      controller.clearQueue();

      expect(controller.state.status, PlaybackStatus.idle);
    });

    test('stop returns to idle, clearing the error', () async {
      await controller.playTrack(_track('a'));
      await controller.stop();

      expect(controller.state.status, PlaybackStatus.idle);
      expect(controller.state.errorMessage, isNull);
    });
  });

  group('the cast-handoff half of LocalPlaybackController', () {
    test('never claims to be suspending a local engine', () async {
      await controller.suspend();
      expect(controller.isSuspended, isFalse);

      await controller.resume(at: const Duration(seconds: 10), play: true);
      await controller.restartQueue();
      controller.setVolumeNormalizationEnabled(true);
      controller.onAppForegrounded();

      expect(controller.state.status, PlaybackStatus.idle);
    });
  });

  group('dispose', () {
    test('is idempotent and stops emitting', () async {
      await controller.dispose();
      await controller.dispose();

      // Post-dispose calls must not throw on a closed stream controller — app
      // shutdown can race a last UI callback.
      await controller.playTrack(_track('a'));
      expect(controller.state.status, PlaybackStatus.idle);
    });
  });
}
