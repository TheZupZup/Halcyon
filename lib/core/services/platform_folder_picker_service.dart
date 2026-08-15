import '../platform/host_platform.dart';
import 'file_picker_folder_picker_service.dart';
import 'folder_picker_service.dart';
import 'method_channel_saf_folder_picker.dart';

/// The default [FolderPickerService]: routes folder selection to the chooser
/// that returns a usable handle on each platform.
///
/// On Android it uses [MethodChannelSafFolderPicker], which returns the picked
/// `content://` tree URI with a persisted read grant — the scoped-storage-
/// correct selection. Everywhere else (desktop, where the chooser returns a real
/// filesystem path) it uses the `file_picker`-backed
/// [FilePickerFolderPickerService]. This is the one place that knows about the
/// platform split, mirroring [PlatformAudioFileScanner] on the scan side.
class PlatformFolderPickerService implements FolderPickerService {
  const PlatformFolderPickerService({
    HostPlatform? host,
    FolderPickerService androidPicker = const MethodChannelSafFolderPicker(),
    FolderPickerService fallbackPicker = const FilePickerFolderPickerService(),
  })  : _host = host,
        _androidPicker = androidPicker,
        _fallbackPicker = fallbackPicker;

  /// The platform to route for. Null means "ask the real host", which is what
  /// the app always does; tests pass a value so both branches are reachable
  /// from one machine.
  final HostPlatform? _host;
  final FolderPickerService _androidPicker;
  final FolderPickerService _fallbackPicker;

  @override
  Future<String?> pickFolder() {
    if ((_host ?? HostPlatform.current).isAndroid) {
      return _androidPicker.pickFolder();
    }
    return _fallbackPicker.pickFolder();
  }
}
