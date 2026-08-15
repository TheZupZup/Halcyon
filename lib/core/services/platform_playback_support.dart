import '../platform/host_platform.dart';

/// Which platforms have an on-device audio engine Linthra can drive.
///
/// One named rule instead of a `Platform.isAndroid` sprinkled through the
/// provider graph, so "does this build have audio?" has exactly one answer that
/// both the app and the tests read.
///
/// The rule follows the engine, not the product plan: `just_audio` — the package
/// `JustAudioPlaybackController` wraps — publishes Android and iOS
/// implementations and no Linux one. Desktop therefore gets
/// `UnsupportedPlaybackController` until a real desktop backend is wired in,
/// which is the next piece of Linux work.
abstract final class PlatformPlaybackSupport {
  /// Whether `just_audio` can actually play audio on [host].
  static bool hasOnDeviceEngine(HostPlatform host) =>
      host == HostPlatform.android || host == HostPlatform.ios;
}
