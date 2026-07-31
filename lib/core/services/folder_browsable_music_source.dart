import '../models/music_folder.dart';

/// Optional capability implemented by providers that expose their server-side
/// directory hierarchy.
///
/// It is deliberately separate from `MusicSource`: local files, Plex, and any
/// future provider can keep implementing the ordinary catalog contract without
/// being forced to invent folder semantics they do not support.
abstract interface class FolderBrowsableMusicSource {
  /// Stable provider id, e.g. `jellyfin` or `subsonic`.
  String get id;

  /// Friendly source label shown above its root folders.
  String get displayName;

  /// Top-level music libraries/folders available to the signed-in user.
  Future<List<MusicFolder>> fetchRootFolders();

  /// The direct child folders and tracks of [folderId].
  Future<MusicFolderListing> fetchFolder(String folderId);
}
