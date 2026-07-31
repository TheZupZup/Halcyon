import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/music_folder.dart';
import '../../core/services/folder_browsable_music_source.dart';
import '../../core/sources/jellyfin/jellyfin_folder_browser_source.dart';
import '../../core/sources/subsonic/subsonic_folder_browser_source.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';

/// Live Jellyfin folder browser, present only while a session is connected.
final jellyfinFolderBrowserSourceProvider =
    Provider<JellyfinFolderBrowserSource?>((ref) {
  final bool connected = ref.watch(
    jellyfinSettingsControllerProvider.select((state) => state.isConnected),
  );
  if (!connected) return null;
  final session =
      ref.read(jellyfinSettingsControllerProvider.notifier).session;
  if (session == null) return null;
  final JellyfinFolderBrowserSource source =
      JellyfinFolderBrowserSource(session: session);
  ref.onDispose(source.close);
  return source;
});

/// Live Navidrome/Subsonic folder browser, present only while connected.
final subsonicFolderBrowserSourceProvider =
    Provider<SubsonicFolderBrowserSource?>((ref) {
  final bool connected = ref.watch(
    subsonicSettingsControllerProvider.select((state) => state.isConnected),
  );
  if (!connected) return null;
  final session =
      ref.read(subsonicSettingsControllerProvider.notifier).session;
  if (session == null) return null;
  final SubsonicFolderBrowserSource source =
      SubsonicFolderBrowserSource(session: session);
  ref.onDispose(source.close);
  return source;
});

/// Every currently connected source that can expose a directory hierarchy.
final folderBrowsableSourcesProvider =
    Provider<List<FolderBrowsableMusicSource>>((ref) {
  final JellyfinFolderBrowserSource? jellyfin =
      ref.watch(jellyfinFolderBrowserSourceProvider);
  final SubsonicFolderBrowserSource? subsonic =
      ref.watch(subsonicFolderBrowserSourceProvider);
  return <FolderBrowsableMusicSource>[
    if (jellyfin != null) jellyfin,
    if (subsonic != null) subsonic,
  ];
});

/// Loads the top-level folders for one connected provider.
final folderRootFoldersProvider = FutureProvider.autoDispose
    .family<List<MusicFolder>, String>((ref, sourceId) async {
  return _source(ref, sourceId).fetchRootFolders();
});

/// Identifies one directory request without exposing provider credentials.
class FolderBrowseRequest {
  const FolderBrowseRequest({
    required this.sourceId,
    required this.folderId,
  });

  final String sourceId;
  final String folderId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderBrowseRequest &&
          other.sourceId == sourceId &&
          other.folderId == folderId;

  @override
  int get hashCode => Object.hash(sourceId, folderId);
}

/// Loads exactly one level of a provider's directory hierarchy.
final folderListingProvider = FutureProvider.autoDispose
    .family<MusicFolderListing, FolderBrowseRequest>((ref, request) async {
  return _source(ref, request.sourceId).fetchFolder(request.folderId);
});

FolderBrowsableMusicSource _source(Ref ref, String sourceId) {
  final List<FolderBrowsableMusicSource> sources =
      ref.watch(folderBrowsableSourcesProvider);
  for (final FolderBrowsableMusicSource source in sources) {
    if (source.id == sourceId) return source;
  }
  throw StateError('The selected music source is no longer connected.');
}
