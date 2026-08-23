import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/lifecycle/platform_shutdown_policy.dart';
import 'package:linthra/core/platform/host_platform.dart';

void main() {
  group('PlatformShutdownPolicy', () {
    test('desktop hosts shut down when the engine detaches', () {
      expect(
        PlatformShutdownPolicy.shutsDownOnDetached(HostPlatform.linux),
        isTrue,
      );
      expect(
        PlatformShutdownPolicy.shutsDownOnDetached(HostPlatform.macOS),
        isTrue,
      );
      expect(
        PlatformShutdownPolicy.shutsDownOnDetached(HostPlatform.windows),
        isTrue,
      );
    });

    test('mobile hosts do not — a detach there can be a backgrounded app', () {
      expect(
        PlatformShutdownPolicy.shutsDownOnDetached(HostPlatform.android),
        isFalse,
      );
      expect(
        PlatformShutdownPolicy.shutsDownOnDetached(HostPlatform.ios),
        isFalse,
      );
      expect(
        PlatformShutdownPolicy.shutsDownOnDetached(HostPlatform.other),
        isFalse,
      );
    });
  });
}
