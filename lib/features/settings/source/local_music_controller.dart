import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/local/android_media_library.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_music_source.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../library/library_controller.dart';
import '../../library/library_providers.dart';
import '../../library/local_scan_report_provider.dart';
import '../../library/selected_folder_controller.dart';

/// Transient state for the Settings ▸ Local music card.
class LocalMusicActionState {
  const LocalMusicActionState({
    this.busy = false,
    this.message,
    this.isError = false,
  });

  final bool busy;
  final String? message;
  final bool isError;
}

/// Drives the Settings ▸ Local music source card.
///
/// Android exposes two deliberate choices:
///  - a targeted SAF folder grant; or
///  - the system-visible Music and audio permission for the device MediaStore.
/// The second path is only requested when the user explicitly chooses it.
class LocalMusicController extends Notifier<LocalMusicActionState> {
  @override
  LocalMusicActionState build() => const LocalMusicActionState();

  Future<void> pickFolder() async {
    state = const LocalMusicActionState(busy: true);
    final String? picked = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndPersist();
    if (picked == null || picked.isEmpty) {
      state = const LocalMusicActionState();
      return;
    }
    await _scan(picked);
  }

  /// Opts into Android's device-wide shared music library.
  ///
  /// This requests only the narrow audio/media permission for the current
  /// Android release. A denial leaves the existing folder/catalog untouched.
  Future<void> useAllDeviceMusic() async {
    if (!ref.read(hostPlatformProvider).isAndroid) return;
    state = const LocalMusicActionState(busy: true);
    final AndroidMusicPermissionStatus status =
        await ref.read(androidMediaLibraryProvider).requestPermission();
    ref.invalidate(androidMusicPermissionStatusProvider);
    ref.invalidate(localFolderAccessProvider);
    if (status != AndroidMusicPermissionStatus.allowed) {
      state = const LocalMusicActionState(
        message: 'Music and audio access was not granted. You can keep using a '
            'selected folder instead.',
        isError: true,
      );
      return;
    }

    await ref
        .read(selectedFolderControllerProvider.notifier)
        .setAndPersist(FolderLocation.androidMediaStoreAudio);
    await _scan(FolderLocation.androidMediaStoreAudio);
  }

  Future<void> refreshAndroidPermissionStatus() async {
    ref.invalidate(androidMusicPermissionStatusProvider);
    ref.invalidate(localFolderAccessProvider);
  }

  Future<void> openAndroidPermissions() async {
    await ref.read(androidMediaLibraryProvider).openAppSettings();
  }

  Future<void> rescan() async {
    final String? folder =
        ref.read(selectedFolderControllerProvider).valueOrNull;
    if (folder == null || folder.isEmpty) {
      return;
    }
    state = const LocalMusicActionState(busy: true);
    await _scan(folder);
  }

  Future<void> forget() async {
    state = const LocalMusicActionState(busy: true);
    await ref.read(selectedFolderControllerProvider.notifier).clear();
    await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
      sourceId: const LocalMusicSource(folderPath: null).id,
      tracks: const [],
      albums: const [],
      artists: const [],
    );
    ref.read(localScanReportProvider.notifier).clear();
    await ref.read(libraryControllerProvider.notifier).refresh();
    state = const LocalMusicActionState(
      message: 'Local music forgotten. Your files were not deleted.',
    );
  }

  Future<void> _scan(String folder) async {
    await ref.read(libraryControllerProvider.notifier).scanFolder(folder);
    final report = ref.read(localScanReportProvider);
    final FolderLocation location = FolderLocation.parse(folder);
    if (report == null) {
      state = const LocalMusicActionState();
      return;
    }
    if (report.hadError) {
      final String message;
      if (location.isAndroidMediaStore) {
        message = report.error == LocalScanError.mediaPermission
            ? 'Could not scan the device music library. Check Music and audio '
                'access in Android settings, or choose a folder instead.'
            : "Couldn't read Android's shared music library. Try again, or "
                'choose a folder instead.';
      } else {
        message = "Couldn't scan that folder. Try selecting it again.";
      }
      state = LocalMusicActionState(message: message, isError: true);
      return;
    }
    if (report.importedTracks > 0) {
      state = LocalMusicActionState(
        message: 'Added ${report.importedTracks} '
            '${report.importedTracks == 1 ? 'track' : 'tracks'} from '
            '${location.isAndroidMediaStore ? 'this device' : 'this folder'}.',
      );
      return;
    }
    final bool looksBlocked = report.readFailures > 0 ||
        (location.isContentUri && report.filesVisited == 0);
    state = LocalMusicActionState(
      message: location.isAndroidMediaStore
          ? 'No music was found in Android MediaStore.'
          : looksBlocked
              ? 'No music found. Linthra may not have access to that folder — '
                  'try selecting it again.'
              : 'No playable audio found in that folder.',
      isError: looksBlocked,
    );
  }
}

final localMusicControllerProvider =
    NotifierProvider<LocalMusicController, LocalMusicActionState>(
  LocalMusicController.new,
);

/// Whether Linthra can still reach the currently selected local-music source.
final localFolderAccessProvider = FutureProvider<bool?>((ref) async {
  final String? folder =
      ref.watch(selectedFolderControllerProvider).valueOrNull;
  ref.watch(localScanReportProvider);
  if (folder == null || folder.isEmpty) {
    return null;
  }

  final FolderLocation location = FolderLocation.parse(folder);
  if (location.isAndroidMediaStore) {
    final AndroidMusicPermissionStatus status =
        await ref.read(androidMediaLibraryProvider).permissionStatus();
    return status == AndroidMusicPermissionStatus.allowed;
  }
  if (location.isContentUri) {
    return ref.read(safPermissionProbeProvider).hasPersistedPermission(folder);
  }
  if (!ref.watch(hostPlatformProvider).isDesktop) {
    return null;
  }
  return ref.read(directoryReadabilityProvider).canList(folder);
});
