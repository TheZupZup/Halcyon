import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/folder_picker_service.dart';
import 'package:linthra/core/services/platform_folder_picker_service.dart';

/// Records which picker was asked and returns a canned answer, so the routing
/// can be asserted without a real OS dialog or platform channel.
class _RecordingPicker implements FolderPickerService {
  _RecordingPicker(this.answer);

  final String? answer;
  int calls = 0;

  @override
  Future<String?> pickFolder() async {
    calls++;
    return answer;
  }
}

void main() {
  group('PlatformFolderPickerService', () {
    test('off Android, delegates to the fallback (file_picker) chooser',
        () async {
      // The unit-test host is never Android, so the SAF picker must not run and
      // the filesystem fallback handles the pick.
      final android = _RecordingPicker('content://should-not-be-used');
      final fallback = _RecordingPicker('/home/me/Music');
      final service = PlatformFolderPickerService(
        androidPicker: android,
        fallbackPicker: fallback,
      );

      final result = await service.pickFolder();

      expect(Platform.isAndroid, isFalse, reason: 'precondition for this host');
      expect(result, '/home/me/Music');
      expect(fallback.calls, 1);
      expect(android.calls, 0);
    });

    test('on Android, delegates to the SAF picker', () async {
      // Asserted with an injected host rather than the real one, so the Android
      // half of the split is covered from any machine — including the Linux CI
      // runner, where it would otherwise be untestable.
      final android = _RecordingPicker('content://tree/primary%3AMusic');
      final fallback = _RecordingPicker('/home/me/Music');
      final service = PlatformFolderPickerService(
        host: HostPlatform.android,
        androidPicker: android,
        fallbackPicker: fallback,
      );

      final result = await service.pickFolder();

      expect(result, 'content://tree/primary%3AMusic');
      expect(android.calls, 1);
      expect(fallback.calls, 0);
    });

    test('on Linux, delegates to the filesystem chooser', () async {
      final android = _RecordingPicker('content://should-not-be-used');
      final fallback = _RecordingPicker('/home/me/Music');
      final service = PlatformFolderPickerService(
        host: HostPlatform.linux,
        androidPicker: android,
        fallbackPicker: fallback,
      );

      expect(await service.pickFolder(), '/home/me/Music');
      expect(android.calls, 0);
      expect(fallback.calls, 1);
    });

    test('an explicit host never disagrees with the real host on this machine',
        () async {
      // Guards the injection itself: passing the actual platform must behave
      // identically to passing nothing.
      final android = _RecordingPicker('content://should-not-be-used');
      final fallback = _RecordingPicker('/home/me/Music');

      expect(
        await PlatformFolderPickerService(
          host: HostPlatform.current,
          androidPicker: android,
          fallbackPicker: fallback,
        ).pickFolder(),
        await PlatformFolderPickerService(
          androidPicker: android,
          fallbackPicker: fallback,
        ).pickFolder(),
      );
    });
  });
}
