import 'dart:math';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'just_audio_playback_controller.dart';
import 'local_playable_uri_resolver.dart';
import 'playable_uri_resolver.dart';
import 'playback_candidate_source.dart';

typedef LinuxPlaybackBackendRegistration = void Function();

/// Registers just_audio's Linux implementation once for this process.
///
/// Registration is synchronous, so the success flag cannot race another call
/// in the same isolate. It is deliberately set after registration returns: if
/// native setup throws, the next controller construction can retry.
class LinuxPlaybackBackendInitializer {
  LinuxPlaybackBackendInitializer({
    LinuxPlaybackBackendRegistration? registerBackend,
  }) : _registerBackend = registerBackend ?? _registerDefaultBackend;

  final LinuxPlaybackBackendRegistration _registerBackend;
  bool _initialized = false;

  void ensureInitialized() {
    if (_initialized) return;
    _registerBackend();
    _initialized = true;
  }

  static void _registerDefaultBackend() {
    JustAudioMediaKit.title = 'Linthra';
    JustAudioMediaKit.ensureInitialized(linux: true, windows: false);
  }
}

/// Linux on-device playback backed by media_kit and the declared libmpv runtime.
///
/// The transport, queue, resolver fallback and completion behaviour deliberately
/// stay in [JustAudioPlaybackController]. This class only registers the Linux
/// federated implementation before that controller creates its [AudioPlayer].
/// Android never constructs this type and therefore keeps just_audio's native
/// ExoPlayer implementation and its existing audio-service/audio-focus path.
class LinuxPlaybackController extends JustAudioPlaybackController {
  static final LinuxPlaybackBackendInitializer _backendInitializer =
      LinuxPlaybackBackendInitializer();

  factory LinuxPlaybackController({
    AudioPlayer? player,
    PlayableUriResolver resolver = const LocalPlayableUriResolver(),
    PlaybackCandidateSource candidates = const NoFallbackCandidateSource(),
    PlayableUriResolver? streamingFallbackResolver,
    Random? random,
    TrackCompletionCallback? onTrackCompleted,
  }) {
    // Tests inject an AudioPlayer explicitly. The production path registers
    // media_kit before the superclass can construct its AudioPlayer.
    if (player == null) _backendInitializer.ensureInitialized();
    return LinuxPlaybackController._(
      player: player,
      resolver: resolver,
      candidates: candidates,
      streamingFallbackResolver: streamingFallbackResolver,
      random: random,
      onTrackCompleted: onTrackCompleted,
    );
  }

  LinuxPlaybackController._({
    super.player,
    required super.resolver,
    required super.candidates,
    super.streamingFallbackResolver,
    super.random,
    super.onTrackCompleted,
  });
}
