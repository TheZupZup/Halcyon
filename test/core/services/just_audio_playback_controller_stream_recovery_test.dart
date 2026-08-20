import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/stream_interruption.dart';

/// Fake engine with controllable state and error streams for mid-stream recovery
/// tests. No platform channel is touched.
class _ControllablePlayer extends Fake implements AudioPlayer {
  _ControllablePlayer();

  final StreamController<PlayerState> _playerStateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _playbackEventController =
      StreamController<PlaybackEvent>.broadcast();

  final List<String> setUrlCalls = <String>[];
  int playCalls = 0;

  /// URIs whose [setUrl] should throw.
  Set<String> failUrls = <String>{};

  /// When true, every [setUrl] after the first successful one throws, simulating
  /// a server that dies mid-playback on retry.
  bool failAfterFirstSuccess = false;
  bool _hadSuccessfulSetUrl = false;

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      _playbackEventController.stream;

  void emitState(PlayerState state) => _playerStateController.add(state);

  void emitError(Object error) =>
      _playbackEventController.addError(error, StackTrace.empty);

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    setUrlCalls.add(url);
    final bool shouldFail = failUrls.contains(url) ||
        (failAfterFirstSuccess && _hadSuccessfulSetUrl);
    if (shouldFail) {
      throw Exception('engine could not open source');
    }
    _hadSuccessfulSetUrl = true;
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
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {
    await _playerStateController.close();
    await _playbackEventController.close();
  }
}

/// Resolver that can flip between reachable and unreachable per uri, modelling a
/// server that disappears and later returns. Never echoes secrets in messages.
class _FlappingResolver implements PlayableUriResolver {
  _FlappingResolver({
    required this.reachable,
    this.token = 'SECRET-TOKEN',
  });

