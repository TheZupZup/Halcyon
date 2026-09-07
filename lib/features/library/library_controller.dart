import 'dart:async';

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
  int _scanGeneration = 0;
  int _loadGeneration = 0;
  Future<void> _localMutationTail = Future<void>.value();

  @override
  LibraryState build() {
    _load();
    return const LibraryState.loading();
  }

  /// Reloading the shared catalog must not cancel an unrelated local scan.
  Future<void> refresh() => _load();

  /// Supersedes pending local scans when the user changes or forgets a source.
  /// Call this before the first asynchronous part of the source mutation.
  ///
  /// Bumping the generations makes an in-flight scan's result unusable, but on
  /// Android it does not stop the native SAF walk producing it: that keeps
  /// opening a metadata retriever and extracting artwork for the rest of an
  /// abandoned library, competing for content-resolver I/O with whatever the
  /// user switched to. Starting another scan already supersedes the walk ahead
  /// of it; forgetting the folder or switching to the device-wide library does
  /// not start one, so ask the scanner to stop directly.
  ///
  /// Deliberately not awaited: this must stay synchronous so callers can
  /// invalidate before their first `await`, and cancellation is best-effort on
  /// every platform. The generation guard remains the thing that makes the
  /// result safe; this only saves the work.
  void invalidatePendingScans() {
    _scanGeneration++;
    _loadGeneration++;
    unawaited(ref.read(safDocumentListerProvider).cancelScan());
  }

  /// Waits for already-started local writes before persisting a source change.
  /// Invalidation happens first, so pending walks cannot enqueue a new write.
  Future<void> waitForLocalMutations() => _localMutationTail;

  /// Serializes local catalog writes, including forget. A scan may finish its
  /// walk while a previous write is pending; its generation is checked again
  /// inside this queue so obsolete results cannot commit after a clear.
  Future<T> _serializeLocalMutation<T>(Future<T> Function() operation) {
    final Future<T> result = _localMutationTail.then((_) => operation());
    _localMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Clears only the local source, after any already-started local write.
  /// A new scan started after this action can still populate the catalog.
  Future<void> clearLocalCatalog() {
    invalidatePendingScans();
    return _serializeLocalMutation(() async {
      await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
        sourceId: const LocalMusicSource(folderPath: null).id,
        tracks: const [],
        albums: const [],
        artists: const [],
      );
      ref.read(localScanReportProvider.notifier).clear();
      await _load();
    });
  }

  /// Scans a filesystem folder, SAF tree, or Android device-wide MediaStore
  /// selection, persists the discovered tracks, then reloads the catalog.
  /// Kept as a void-returning API for existing Library screen callers.
  Future<void> scanFolder(String folderPath) async {
    await scanFolderWithReport(folderPath);
  }

  /// Returns this operation's report, or null if it was superseded. Callers
  /// must not infer success from the last globally recorded scan report.
  Future<LocalScanReport?> scanFolderWithReport(String folderPath) async {
    final int generation = ++_scanGeneration;
    _loadGeneration++;
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
      if (generation != _scanGeneration) return null;

      return await _serializeLocalMutation<LocalScanReport?>(() async {
        // Check at commit time, not merely when the filesystem walk finishes.
        if (generation != _scanGeneration) return null;
        final repository = ref.read(musicLibraryRepositoryProvider);
        await repository.upsertCatalog(
          sourceId: source.id,
          tracks: scan.tracks,
          albums: groupAlbums(scan.tracks),
          artists: groupArtists(scan.tracks),
        );
        // A newer action may have started while the write was awaiting I/O.
        // Its queued write will run after this one; do not publish stale status.
        if (generation != _scanGeneration) return null;
        ref.read(localScanReportProvider.notifier).record(scan.report);
        await _load();
        return generation == _scanGeneration ? scan.report : null;
      });
    } on FolderScanException catch (error) {
      if (generation != _scanGeneration) return null;
      final report = LocalScanReport.failure(
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
      );
      ref.read(localScanReportProvider.notifier).record(report);
      _loadGeneration++;
      state = LibraryState.error(error.message);
      return report;
    } catch (_) {
      if (generation != _scanGeneration) return null;
      final report = LocalScanReport.failure(
        folderSelected: folderPath.isNotEmpty,
        isContentUri: location.isContentUri,
        isDeviceLibrary: location.isAndroidMediaStore,
        error: LocalScanError.unexpected,
      );
      ref.read(localScanReportProvider.notifier).record(report);
      _loadGeneration++;
      state = const LibraryState.error(_scanFailedMessage);
      return report;
    }
  }

  static const String _scanFailedMessage =
      "Couldn't scan that folder. Try selecting it again, or pick a different "
      'folder.';

  static const String _loadFailedMessage =
      "Couldn't open your music library. Try again, or rescan your music "
      'folder.';

  Future<void> _load() async {
    final int generation = ++_loadGeneration;
    state = const LibraryState.loading();
    try {
      final tracks =
          await ref.read(musicLibraryRepositoryProvider).getAllTracks();
      if (generation == _loadGeneration) {
        state = LibraryState.loaded(tracks);
      }
    } catch (_) {
      if (generation == _loadGeneration) {
        state = const LibraryState.error(_loadFailedMessage);
      }
    }
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
