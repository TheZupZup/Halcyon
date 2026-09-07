import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/local/android_media_library.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../../data/repositories/host_platform_provider.dart';
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
///  - device-wide MediaStore access, backed by READ_MEDIA_AUDIO on Android 13+
///    and the legacy shared-storage read permission on older Android releases.
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
  /// The switch is transactional: the permission is requested, the first
  /// MediaStore scan runs, and only a scan that actually succeeded persists the
  /// MediaStore sentinel. A denial or a failed first scan therefore leaves an
  /// existing folder selection *and* its indexed catalog exactly as they were,
  /// rather than stranding the app in MediaStore mode while it still shows
  /// tracks from a folder it can no longer name.
  Future<void> useAllDeviceMusic() async {
    if (!ref.read(hostPlatformProvider).isAndroid) return;
    state = const LocalMusicActionState(busy: true);
    final AndroidMusicPermissionStatus status =
        await ref.read(androidMediaLibraryProvider).requestPermission();
    ref.invalidate(androidMusicPermissionStatusProvider);
    ref.invalidate(localFolderAccessProvider);
    if (status != AndroidMusicPermissionStatus.allowed) {
      state = const LocalMusicActionState(
        message: 'Device music access was not granted. You can keep using a '
            'selected folder instead.',
        isError: true,
      );
      return;
    }

    // Scan before persisting. `scanFolder` takes the location explicitly, so
    // nothing has to be saved first, and a failure leaves the stored selection
    // untouched: no restore step, and no window where a crash could strand a
    // half-applied switch.
    final LocalScanReport? report =
        await _scan(FolderLocation.androidMediaStoreAudio);
    if (report == null || report.hadError) {
      return;
    }
    await ref
        .read(selectedFolderControllerProvider.notifier)
        .setAndPersist(FolderLocation.androidMediaStoreAudio);
    ref.invalidate(localFolderAccessProvider);
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
    final library = ref.read(libraryControllerProvider.notifier);
    // Invalidate immediately, before the first await. The selection controller
    // also invalidates source changes, and clearLocalCatalog serializes the
    // actual clear after any already-started local catalog write.
    library.invalidatePendingScans();
    state = const LocalMusicActionState(busy: true);
    await ref.read(selectedFolderControllerProvider.notifier).clear();
    await library.clearLocalCatalog();
    state = const LocalMusicActionState(
      message: 'Local music forgotten. Your files were not deleted.',
    );
  }

  /// Scans [folder], turns the resulting report into the card's status line,
  /// and hands the report back so a caller can act on the outcome.
  Future<LocalScanReport?> _scan(String folder) async {
    // Use this operation's result, never the last globally recorded report:
    // a superseded scan must not look successful or persist a source switch.
    final report = await ref
        .read(libraryControllerProvider.notifier)
        .scanFolderWithReport(folder);
    final FolderLocation location = FolderLocation.parse(folder);
    if (report == null) {
      state = const LocalMusicActionState();
      return null;
    }
    if (report.hadError) {
      final String message;
      if (location.isAndroidMediaStore) {
        message = report.error == LocalScanError.mediaPermission
            ? 'Could not scan the device music library. Check device music '
                'access in Android settings, or choose a folder instead.'
            : "Couldn't read Android's shared music library. Try again, or "
                'choose a folder instead.';
      } else {
        message = "Couldn't scan that folder. Try selecting it again.";
      }
      state = LocalMusicActionState(message: message, isError: true);
      return report;
    }
    if (report.importedTracks > 0) {
      state = LocalMusicActionState(
        message: 'Added ${report.importedTracks} '
            '${report.importedTracks == 1 ? 'track' : 'tracks'} from '
            '${location.isAndroidMediaStore ? 'this device' : 'this folder'}.',
      );
      return report;
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
    return report;
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
