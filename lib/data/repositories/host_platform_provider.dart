import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/host_platform.dart';

/// The platform the app believes it is running on, for every provider that has
/// to choose a platform-specific implementation.
///
/// Defaults to the real host, so the running app behaves exactly as it did when
/// each of those providers read `Platform.isAndroid` itself. Its reason for
/// existing is the other direction: a test can override it and assert that the
/// Android bindings are still chosen on Android and that a desktop build gets
/// the desktop ones — on a single machine, without the assertion quietly
/// becoming "whatever this CI runner happens to be".
final hostPlatformProvider = Provider<HostPlatform>((ref) {
  return HostPlatform.current;
});
