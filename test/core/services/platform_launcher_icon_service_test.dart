import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/launcher_icon_service.dart';
import 'package:linthra/core/services/noop_launcher_icon_service.dart';
import 'package:linthra/core/services/platform_launcher_icon_service.dart';

/// Records the variant it was asked to apply, so the platform split can be
/// asserted without touching the real `<activity-alias>` toggle.
class _RecordingLauncherIconService implements LauncherIconService {
  _RecordingLauncherIconService({required this.isSupported});

  @override
  final bool isSupported;
  String? applied;

  @override
  Future<bool> applyVariant(String variantId) async {
    applied = variantId;
    return true;
  }
}

void main() {
  group('PlatformLauncherIconService', () {
    test('on Android, switches the real launcher alias', () async {
      final android = _RecordingLauncherIconService(isSupported: true);
      final fallback = _RecordingLauncherIconService(isSupported: false);
      final service = PlatformLauncherIconService(
        host: HostPlatform.android,
        androidService: android,
        fallbackService: fallback,
      );

      expect(service.isSupported, isTrue);
      await service.applyVariant('classic');
      expect(android.applied, 'classic');
      expect(fallback.applied, isNull);
    });

    test('on Linux, there is no launcher alias to switch', () async {
      // The in-app branding choice still applies; only the desktop launcher
      // entry is out of scope, and it must not reach the Android channel.
      final android = _RecordingLauncherIconService(isSupported: true);
      final fallback = _RecordingLauncherIconService(isSupported: false);
      final service = PlatformLauncherIconService(
        host: HostPlatform.linux,
        androidService: android,
        fallbackService: fallback,
      );

      expect(service.isSupported, isFalse);
      await service.applyVariant('classic');
      expect(android.applied, isNull);
      expect(fallback.applied, 'classic');
    });

    test('the production default is inert on this (non-Android) host', () {
      const service = PlatformLauncherIconService();

      expect(service.isSupported, isFalse);
      expect(const NoopLauncherIconService().isSupported, isFalse);
    });
  });
}
