/// How a selected local-music location is addressed on the current platform.
///
/// The folder picker normally hands back a single opaque string (see
/// [FolderPickerService]). On desktop that is a real filesystem path; on
/// Android the Storage Access Framework returns a `content://…/tree/…` URI.
/// Android can also use [androidMediaStoreAudio], a Linthra-owned sentinel for
/// the explicit device-wide "Music and audio" / MediaStore mode.
enum FolderLocationKind {
  /// A real filesystem path the `dart:io` scanner can walk directly.
  filesystemPath,

  /// An Android SAF `content://` tree/document URI.
  contentUri,

  /// Android's shared audio library, read through MediaStore after the user
  /// explicitly grants the normal Music and audio runtime permission.
  androidMediaStore,
}

/// A parsed view of a selected local-music location and how to reach it.
class FolderLocation {
  const FolderLocation({required this.kind, required this.raw});

  /// Persisted sentinel for the optional device-wide Android music library.
  /// It is not a filesystem path and never leaves Linthra as an external URI.
  static const String androidMediaStoreAudio = 'mediastore://audio';

  /// Classifies [raw]. The Linthra MediaStore sentinel wins first, then any
  /// `content` URI is a SAF selection; everything else is a filesystem path.
  factory FolderLocation.parse(String raw) {
    if (raw == androidMediaStoreAudio) {
      return const FolderLocation(
        kind: FolderLocationKind.androidMediaStore,
        raw: androidMediaStoreAudio,
      );
    }
    final Uri? uri = Uri.tryParse(raw);
    final bool isContent = uri != null && uri.scheme.toLowerCase() == 'content';
    return FolderLocation(
      kind: isContent
          ? FolderLocationKind.contentUri
          : FolderLocationKind.filesystemPath,
      raw: raw,
    );
  }

  final FolderLocationKind kind;
  final String raw;

  bool get isContentUri => kind == FolderLocationKind.contentUri;
  bool get isFilesystemPath => kind == FolderLocationKind.filesystemPath;
  bool get isAndroidMediaStore => kind == FolderLocationKind.androidMediaStore;

  /// A human-readable label for showing the user their own selection in-app.
  String get displayLabel {
    if (isAndroidMediaStore) {
      return 'All music on this device';
    }
    if (!isContentUri) {
      return raw;
    }
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null) {
      return raw;
    }
    final List<String> segments = uri.pathSegments;
    final int treeIndex = segments.indexOf('tree');
    if (treeIndex >= 0 && treeIndex + 1 < segments.length) {
      // pathSegments are percent-decoded, so this is already e.g.
      // `primary:Music/musi5` rather than `primary%3AMusic%2Fmusi5`.
      return segments[treeIndex + 1];
    }
    return raw;
  }
}
