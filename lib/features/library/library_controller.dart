import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/library_grouping.dart';
import '../../core/sources/local/folder_location.dart';
import '../../core/sources/local/folder_scan_exception.dart';
import '../../core/sources/local/local_music_source.dart';
import '../../core/sources/local/local_scan_report.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import 'library_providers.dart';
import 'library_state.dart';
import 'local_scan_report_provider.dart';

/// Drives the Library screen: loads tracks from the [MusicLibraryRepository]
/// and exposes them as a [LibraryState].
class LibraryController extends Notifier<LibraryState> {
  @override
  LibraryState build() {
    _load();
    return const LibraryState.loading();
  }

  Future<void> refresh() => _load();

  /// Scans a filesystem folder, SAF tree, or Android device-wide MediaStore
  /// selection, persists the discovered tracks, then reloads the catalog.
  Future<void> scanFolder(String folderPath) async {
    state = const LibraryState.loading();
    final FolderLocation location = FolderLocation.parse(folderPath);
    try {
      final source = LocalMusicSource(
        folderPath: folderPath,
        scanner: ref.read(audioFileScannerProvider),
        safDocumentLister: ref.read(safDocumentListerProvider),
        androidMediaLibrary: ref.read(androidMediaLibraryProvider),
        metadataReader: ref.read(localMetadataReaderProvider),
      );
      final LocalScan scan = await source.scanTracks();
      final repository = ref.read(musicLibraryRepositoryProvider);
      await repository.upsertCatalog(
        sourceId: source.id,
        tracks: scan.tracks,
        albums: groupAlbums(scan.tracks),
        artists: groupArtists(scan.tracks),
      );
      ref.read(localScanReportProvider.notifier).record(scan.report);
      await _load();
    } on FolderScanException catch (error) {
      ref.read(localScanReportProvider.notifier).record(
            LocalScanReport.failure(
              folderSelected: folderPath.isNotEmpty,
              isContentUri: location.isContentUri,
              isDeviceLibrary: location.isAndroidMediaStore,
              error: location.isAndroidMediaStore
                  ? error.code == 'permission_denied'
                      ? LocalScanError.mediaPermission
                      : LocalScanError.unexpected
                  : location.isContentUri
                      ? LocalScanError.safTraversal
                      : LocalScanError.folderUnavailable,
            ),
          );
      state = LibraryState.error(error.message);
    } catch (_) {
      ref.read(localScanReportProvider.notifier).record(
            LocalScanReport.failure(
              folderSelected: folderPath.isNotEmpty,
              isContentUri: location.isContentUri,
              isDeviceLibrary: location.isAndroidMediaStore,
              error: LocalScanError.unexpected,
            ),
          );
      state = const LibraryState.error(_scanFailedMessage);
    }
  }

  static const String _scanFailedMessage =
      "Couldn't scan that folder. Try selecting it again, or pick a different "
      'folder.';

  static const String _loadFailedMessage =
      "Couldn't open your music library. Try again, or rescan your music "
      'folder.';

  Future<void> _load() async {
    state = const LibraryState.loading();
    try {
      final tracks =
          await ref.read(musicLibraryRepositoryProvider).getAllTracks();
      state = LibraryState.loaded(tracks);
    } catch (_) {
      state = const LibraryState.error(_loadFailedMessage);
    }
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
