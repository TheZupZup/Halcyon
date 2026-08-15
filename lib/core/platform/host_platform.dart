import 'dart:io' show Platform;

/// The operating system Linthra is running on, as far as platform *selection*
/// is concerned.
///
/// Linthra has always chosen its platform implementations with `Platform.isX`
/// read straight from `dart:io`. That works in the app and is untestable off the
/// host OS: a unit test running on Linux can assert that the desktop branch was
/// taken, but it can never assert that Android still picks the Android one —
/// exactly the regression that would go unnoticed once a second platform
/// exists.
///
/// [HostPlatform] is the same decision expressed as a value, so the selection
/// rule can be exercised for *both* platforms on one machine. Production code
/// keeps using [HostPlatform.current], which reads `dart:io` once at startup and
/// is unchanged behaviour; tests pass [HostPlatform.android] or
/// [HostPlatform.linux] directly.
///
/// This is deliberately a small, closed enum rather than a wrapper around every
/// `Platform` member: it exists to answer "which implementation should I build",
/// not to abstract the OS.
enum HostPlatform {
  android,
  ios,
  linux,
  macOS,
  windows,

  /// Anything else `dart:io` reports (fuchsia, or a future value). Treated as a
  /// non-Android, non-desktop platform: every seam falls back to its safest
  /// implementation.
  other;

  /// The platform this process is actually running on.
  ///
  /// Read from `dart:io` once, at first use. `Platform.operatingSystem` is a
  /// build-time constant on every target Linthra ships, so this is a cheap
  /// lookup, not a syscall per call site.
  static final HostPlatform current = fromOperatingSystem(
    Platform.operatingSystem,
  );

  /// Maps a `Platform.operatingSystem` string onto a [HostPlatform].
  ///
  /// Exposed so the mapping itself is unit-testable without spoofing the host
  /// OS, and so a future embedder string can be handled explicitly rather than
  /// silently landing in the wrong branch.
  static HostPlatform fromOperatingSystem(String operatingSystem) {
    switch (operatingSystem) {
      case 'android':
        return HostPlatform.android;
      case 'ios':
        return HostPlatform.ios;
      case 'linux':
        return HostPlatform.linux;
      case 'macos':
        return HostPlatform.macOS;
      case 'windows':
        return HostPlatform.windows;
      default:
        return HostPlatform.other;
    }
  }

  /// Whether this is Android — the platform that owns SAF, the media
  /// notification, Android Auto, and the native MethodChannels.
  bool get isAndroid => this == HostPlatform.android;

  /// Whether this is a desktop platform (Linux today; macOS and Windows are not
  /// targets yet but must not be misread as mobile if someone builds them).
  bool get isDesktop =>
      this == HostPlatform.linux ||
      this == HostPlatform.macOS ||
      this == HostPlatform.windows;

  /// A stable, secret-free label for diagnostics and logs.
  String get label {
    switch (this) {
      case HostPlatform.android:
        return 'android';
      case HostPlatform.ios:
        return 'ios';
      case HostPlatform.linux:
        return 'linux';
      case HostPlatform.macOS:
        return 'macos';
      case HostPlatform.windows:
        return 'windows';
      case HostPlatform.other:
        return 'other';
    }
  }
}
