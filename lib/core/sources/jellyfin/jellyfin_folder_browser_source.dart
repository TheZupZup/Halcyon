import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/jellyfin_session.dart';
import '../../models/music_folder.dart';
import '../../services/folder_browsable_music_source.dart';
import 'jellyfin_api.dart';
import 'jellyfin_auth_header.dart';
import 'jellyfin_exception.dart';
import 'jellyfin_track_mapper.dart';

/// Folder-hierarchy browsing for a signed-in Jellyfin server.
///
/// This is kept separate from the normal full-catalog sync. Each tap loads one
/// directory level through Jellyfin's media-folder and child-item APIs, so a
/// user can browse a carefully organised tree without recursively downloading
/// its complete shape first.
class JellyfinFolderBrowserSource implements FolderBrowsableMusicSource {
  JellyfinFolderBrowserSource({
    required this.session,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final JellyfinSession session;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  @override
  String get id => 'jellyfin';

  @override
  String get displayName {
    final String? name = session.serverName;
    return name == null || name.isEmpty ? 'Jellyfin' : 'Jellyfin · $name';
  }

  @override
  Future<List<MusicFolder>> fetchRootFolders() async {
    final Uri uri = Uri.parse('${session.baseUrl}/Library/MediaFolders').replace(
      queryParameters: const <String, String>{'IsHidden': 'false'},
    );
    final Map<String, dynamic> body = await _getObject(uri);
    final Object? rawItems = body['Items'];
    if (rawItems is! List) return const <MusicFolder>[];

    final List<MusicFolder> folders = <MusicFolder>[];
    for (final Object? raw in rawItems) {
      if (raw is! Map<String, dynamic>) continue;
      final String? id = _string(raw['Id']);
      final String? name = _string(raw['Name']);
      if (id == null || name == null) continue;

      // Jellyfin normally reports `music`. A missing CollectionType is kept for
      // compatibility with older/custom servers; an explicit non-music type is
      // not shown in Linthra's music browser.
      final String? collectionType = _string(raw['CollectionType']);
      if (collectionType != null && collectionType.toLowerCase() != 'music') {
        continue;
      }
      folders.add(MusicFolder(id: id, name: name));
    }
    folders.sort(_compareFolders);
    return folders;
  }

  @override
  Future<MusicFolderListing> fetchFolder(String folderId) async {
    final Uri uri = Uri.parse('${session.baseUrl}/Items').replace(
      queryParameters: <String, String>{
        'UserId': session.userId,
        'ParentId': folderId,
        'Recursive': 'false',
        'IncludeItemTypes': 'Folder,MusicArtist,MusicAlbum,Audio',
        'SortBy': 'IsFolder,SortName',
        'SortOrder': 'Ascending',
        'Fields': 'RunTimeTicks,ProductionYear,ChildCount',
        'EnableImages': 'true',
      },
    );
    final Map<String, dynamic> body = await _getObject(uri);
    final Object? rawItems = body['Items'];
    if (rawItems is! List) return MusicFolderListing.empty;

    final List<MusicFolder> folders = <MusicFolder>[];
    final tracks = <dynamic>[];
    for (final Object? raw in rawItems) {
      if (raw is! Map<String, dynamic>) continue;
      final String type = _string(raw['Type']) ?? '';
      if (type == 'Audio') {
        final JellyfinItemDto? dto = JellyfinItemDto.fromJson(raw);
        if (dto != null) {
          tracks.add(
            JellyfinTrackMapper.toTrack(dto, baseUrl: session.baseUrl),
          );
        }
        continue;
      }
      if (!_isFolder(raw, type)) continue;
      final String? childId = _string(raw['Id']);
      final String? name = _string(raw['Name']);
      if (childId != null && name != null) {
        folders.add(MusicFolder(id: childId, name: name));
      }
    }
    folders.sort(_compareFolders);
    return MusicFolderListing(
      folders: folders,
      tracks: tracks.cast(),
    );
  }

  void close() => _client.close();

  bool _isFolder(Map<String, dynamic> raw, String type) {
    if (raw['IsFolder'] == true) return true;
    return type == 'Folder' || type == 'MusicArtist' || type == 'MusicAlbum';
  }

  Future<Map<String, dynamic>> _getObject(Uri uri) async {
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: <String, String>{
            'Accept': 'application/json',
            'Authorization': JellyfinAuthHeader.forToken(
              session.deviceId,
              session.accessToken,
            ),
          })
          .timeout(_timeout);
    } on TimeoutException {
      throw JellyfinException.notReachable();
    } on Exception {
      // Never include the low-level error: it may contain request details.
      throw JellyfinException.notReachable();
    }

    final int status = response.statusCode;
    if (status == 401 || status == 403) {
      throw JellyfinException.unauthorized();
    }
    if (status >= 500) {
      throw JellyfinException.serverError(status);
    }
    if (status < 200 || status >= 300) {
      throw JellyfinException.notJellyfin();
    }

    try {
      final Object? decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Fall through to the same friendly, secret-free response error.
    }
    throw JellyfinException.notJellyfin();
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _compareFolders(MusicFolder a, MusicFolder b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
