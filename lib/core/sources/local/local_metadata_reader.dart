import 'local_audio_metadata.dart';

/// Reads audio tags from an on-device file *path* (the desktop/Linux and
/// resolved-path case), the filesystem counterpart of the SAF metadata the
/// native content-resolver walk returns.
///
/// This is a seam, deliberately mirroring [SafDocumentLister]: the source
/// depends on this interface, never on a concrete reader, so tag reading can
/// change without touching the scanner, source, or mapper, which is exactly
/// how the real reader arrived (#407) without a caller moving.
///
/// Which implementation runs is `localMetadataReaderProvider`'s decision:
/// `FilesystemLocalMetadataReader` on desktop/Linux, and
/// [UnsupportedLocalMetadataReader] on Android, whose tags already come from
/// the native SAF walk.
abstract interface class LocalMetadataReader {
  /// Returns the tags for the file at [path], or null when none could be read
  /// (unsupported here, an unreadable file, or a format without tags). Must
  /// never throw: an unreadable file is a null result, not a failed scan.
  Future<LocalAudioMetadata?> readFromPath(String path);
}

/// The [LocalMetadataReader] for anywhere a filesystem tag read is not wanted:
/// Android, whose tags come from the native SAF walk, and tests. It reads
/// nothing, so the mapper falls back to filename/folder metadata.
class UnsupportedLocalMetadataReader implements LocalMetadataReader {
  const UnsupportedLocalMetadataReader();

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async => null;
}
