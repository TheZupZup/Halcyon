import 'track.dart';

/// A browsable directory exposed by a music provider.
///
/// [id] is opaque and only meaningful to the source that returned it. It must
/// never contain a credential or an authenticated URL.
class MusicFolder {
  const MusicFolder({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MusicFolder && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// The immediate children of one [MusicFolder].
///
/// Folder browsing is intentionally non-recursive: the UI asks for one level at
/// a time, keeping requests small even for very large server libraries.
class MusicFolderListing {
  const MusicFolderListing({
    this.folders = const <MusicFolder>[],
    this.tracks = const <Track>[],
  });

  static const MusicFolderListing empty = MusicFolderListing();

  final List<MusicFolder> folders;
  final List<Track> tracks;

  bool get isEmpty => folders.isEmpty && tracks.isEmpty;
}
