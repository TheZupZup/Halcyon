import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';

/// Controllable engine for suspend/resume recovery — no platform channel.
class _Engine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  final List<String> setUrlCalls = <String>[];
  final List<Duration?> seekCalls = <Duration?>[];
  int playCalls = 0;
  bool failUrls = false;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
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
    setUrlCalls.add(url);
    if (failUrls) throw Exception('device not ready after wake');
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seekCalls.add(position);
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _events.close();
  }
}

class _Resolver implements PlayableUriResolver {
  _Resolver({this.reachable = true});

  bool reachable;
  final List<String> calls = <String>[];
  int _n = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    if (!reachable) {
      throw const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    _n++;
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.uri}?n=$_n'),
      track.uri.startsWith('/')
          ? PlaybackSource.localFile
          : PlaybackSource.streamingDirect,
    );
  }
}

Track _track(String id, String uri) => Track(
      id: id,
      title: 'Song',
      uri: uri,
      artistName: 'Artist',
      albumName: 'Album',
      duration: const Duration(minutes: 3),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track local = _track('l', '/music/a.flac');
  final Track remote = _track('r', 'jellyfin:r');
  final Track next = _track('n', 'jellyfin:n');

  LinuxPlaybackController buildLinux({
    required _Engine player,
    required _Resolver resolver,
  }) {
    final controller = LinuxPlaybackController(
      player: player,
      resolver: resolver,
      candidates: const NoFallbackCandidateSource(),
    )
      ..suspendResumeBackoff = Duration.zero
      ..midStreamBufferingTimeout = const Duration(hours: 1);
    addTearDown(controller.dispose);
    return controller;
  }

  JustAudioPlaybackController buildAndroid({
    required _Engine player,
    required _Resolver resolver,
  }) {
    final controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      // Android default: recoverPlaybackAfterSuspend == false
    )..suspendResumeBackoff = Duration.zero;
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> startPlaying(
    JustAudioPlaybackController controller,
    Track track,
  ) async {
    await controller.playTracks(<Track>[track, next]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
  }

  group('Linux suspend/resume recovery', () {
    test('paused across suspend stays paused — no reload, no autoplay',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final controller = buildLinux(player: player, resolver: resolver);

      await startPlaying(controller, local);
      await controller.pause();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      expect(controller.state.status, PlaybackStatus.paused);
      final int urlsBefore = player.setUrlCalls.length;

      controller.onAppBackgrounded();
      controller.onAppForegrounded();
      await Future<void>.delayed(Duration.zero);

      expect(player.setUrlCalls.length, urlsBefore);
      expect(controller.state.status, PlaybackStatus.paused);
      expect(controller.state.currentTrack?.uri, local.uri);
    });

    test('playing across suspend reloads once at the preserved position',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final controller = buildLinux(player: player, resolver: resolver);

      await startPlaying(controller, remote);
      const Duration preserved = Duration(minutes: 1, seconds: 5);
      controller.setPositionForTesting(preserved);
      expect(player.setUrlCalls, hasLength(1));
      final String firstUrl = player.setUrlCalls.single;

      controller.onAppBackgrounded();
      controller.onAppForegrounded();
      await Future<void>.delayed(Duration.zero);

      expect(resolver.calls, <String>[remote.uri, remote.uri]);
      expect(player.setUrlCalls, hasLength(2));
      expect(player.setUrlCalls.last, isNot(firstUrl));
      expect(player.seekCalls, contains(preserved));
      expect(controller.state.currentTrack?.uri, remote.uri);
      expect(controller.state.upNext.map((Track t) => t.uri).toList(),
          <String>[next.uri]);
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('concurrent resumes coalesce into one recovery', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final controller = buildLinux(player: player, resolver: resolver);
      controller.suspendResumeBackoff = const Duration(milliseconds: 30);

      await startPlaying(controller, remote);
      expect(resolver.calls, <String>[remote.uri]);

      controller.onAppBackgrounded();
      controller.onAppForegrounded();
      controller.onAppForegrounded();
      controller.onAppForegrounded();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(resolver.calls, <String>[remote.uri, remote.uri]);
      expect(player.setUrlCalls, hasLength(2));
    });

    test('failed recovery surfaces error and preserves the queue', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final controller = buildLinux(player: player, resolver: resolver);

      await startPlaying(controller, remote);
      controller.onAppBackgrounded();

      resolver.reachable = false;
      controller.onAppForegrounded();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.uri, remote.uri);
      expect(controller.state.upNext.map((Track t) => t.uri).toList(),
          <String>[next.uri]);
      expect(controller.state.errorMessage, isNot(contains('http')));
      expect(controller.state.errorMessage, isNotNull);
    });

    test('repeated suspend/resume cycles never stack overlapping reloads',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final controller = buildLinux(player: player, resolver: resolver);

      await startPlaying(controller, local);

      for (int i = 0; i < 3; i++) {
        controller.onAppBackgrounded();
        controller.onAppForegrounded();
        await Future<void>.delayed(Duration.zero);
      }

      // Initial load + one recovery per cycle.
      expect(player.setUrlCalls.length, 4);
      expect(controller.state.currentTrack?.uri, local.uri);
    });
  });

  group('Android suspend path stays inert', () {
    test('screen-on never reloads a playing track', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final controller = buildAndroid(player: player, resolver: resolver);

      await startPlaying(controller, remote);
      final int urlsBefore = player.setUrlCalls.length;

      controller.onAppBackgrounded();
      controller.onAppForegrounded();
      await Future<void>.delayed(Duration.zero);

      expect(player.setUrlCalls.length, urlsBefore);
      expect(resolver.calls, <String>[remote.uri]);
    });
  });
}
