import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/quick_search.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

Track _track(
  String id,
  String title, {
  String? artist,
  String? album,
}) {
  return Track(
    id: id,
    title: title,
    uri: 'file:///$id.mp3',
    artistName: artist,
    albumName: album,
  );
}

const List<Album> _albums = <Album>[
  Album(id: 'al-1', title: 'Random Access Memories', artistName: 'Daft Punk'),
  Album(id: 'al-2', title: 'Discovery', artistName: 'Daft Punk'),
];

const List<Artist> _artists = <Artist>[
  Artist(id: 'ar-1', name: 'Daft Punk', albumCount: 2, trackCount: 20),
  Artist(id: 'ar-2', name: 'Beyoncé', albumCount: 1, trackCount: 12),
];

const List<Playlist> _playlists = <Playlist>[
  Playlist(id: 'pl-1', name: 'Late night drive', trackIds: <String>['a', 'b']),
  Playlist(id: 'pl-2', name: 'Focus'),
];

final List<Track> _tracks = <Track>[
  _track('1', 'Get Lucky',
      artist: 'Daft Punk', album: 'Random Access Memories'),
  _track('2', 'Instant Crush', artist: 'Daft Punk'),
  _track('3', 'Halo', artist: 'Beyoncé', album: 'I Am… Sasha Fierce'),
];

QuickSearchResults _search(String query, {int limit = kQuickSearchGroupLimit}) {
  return runQuickSearch(
    query: query,
    tracks: _tracks,
    albums: _albums,
    artists: _artists,
    playlists: _playlists,
    limit: limit,
  );
}