  final Set<String> reachable;
  final String token;
  final List<String> calls = <String>[];
  int _counter = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    if (!reachable.contains(track.uri)) {
      throw const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    _counter++;
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.uri}'
          '?n=$_counter&api_key=$token'),
      PlaybackSource.streamingDirect,
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

  final Track jelly = _track('j', 'jellyfin:j');
  final Track sub = _track('s', 'subsonic:s');
  final Track next = _track('n', 'jellyfin:n');

  JustAudioPlaybackController build({
    required _ControllablePlayer player,
    required PlayableUriResolver resolver,
    Map<String, List<Track>> candidates = const <String, List<Track>>{},
  }) {
    final controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      candidates: MapPlaybackCandidateSource(() => candidates),
    )..midStreamBufferingTimeout = Duration.zero;
    addTearDown(controller.dispose);
    return controller;
  }

  group('mid-stream server disappearance', () {
    Future<void> startPlaying(
      JustAudioPlaybackController controller,
      _ControllablePlayer player,
    ) async {
      await controller.playTracks(<Track>[jelly]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    }

    test('a transient drop gets one bounded retry', () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{'jellyfin:j'});
      final controller = build(player: player, resolver: resolver);

      await startPlaying(controller, player);
      expect(resolver.calls, <String>['jellyfin:j']);

      controller.handleStreamFailureForTesting(
        classifyEngineError(Exception('Connection reset while reading')),
      );
      await Future<void>.delayed(Duration.zero);

      expect(resolver.calls, <String>['jellyfin:j', 'jellyfin:j']);
      expect(player.setUrlCalls.length, 2);
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('concurrent mid-stream failures start only one recovery', () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{'jellyfin:j'});
      final controller = build(player: player, resolver: resolver);

      await startPlaying(controller, player);
      expect(resolver.calls, <String>['jellyfin:j']);

      // Watchdog + engine error racing: both enter the shared path, but the
      // in-flight gate must admit only one bounded retry.
      const StreamInterruption failure = StreamInterruption(
        StreamInterruptionKind.serverUnreachable,
        "Couldn't reach your music server. Check your connection and try again.",
        retryable: true,
      );
      controller.handleStreamFailureForTesting(failure);
      controller.handleStreamFailureForTesting(failure);
      controller.onBufferingTimeoutForTesting();
      await Future<void>.delayed(Duration.zero);

      expect(resolver.calls, <String>['jellyfin:j', 'jellyfin:j']);
      expect(player.setUrlCalls.length, 2);
    });

    test('retry exhaustion falls back to a sibling source copy', () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(
        reachable: <String>{'jellyfin:j', 'subsonic:s'},
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly, sub],
        },
      );
      // Avoid the post-recovery zero-timeout re-arm firing between the two
      // deliberate failure injections (build() defaults to Duration.zero).
      controller.midStreamBufferingTimeout = const Duration(hours: 1);

      await controller.playTracks(<Track>[jelly, next]);
      // Drive status through the controller only — avoid a parallel player-state
      // stream event that can arrive after recovery and refill the retry budget.
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      expect(resolver.calls, <String>['jellyfin:j']);

      // First retryable failure → consumes the one bounded retry on the same
      // source (still jellyfin).
      await controller.handleStreamFailureForTestingAsync(
        const StreamInterruption(
          StreamInterruptionKind.networkDropped,
          'The connection dropped while streaming. Reconnecting…',
          retryable: true,
        ),
      );
      expect(resolver.calls, <String>['jellyfin:j', 'jellyfin:j']);

      // Second retryable failure → budget exhausted → remaining sibling.
      await controller.handleStreamFailureForTestingAsync(
        const StreamInterruption(
          StreamInterruptionKind.serverUnreachable,
          "Couldn't reach your music server. Check your connection and try again.",
          retryable: true,
        ),
      );

      expect(controller.state.currentTrack?.uri, 'subsonic:s');
      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(controller.state.upNext.map((Track t) => t.uri).toList(),
          <String>['jellyfin:n']);
      expect(
          resolver.calls, <String>['jellyfin:j', 'jellyfin:j', 'subsonic:s']);
      expect(player.setUrlCalls.length, 3);
    });

    test('persistent disappearance surfaces error and preserves the queue',
        () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{'jellyfin:j'});
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly, next]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      resolver.reachable.remove('jellyfin:j');
      await controller.handleStreamFailureForTestingAsync(
        const StreamInterruption(
          StreamInterruptionKind.serverUnreachable,
          "Couldn't reach your music server. Check your connection and try again.",
          retryable: true,
        ),
      );
      await controller.handleStreamFailureForTestingAsync(
        const StreamInterruption(
          StreamInterruptionKind.serverUnreachable,
          "Couldn't reach your music server. Check your connection and try again.",
          retryable: true,
        ),
      );

      final PlaybackState s = controller.state;
      expect(s.status, PlaybackStatus.error);
      expect(s.currentTrack?.uri, 'jellyfin:j');
      expect(s.upNext.map((Track t) => t.uri).toList(), <String>['jellyfin:n']);
      expect(s.errorMessage, isNot(contains('SECRET')));
      expect(s.errorMessage, isNot(contains('http')));
      // Bounded: each candidate is probed at most a handful of times — never loops.
      expect(resolver.calls.length, lessThanOrEqualTo(6));
      expect(
        resolver.calls.where((String u) => u == 'subsonic:s').length,
        greaterThanOrEqualTo(1),
      );
    });

    test('a non-retryable auth failure skips retry and tries fallback',
        () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(
        reachable: <String>{'subsonic:s'},
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.handleStreamFailureForTesting(
        const StreamInterruption(
          StreamInterruptionKind.sessionExpired,
          'Your session expired. Sign in again to keep streaming.',
          retryable: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.currentTrack?.uri, 'subsonic:s');
      expect(resolver.calls, <String>['jellyfin:j', 'subsonic:s']);
    });
  });

  group('buffering watchdog', () {
    test('prolonged mid-stream buffering is treated as server unreachable',
        () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{'jellyfin:j'});
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[jelly]);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      controller
          .handleEngineState(PlayerState(true, ProcessingState.buffering));

      resolver.reachable.remove('jellyfin:j');
      controller.onBufferingTimeoutForTesting();
      await Future<void>.delayed(Duration.zero);
      controller.onBufferingTimeoutForTesting();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, PlaybackStatus.error);
      expect(resolver.calls.length, lessThanOrEqualTo(2));
    });

    test('controller-driven recovery buffering cannot hang past the watchdog',
        () async {
      // After a mid-stream retry reloads successfully, status stays buffering
      // until the engine reports playing. With no engine events, the recovery
      // path re-arms the watchdog; a timeout must reach a terminal error
      // instead of hanging forever.
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{'jellyfin:j'});
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[jelly]);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      expect(resolver.calls, <String>['jellyfin:j']);

      await controller.handleStreamFailureForTestingAsync(
        const StreamInterruption(
          StreamInterruptionKind.networkDropped,
          'The connection dropped while streaming. Reconnecting…',
          retryable: true,
        ),
      );
      // Retry loaded (second resolve) but we never emit playing.
      expect(resolver.calls, <String>['jellyfin:j', 'jellyfin:j']);
      expect(controller.state.status, PlaybackStatus.buffering);

      // Same escape the re-armed watchdog uses: budget already spent → error.
      controller.onBufferingTimeoutForTesting();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.uri, 'jellyfin:j');
      // No further resolve hammering after the bounded escape.
      expect(resolver.calls, <String>['jellyfin:j', 'jellyfin:j']);
    });
  });

  group('manual recovery after outage', () {
    test('play() from error re-resolves when the server returns', () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{});
      final controller = build(player: player, resolver: resolver);

      await controller.playTracks(<Track>[jelly]);
      expect(controller.state.status, PlaybackStatus.error);

      resolver.reachable.add('jellyfin:j');
      await controller.play();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(controller.state.currentTrack?.uri, 'jellyfin:j');
      expect(resolver.calls.length, 2);
    });
  });

  group('fake-server resolver integration', () {
    test('server-down then up models disappearance and recovery', () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{'jellyfin:j'});
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);
      expect(controller.state.status, isNot(PlaybackStatus.error));

      resolver.reachable.remove('jellyfin:j');
      controller.handleStreamFailureForTesting(
        const StreamInterruption(
          StreamInterruptionKind.serverUnreachable,
          "Couldn't reach your music server. Check your connection and try again.",
          retryable: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      controller.handleStreamFailureForTesting(
        const StreamInterruption(
          StreamInterruptionKind.serverUnreachable,
          "Couldn't reach your music server. Check your connection and try again.",
          retryable: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, PlaybackStatus.error);

      resolver.reachable.add('jellyfin:j');
      await controller.play();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(resolver.calls.last, 'jellyfin:j');
    });

    test('fallback uses the existing candidate policy when primary stays down',
        () async {
      final player = _ControllablePlayer();
      final resolver = _FlappingResolver(reachable: <String>{'subsonic:s'});
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.handleStreamFailureForTesting(
        const StreamInterruption(
          StreamInterruptionKind.serverUnreachable,
          "Couldn't reach your music server. Check your connection and try again.",
          retryable: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      controller.handleStreamFailureForTesting(
        const StreamInterruption(
          StreamInterruptionKind.serverUnreachable,
          "Couldn't reach your music server. Check your connection and try again.",
          retryable: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.currentTrack?.uri, 'subsonic:s');
      expect(
        resolver.calls.where((String u) => u == 'subsonic:s').length,
        greaterThanOrEqualTo(1),
      );
    });
  });
}
