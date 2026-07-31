import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_folder_browser_source.dart';

void main() {
  const JellyfinSession session = JellyfinSession(
    baseUrl: 'https://music.example.test',
    userId: 'user-1',
    accessToken: 'secret-token',
    deviceId: 'device-1',
    serverName: 'Home',
  );

  test('lists only music media folders in alphabetical order', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.url.path, '/Library/MediaFolders');
      expect(request.url.queryParameters['IsHidden'], 'false');
      expect(request.headers['Authorization'], contains('secret-token'));
      return http.Response(
        jsonEncode(<String, Object>{
          'Items': <Object>[
            <String, Object>{
              'Id': 'movies',
              'Name': 'Movies',
              'CollectionType': 'movies',
            },
            <String, Object>{
              'Id': 'music-b',
              'Name': 'Zebra Music',
              'CollectionType': 'music',
            },
            <String, Object>{
              'Id': 'music-a',
              'Name': 'Albums',
              'CollectionType': 'music',
            },
          ],
        }),
        200,
      );
    });
    final JellyfinFolderBrowserSource source = JellyfinFolderBrowserSource(
      session: session,
      httpClient: client,
    );
    addTearDown(source.close);

    final folders = await source.fetchRootFolders();

    expect(folders.map((folder) => folder.id), <String>['music-a', 'music-b']);
    expect(folders.map((folder) => folder.name),
        <String>['Albums', 'Zebra Music']);
  });

  test('maps immediate child folders and audio tracks', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.url.path, '/Items');
      expect(request.url.queryParameters['ParentId'], 'music-a');
      expect(request.url.queryParameters['Recursive'], 'false');
      return http.Response(
        jsonEncode(<String, Object>{
          'Items': <Object>[
            <String, Object>{
              'Id': 'album-1',
              'Name': 'An Album',
              'Type': 'MusicAlbum',
              'IsFolder': true,
            },
            <String, Object>{
              'Id': 'song-1',
              'Name': 'A Song',
              'Type': 'Audio',
              'Album': 'An Album',
              'AlbumId': 'album-1',
              'AlbumArtist': 'An Artist',
              'Artists': <String>['An Artist'],
              'RunTimeTicks': 300000000,
            },
          ],
        }),
        200,
      );
    });
    final JellyfinFolderBrowserSource source = JellyfinFolderBrowserSource(
      session: session,
      httpClient: client,
    );
    addTearDown(source.close);

    final listing = await source.fetchFolder('music-a');

    expect(listing.folders.single.name, 'An Album');
    expect(listing.tracks.single.title, 'A Song');
    expect(listing.tracks.single.uri, 'jellyfin:song-1');
  });
}
