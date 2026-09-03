import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/folder_picker_service.dart';
import '../../core/services/platform_folder_picker_service.dart';
import '../../core/sources/local/android_media_library.dart';
import '../../core/sources/local/audio_file_scanner.dart';
import '../../core/sources/local/directory_readability.dart';
import '../../core/sources/local/local_metadata_reader.dart';
import '../../core/sources/local/method_channel_android_media_library.dart';
import '../../core/sources/local/method_channel_saf_document_lister.dart';
import '../../core/sources/local/method_channel_saf_permission_probe.dart';
import '../../core/sources/local/saf_document_lister.dart';
import '../../core/sources/local/saf_permission_probe.dart';
import '../../data/repositories/host_platform_provider.dart';

/// The storage seam the library scan uses to discover audio files.
final audioFileScannerProvider = Provider<AudioFileScanner>((ref) {
  return const PlatformAudioFileScanner();
});

/// The folder-chooser seam the Library uses to let the user pick a music
/// folder. Android returns a persisted SAF tree URI; desktop uses its native
/// chooser/portal.
final folderPickerServiceProvider = Provider<FolderPickerService>((ref) {
  return const PlatformFolderPickerService();
});

/// The SAF traversal seam used to scan an Android `content://` folder through
/// the content resolver.
final safDocumentListerProvider = Provider<SafDocumentLister>((ref) {
  return ref.watch(hostPlatformProvider).isAndroid
      ? const MethodChannelSafDocumentLister()
      : const UnsupportedSafDocumentLister();
});

/// Optional Android device-wide local library. This is intentionally distinct
/// from SAF: it is backed by Android's visible/revocable Music and audio
/// permission plus MediaStore, while the existing folder mode remains a narrow
/// persisted grant with no broad storage permission.
final androidMediaLibraryProvider = Provider<AndroidMediaLibrary>((ref) {
  return ref.watch(hostPlatformProvider).isAndroid
      ? const MethodChannelAndroidMediaLibrary()
      : const UnsupportedAndroidMediaLibrary();
});

/// Reactive permission state shown in Settings ▸ Local music. Auto-dispose means
/// leaving and reopening the screen asks Android again rather than keeping stale
/// permission state forever; actions also invalidate it after a request.
final androidMusicPermissionStatusProvider =
    FutureProvider.autoDispose<AndroidMusicPermissionStatus>((ref) {
  return ref.watch(androidMediaLibraryProvider).permissionStatus();
});

/// The seam diagnostics use to check whether a persisted SAF read grant is still
/// held for the selected `content://` folder.
final safPermissionProbeProvider = Provider<SafPermissionProbe>((ref) {
  return ref.watch(hostPlatformProvider).isAndroid
      ? const MethodChannelSafPermissionProbe()
      : const UnsupportedSafPermissionProbe();
});

/// The seam that answers whether a filesystem music folder can still be listed.
final directoryReadabilityProvider = Provider<DirectoryReadability>((ref) {
  return const IoDirectoryReadability();
});

/// The tag-reading seam used to enrich filesystem (desktop/Linux and
/// resolved-path) tracks with their audio metadata.
final localMetadataReaderProvider = Provider<LocalMetadataReader>((ref) {
  return const UnsupportedLocalMetadataReader();
});
