import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_music_source.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../library/library_controller.dart';
import '../../library/library_providers.dart';
import '../../library/local_scan_report_provider.dart';
import '../../library/selected_folder_controller.dart';

/// Transient state for the Settings ▸ Local music card: whether an action is
/// running and the last one-line outcome to surface.
class LocalMusicActionState {
  const LocalMusicActionState({
    this.busy = false,
    this.message,
    this.isError = false,
  });

  /// True while a pick/rescan/forget is in flight (drives the spinner).
  final bool busy;

  /// A short, secret-free outcome line for the card, or null when there's
  /// nothing to say. Never a path or file name.
  final String? message;

  /// Whether [message] reports a failure (rendered in the error colour).
  final bool isError;
}

/// Drives the Settings ▸ Local music source card: choose a folder, rescan it,
/// or forget it. It is the source-shaped peer of the Jellyfin/Subsonic settings
/// controllers, and the configuration home the empty-state "Change folder"
/// button mirrors.
///
/// It owns no scanning logic of its own — it reuses the same pick/scan path the
/// Library screen uses ([SelectedFolderController] + [LibraryController]) so a
/// folder configured here and one configured from the Library behave
/// identically and both refresh the catalog. The selected folder and the last
/// scan counts are read reactively from their own providers by the widget; this
/// controller only carries the in-flight/outcome state and the actions.
class LocalMusicController extends Notifier<LocalMusicActionState> {
  @override
  LocalMusicActionState build() => const LocalMusicActionState();

  /// Opens the folder chooser, persists the choice, and scans it. On Android
  /// this returns a `content://` tree URI with a persisted read grant — the
  /// scoped-storage-correct selection. A cancelled pick leaves everything as it
  /// was.
  Future<void> pickFolder() async {
    state = const LocalMusicActionState(busy: true);
    final String? picked = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndPersist();
    if (picked == null || picked.isEmpty) {
      // Cancelled — say nothing, change nothing.
      state = const LocalMusicActionState();
      return;
    }
    await _scan(picked);
  }

  /// Re-scans the folder already selected, without opening the chooser. No-op
  /// when nothing is selected yet.
  Future<void> rescan() async {
    final String? folder =
        ref.read(selectedFolderControllerProvider).valueOrNull;
    if (folder == null || folder.isEmpty) {
      return;
    }
    state = const LocalMusicActionState(busy: true);
    await _scan(folder);
  }

  /// Forgets the selected folder and removes the local tracks from the catalog.
  /// Deletes nothing on disk — it only clears Linthra's index for the `local`
  /// source, so re-selecting the folder brings everything back.
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
      message: 'Local folder forgotten. Your files were not deleted.',
    );
  }

  /// Runs the shared scan-and-persist path, then summarizes the outcome from the
  /// recorded scan report (counts only — never a path or file name).
  Future<void> _scan(String folder) async {
    await ref.read(libraryControllerProvider.notifier).scanFolder(folder);
    final report = ref.read(localScanReportProvider);
    final bool isContentUri = FolderLocation.parse(folder).isContentUri;
    if (report == null) {
      state = const LocalMusicActionState();
      return;
    }
    if (report.hadError) {
      state = const LocalMusicActionState(
        message: "Couldn't scan that folder. Try selecting it again.",
        isError: true,
      );
      return;
    }
    if (report.importedTracks > 0) {
      state = LocalMusicActionState(
        message: 'Added ${report.importedTracks} '
            '${report.importedTracks == 1 ? 'track' : 'tracks'} from this '
            'folder.',
      );
      return;
    }
    // Completed, but nothing playable. Distinguish a likely access problem from
    // a genuinely empty folder so the message is actionable.
    final bool looksBlocked =
        report.readFailures > 0 || (isContentUri && report.filesVisited == 0);
    state = LocalMusicActionState(
      message: looksBlocked
          ? 'No music found. Linthra may not have access to that folder — try '
              'selecting it again.'
          : 'No playable audio found in that folder.',
      isError: looksBlocked,
    );
  }
}

final localMusicControllerProvider =
    NotifierProvider<LocalMusicController, LocalMusicActionState>(
  LocalMusicController.new,
);

/// Whether Linthra can still reach the selected folder — the lost-access
/// signal shown on the Local music card. Re-evaluated whenever the selection
/// changes.
///
/// Two storage kinds, one question:
///  - an Android `content://` tree: does the app still hold the persisted SAF
///    read grant (the removable-SD-card / revoked-permission case)?
///  - a desktop filesystem path: can the folder still be listed? On a Flatpak
///    that is the portal document exported for the folder the user chose;
///    revoking it (or unplugging the drive, or deleting the folder) makes the
///    path stop resolving, which is the same recoverable "select it again"
///    state rather than an empty library (#438).
///
/// Returns `null` when it doesn't apply (no folder) or can't be determined (a
/// filesystem path on a platform without a desktop chooser), so the card simply
/// omits the line.
final localFolderAccessProvider = FutureProvider<bool?>((ref) async {
  final String? folder =
      ref.watch(selectedFolderControllerProvider).valueOrNull;
  // Re-probed on every recorded scan, not only when the *selection* changes.
  // Access is lost while the app is running — a drive unplugged, a portal
  // document revoked, a folder deleted — and the selection does not change when
  // it happens, so a cached "yes" would outlive the truth and leave both cards
  // showing a healthy folder right after a rescan failed on it. Every scan path
  // (this card and the Library empty state) records through this provider, so
  // watching it is what makes a rescan the natural way to re-check.
  ref.watch(localScanReportProvider);
  if (folder == null || folder.isEmpty) {
    return null;
  }
  if (FolderLocation.parse(folder).isContentUri) {
    return ref.read(safPermissionProbeProvider).hasPersistedPermission(folder);
  }
  // Desktop only: on Android a filesystem path is a legacy selection whose
  // access story is scoped storage's, not this probe's, so it keeps reporting
  // "can't tell" exactly as before.
  if (!ref.watch(hostPlatformProvider).isDesktop) {
    return null;
  }
  return ref.read(directoryReadabilityProvider).canList(folder);
});
