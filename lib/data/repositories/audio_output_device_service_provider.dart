import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/audio_output_device_service.dart';
import '../../core/services/noop_audio_output_device_service.dart';
import '../../core/services/platform_audio_output_device_service.dart';

/// The single seam the app lists and chooses audio outputs through.
///
/// Defaults to the no-op implementation so unit and widget tests never load
/// libmpv. The running app overrides this with
/// [platformAudioOutputDeviceServiceOverride], which gives Linux the real
/// media_kit-backed routing and leaves every other platform on the no-op.
/// Mirrors the [shareServiceProvider] seam.
final audioOutputDeviceServiceProvider = Provider<AudioOutputDeviceService>(
  (ref) => const NoopAudioOutputDeviceService(),
);

/// Production binding: real output routing on Linux, a safe no-op elsewhere.
/// Applied in `main`.
final platformAudioOutputDeviceServiceOverride =
    audioOutputDeviceServiceProvider.overrideWithValue(
  PlatformAudioOutputDeviceService(),
);