List<String> _titles(Iterable<QuickSearchResult> results) =>
    <String>[for (final QuickSearchResult r in results) r.title];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('runQuickSearch', () {
    test('an empty query returns nothing rather than the whole library', () {
      expect(_search('').isEmpty, isTrue);
      expect(_search('   ').isEmpty, isTrue);
      expect(_search('').rows, isEmpty);
    });

    test('finds songs, albums, artists and playlists in one pass', () {
      final QuickSearchResults results = _search('daft');

      expect(
        _titles(results.groups[QuickSearchKind.song]!),
        <String>['Get Lucky', 'Instant Crush'],
      );
      expect(
        _titles(results.groups[QuickSearchKind.album]!),
        <String>['Random Access Memories', 'Discovery'],
      );
      expect(
        _titles(results.groups[QuickSearchKind.artist]!),
        <String>['Daft Punk'],
      );
      // Nothing playlist-shaped matches "daft", so that group is absent rather
      // than present-and-empty.
      expect(results.groups.containsKey(QuickSearchKind.playlist), isFalse);
    });

    test('rows flatten the groups in render order', () {
      final QuickSearchResults results = _search('daft');

      expect(
        results.rows.map((QuickSearchResult r) => r.kind).toList(),
        <QuickSearchKind>[
          QuickSearchKind.song,
          QuickSearchKind.song,
          QuickSearchKind.album,
          QuickSearchKind.album,
          QuickSearchKind.artist,
        ],
      );
      expect(results.rows.length, 5);
    });

    test('matching is case and accent insensitive', () {
      final QuickSearchResults results = _search('beyonce');

      expect(_titles(results.groups[QuickSearchKind.artist]!),
          <String>['Beyoncé']);
      expect(_titles(results.groups[QuickSearchKind.song]!), <String>['Halo']);
    });

    test('a title match outranks an artist or album match', () {
      final QuickSearchResults results = runQuickSearch(
        query: 'discovery',
        tracks: <Track>[
          _track('a', 'One More Time', album: 'Discovery'),
          _track('b', 'Discovery', artist: 'Someone Else'),
        ],
      );

      expect(
        _titles(results.groups[QuickSearchKind.song]!),
        <String>['Discovery', 'One More Time'],
        reason: 'the song actually called Discovery must come first',
      );
    });

    test('a prefix match outranks a match inside a word', () {
      final QuickSearchResults results = runQuickSearch(
        query: 'ark',
        tracks: <Track>[
          _track('a', 'Aardvark'),
          _track('b', 'Arkansas'),
          _track('c', 'The Dark Ark'),
        ],
      );

      expect(
        _titles(results.groups[QuickSearchKind.song]!),
        <String>['Arkansas', 'The Dark Ark', 'Aardvark'],
        reason: 'prefix beats word start beats mid-word',
      );
    });

    test('an exact title outranks a longer title that starts the same', () {
      final QuickSearchResults results = runQuickSearch(
        query: 'halo',
        tracks: <Track>[
          _track('a', 'Halo Theme'),
          _track('b', 'Halo'),
        ],
      );

      expect(
        _titles(results.groups[QuickSearchKind.song]!),
        <String>['Halo', 'Halo Theme'],
      );
    });

    test('each group is capped at the limit', () {
      final QuickSearchResults results = runQuickSearch(
        query: 'song',
        tracks: <Track>[
          for (int i = 0; i < 40; i++) _track('$i', 'Song $i'),
        ],
        limit: 3,
      );

      expect(results.groups[QuickSearchKind.song], hasLength(3));
      expect(results.rows, hasLength(3));
    });

    test('equal scores keep catalog order, so results are deterministic', () {
      final List<Track> catalog = <Track>[
        for (int i = 0; i < 10; i++) _track('$i', 'Song $i'),
      ];

      final QuickSearchResults first =
          runQuickSearch(query: 'song', tracks: catalog, limit: 4);
      final QuickSearchResults second =
          runQuickSearch(query: 'song', tracks: catalog, limit: 4);

      expect(
        _titles(first.groups[QuickSearchKind.song]!),
        <String>['Song 0', 'Song 1', 'Song 2', 'Song 3'],
      );
      expect(
        _titles(second.groups[QuickSearchKind.song]!),
        _titles(first.groups[QuickSearchKind.song]!),
      );
    });

    test('a query that matches nothing produces no groups at all', () {
      final QuickSearchResults results = _search('zzzzz');

      expect(results.isEmpty, isTrue);
      expect(results.groups, isEmpty);
    });

    test('playlists match by name and describe themselves honestly', () {
      final QuickSearchResults results = _search('late');
      final QuickSearchResult row =
          results.groups[QuickSearchKind.playlist]!.single;

      expect(row.title, 'Late night drive');
      expect(row.subtitle, '2 songs');
      expect((row as QuickSearchPlaylist).playlist.id, 'pl-1');
    });

    test('a synced playlist names its server in the subtitle', () {
      final QuickSearchResults results = runQuickSearch(
        query: 'road',
        playlists: const <Playlist>[
          Playlist(
            id: 'pl-9',
            name: 'Road trip',
            source: PlaylistSource.jellyfin,
            trackIds: <String>['a'],
          ),
        ],
      );

      expect(
        results.groups[QuickSearchKind.playlist]!.single.subtitle,
        '1 song • Jellyfin',
      );
    });

    test('results carry the identity their route needs', () {
      final QuickSearchResults results = _search('daft');

      final QuickSearchAlbum album =
          results.groups[QuickSearchKind.album]!.first as QuickSearchAlbum;
      final QuickSearchArtist artist =
          results.groups[QuickSearchKind.artist]!.single as QuickSearchArtist;
      final QuickSearchSong song =
          results.groups[QuickSearchKind.song]!.first as QuickSearchSong;

      expect(album.album.id, 'al-1');
      expect(artist.artist.id, 'ar-1');
      expect(song.track.uri, 'file:///1.mp3');
      expect(song.id, song.track.uri, reason: 'a song row is keyed by its uri');
    });

    test('a song subtitle falls back to null when it has no metadata', () {
      final QuickSearchResults results = runQuickSearch(
        query: 'untitled',
        tracks: <Track>[_track('a', 'Untitled')],
      );

      expect(results.rows.single.subtitle, isNull);
    });

    test('a zero limit yields nothing instead of throwing', () {
      expect(_search('daft', limit: 0).isEmpty, isTrue);
    });
  });
}
