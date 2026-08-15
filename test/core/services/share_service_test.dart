import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/android_share_service.dart';
import 'package:linthra/core/services/noop_share_service.dart';
import 'package:linthra/core/services/platform_share_service.dart';
import 'package:linthra/core/services/share_service.dart';

/// A [ShareService] that records the text it was asked to share, so the
/// platform-split delegation can be proven without a real channel.
class _RecordingShareService implements ShareService {
  _RecordingShareService({this.isSupported = true});

  @override
  final bool isSupported;
  String? shared;

  @override
  Future<bool> share(String text) async {
    shared = text;
    return true;
  }
}

void main() {
  group('NoopShareService', () {
    test('is unsupported and never shares', () async {
      const ShareService service = NoopShareService();
      expect(service.isSupported, isFalse);
      expect(await service.share('anything'), isFalse);
    });
  });

  group('AndroidShareService', () {
    test('is a safe no-op off Android (no channel call, returns false)',
        () async {
      // The unit suite runs on the host platform (not Android), so the service
      // must short-circuit before touching the method channel and report the
      // share as not done rather than throwing.
      const ShareService service = AndroidShareService();
      expect(service.isSupported, Platform.isAndroid);
      if (!Platform.isAndroid) {
        expect(await service.share('hello'), isFalse);
      }
    });
  });

  group('PlatformShareService', () {
    test('delegates to the right binding for the host platform', () async {
      final _RecordingShareService android =
          _RecordingShareService(isSupported: true);
      final _RecordingShareService fallback =
          _RecordingShareService(isSupported: false);
      final ShareService service = PlatformShareService(
        androidService: android,
        fallbackService: fallback,
      );

      await service.share('invite');

      if (Platform.isAndroid) {
        expect(android.shared, 'invite');
        expect(fallback.shared, isNull);
        expect(service.isSupported, isTrue);
      } else {
        // Every non-Android host uses the no-op fallback, so the feature is
        // ignored safely and the About page omits the "Share Linthra" row.
        expect(fallback.shared, 'invite');
        expect(android.shared, isNull);
        expect(service.isSupported, isFalse);
      }
    });

    test('on Android, shares through the ACTION_SEND chooser', () async {
      // Injected host, so the Android branch is covered from any machine
      // rather than only when the suite happens to run on a device.
      final _RecordingShareService android =
          _RecordingShareService(isSupported: true);
      final _RecordingShareService fallback =
          _RecordingShareService(isSupported: false);
      final ShareService service = PlatformShareService(
        host: HostPlatform.android,
        androidService: android,
        fallbackService: fallback,
      );

      expect(service.isSupported, isTrue);
      await service.share('invite');
      expect(android.shared, 'invite');
      expect(fallback.shared, isNull);
    });

    test('on Linux, sharing is unsupported and reaches no Android code',
        () async {
      final _RecordingShareService android =
          _RecordingShareService(isSupported: true);
      final _RecordingShareService fallback =
          _RecordingShareService(isSupported: false);
      final ShareService service = PlatformShareService(
        host: HostPlatform.linux,
        androidService: android,
        fallbackService: fallback,
      );

      expect(service.isSupported, isFalse);
      await service.share('invite');
      expect(android.shared, isNull);
      expect(fallback.shared, 'invite');
    });
  });
}
