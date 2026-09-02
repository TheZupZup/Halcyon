import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/folder_picker_service.dart';
import 'package:linthra/core/services/linux_folder_picker_service.dart';

/// Answers with a canned result, so the routing between the two Linux choosers
/// can be asserted without a real dialog.
class _StubPicker implements FolderPickerService {
  _StubPicker.answers(this.answer) : error = null;
  _StubPicker.throws(this.error) : answer = null;

  final String? answer;
  final Object? error;
  int calls = 0;

  @override
  Future<String?> pickFolder() async {
    calls++;
    if (error != null) {
      throw error!;
    }
    return answer;
  }
}

void main() {
  group('LinuxFolderPickerService', () {
    test('uses the runner GTK/portal chooser when it is there', () async {
      final native = _StubPicker.answers('/home/me/Music');
      final fallback = _StubPicker.answers('/should/not/be/used');

      final result = await LinuxFolderPickerService(
        nativePicker: native,
        fallbackPicker: fallback,
      ).pickFolder();

      expect(result, '/home/me/Music');
      expect(native.calls, 1);
      expect(fallback.calls, 0);
    });

    test('a cancelled native pick is a cancel, not a reason to fall back',
        () async {
      // Falling back here would pop a second dialog in the face of a user who
      // just dismissed the first one.
      final native = _StubPicker.answers(null);
      final fallback = _StubPicker.answers('/home/me/Music');

      final result = await LinuxFolderPickerService(
        nativePicker: native,
        fallbackPicker: fallback,
      ).pickFolder();

      expect(result, isNull);
      expect(fallback.calls, 0);
    });

    test('falls back to the plugin chooser when no native chooser exists',
        () async {
      // A build whose runner never registered the channel (a test host, an
      // older native build) must still be able to pick a folder.
      final native = _StubPicker.throws(
        const FolderPickerUnavailableException('no channel'),
      );
      final fallback = _StubPicker.answers('/home/me/Music');

      final result = await LinuxFolderPickerService(
        nativePicker: native,
        fallbackPicker: fallback,
      ).pickFolder();

      expect(result, '/home/me/Music');
      expect(fallback.calls, 1);
    });

    test('reports no selection when the fallback chooser cannot run either',
        () async {
      // `file_picker` throws when it finds no zenity/qarma/kdialog to shell out
      // to — the sandbox case. There is no chooser left to try, so this is
      // "nothing chosen" rather than a raw exception thrown into the UI.
      final native = _StubPicker.throws(
        const FolderPickerUnavailableException('no channel'),
      );
      final fallback = _StubPicker.throws(
        Exception("Couldn't find the executable zenity in your path"),
      );

      final result = await LinuxFolderPickerService(
        nativePicker: native,
        fallbackPicker: fallback,
      ).pickFolder();

      expect(result, isNull);
    });
  });
}
