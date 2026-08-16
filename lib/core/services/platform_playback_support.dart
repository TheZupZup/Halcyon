import '../platform/host_platform.dart';

/// Which platforms have an on-device audio engine Linthra can drive.
///
/// One named rule instead of a `Platform.isAndroid` sprinkled through the
/// provider graph, so "does this build have audio?" has exactly one answer that
/// both the app and the tests read.
///
/// The rule follows the available engines, not the product plan: Android/iOS
/// use just_audio's native implementations and Linux uses the media_kit/libmpv
/// federated implementation. Other desktop platforms remain unsupported.
abstract final class PlatformPlaybackSupport {
  /// Whether Linthra can actually play on-device audio on [host].
  static bool hasOnDeviceEngine(HostPlatform host) =>
      host == HostPlatform.android ||
      host == HostPlatform.ios ||
      host == HostPlatform.linux;
}
