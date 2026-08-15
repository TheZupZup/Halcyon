import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/local_playback_controller.dart';
import 'package:linthra/core/services/platform_playback_support.dart';
import 'package:linthra/core/services/unsupported_playback_controller.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

ProviderContainer _containerFor(HostPlatform host) {
  final container = ProviderContainer(
    overrides: <Override>[hostPlatformProvider.overrideWithValue(host)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('PlatformPlaybackSupport.hasOnDeviceEngine', () {
    test('is true exactly where just_audio publishes an implementation', () {
      expect(PlatformPlaybackSupport.hasOnDeviceEngine(HostPlatform.android),
          isTrue);
      expect(
          PlatformPlaybackSupport.hasOnDeviceEngine(HostPlatform.ios), isTrue);
      expect(PlatformPlaybackSupport.hasOnDeviceEngine(HostPlatform.linux),
          isFalse);
      expect(PlatformPlaybackSupport.hasOnDeviceEngine(HostPlatform.macOS),
          isFalse);
      expect(PlatformPlaybackSupport.hasOnDeviceEngine(HostPlatform.windows),
          isFalse);
      expect(PlatformPlaybackSupport.hasOnDeviceEngine(HostPlatform.other),
          isFalse);
    });
  });

  group('localPlaybackControllerProvider', () {
    test('on Android, still builds the just_audio engine', () {
      // The Android regression guard: adding the desktop branch must not have
      // moved Android onto the stub.
      final ProviderContainer container = _containerFor(HostPlatform.android);

      final LocalPlaybackController controller =
          container.read(localPlaybackControllerProvider);

      expect(controller, isA<JustAudioPlaybackController>());
    });

    test('on Linux, builds the explicit unsupported engine', () {
      final ProviderContainer container = _containerFor(HostPlatform.linux);

      final LocalPlaybackController controller =
          container.read(localPlaybackControllerProvider);

      expect(controller, isA<UnsupportedPlaybackController>());
      expect(controller.state.status, PlaybackStatus.idle);
    });

    test('every desktop platform gets the unsupported engine', () {
      for (final HostPlatform host in <HostPlatform>[
        HostPlatform.linux,
        HostPlatform.macOS,
        HostPlatform.windows,
        HostPlatform.other,
      ]) {
        expect(
          _containerFor(host).read(localPlaybackControllerProvider),
          isA<UnsupportedPlaybackController>(),
          reason: '${host.label} has no just_audio implementation',
        );
      }
    });

    test('the Linux engine reports playback as unavailable, not broken',
        () async {
      final ProviderContainer container = _containerFor(HostPlatform.linux);
      final LocalPlaybackController controller =
          container.read(localPlaybackControllerProvider);

      await controller.play();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.errorMessage,
          UnsupportedPlaybackController.defaultReason);
    });
  });

  group('playbackControllerProvider', () {
    test('routes through the same ActivePlaybackController on Linux', () {
      // The UI depends on this provider, never on the engine. It has to build
      // on a platform with no audio engine, otherwise the whole player feature
      // fails to construct at startup.
      final ProviderContainer container = _containerFor(HostPlatform.linux);

      expect(
        () => container.read(playbackControllerProvider),
        returnsNormally,
      );
      expect(container.read(playbackControllerProvider).state.status,
          PlaybackStatus.idle);
    });
  });
}
