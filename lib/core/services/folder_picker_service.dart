/// Opens the platform's native folder chooser so the user can pick a music
/// folder to scan.
///
/// This is the single seam between the app and whatever folder-picking plugin
/// runs underneath. Feature code depends only on this interface, so the UI
/// never imports `file_picker` (or any other plugin) directly and tests can
/// drive the flow with a fake.
abstract interface class FolderPickerService {
  /// Shows the folder chooser and returns the chosen folder's path or URI.
  ///
  /// Returns `null` when the user cancels, or when no picker is available on
  /// the current platform. The returned string is passed through verbatim to
  /// the scan flow; it may be a filesystem path (desktop) or a Storage Access
  /// Framework tree URI (Android).
  Future<String?> pickFolder();
}

/// Thrown by a [FolderPickerService] that could not offer a chooser at all on
/// this build or platform — as opposed to returning `null`, which means the
/// user was shown a chooser and cancelled.
///
/// The distinction matters where one platform has two chooser paths: on Linux
/// the native GTK/portal chooser is the correct one, but it only exists in a
/// build whose runner registered it, so [LinuxFolderPickerService] has to tell
/// "no chooser here, try the plugin" apart from "the user said no" — falling
/// back on a cancel would pop a second dialog in the user's face.
class FolderPickerUnavailableException implements Exception {
  const FolderPickerUnavailableException(this.reason);

  /// Why no chooser was available, for logs. Never shown to the user.
  final String reason;

  @override
  String toString() => 'FolderPickerUnavailableException: $reason';
}
