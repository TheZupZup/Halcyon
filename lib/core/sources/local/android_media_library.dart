import 'saf_document_lister.dart';

/// Android's system-level permission state for reading the shared audio library.
enum AndroidMusicPermissionStatus {
  /// The user has not been prompted by Linthra yet.
  notRequested,

  /// The permission is currently denied or was revoked.
  denied,

  /// Android currently grants Linthra access to the shared audio library.
  allowed,

  /// This platform/build does not expose Android's media-library permission.
  unavailable,
}

/// Android-specific seam for the device-wide MediaStore music library.
///
/// This is deliberately separate from SAF folder access. A user can either
/// grant the normal Android "Music and audio" permission and scan the shared
/// MediaStore library, or keep using the existing targeted folder picker with a
/// persisted SAF grant. Neither path requires MANAGE_EXTERNAL_STORAGE.
abstract interface class AndroidMediaLibrary {
  /// Current Android permission state, without prompting.
  Future<AndroidMusicPermissionStatus> permissionStatus();

  /// Requests the narrow audio/media permission when required by this Android
  /// version and returns the resulting state.
  Future<AndroidMusicPermissionStatus> requestPermission();

  /// Opens Linthra's Android app-details/settings screen when supported.
  Future<void> openAppSettings();

  /// Lists audio rows exposed by Android MediaStore.
  ///
  /// The returned document DTO is shared with the SAF scanner because both
  /// paths ultimately produce content:// URIs plus the same optional metadata.
  Future<SafScanResult> listDeviceAudio();
}

/// Safe non-Android/default binding.
class UnsupportedAndroidMediaLibrary implements AndroidMediaLibrary {
  const UnsupportedAndroidMediaLibrary();

  @override
  Future<AndroidMusicPermissionStatus> permissionStatus() async =>
      AndroidMusicPermissionStatus.unavailable;

  @override
  Future<AndroidMusicPermissionStatus> requestPermission() async =>
      AndroidMusicPermissionStatus.unavailable;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<SafScanResult> listDeviceAudio() async {
    throw const SafUnsupportedException();
  }
}
