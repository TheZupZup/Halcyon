import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/available_tracks.dart';
import 'package:linthra/core/models/track.dart';

Track _track(String uri, {String title = 'Hello'}) => Track(
      id: uri.split(':').last,
      title: title,
      uri: uri,
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
    );

List<String> _uris(List<Track> tracks) =>
    <String>[for (final Track t in tracks) t.uri];

bool _never(Track _) => false;

void main() {
  final Track jellyOne = _track('jellyfin:1');
  final Track jellyTwo = _track('jellyfin:2', title: 'Someone Like You');
  final Track localOne = _track('file:///music/a.mp3', title: 'Hello');
  final Track subsonicOne = _track('subsonic:9', title: 'Rolling');
  final List<Track> catalog = <Track>[
    jellyOne,
    localOne,
    jellyTwo,
    subsonicOne,
  ];

  group('selectAvailableTracks', () {
    test('returns the catalog untouched when everything is reachable', () {
      final List<Track> result = selectAvailableTracks(
        catalog,
        unavailableSourceIds: const <String>{},
        isAvailableOffline: _never,
      );
      expect(identical(result, catalog), isTrue,
          reason: 'the common path should not copy the catalog');
    });

    test('holds back only the unreachable source, keeping local music', () {
      final List<Track> result = selectAvailableTracks(
        catalog,
        unavailableSourceIds: const <String>{'jellyfin'},
        isAvailableOffline: _never,
      );
      expect(_uris(result), <String>['file:///music/a.mp3', 'subsonic:9']);
    });

    test('keeps an unreachable source track that is available offline', () {
      // Downloaded precisely for this situation: hiding it would take away
      // music that plays perfectly well without the server.
      final List<Track> result = selectAvailableTracks(
        catalog,
        unavailableSourceIds: const <String>{'jellyfin'},
        isAvailableOffline: (Track t) => t.uri == 'jellyfin:2',
      );
      expect(
        _uris(result),
        <String>['file:///music/a.mp3', 'jellyfin:2', 'subsonic:9'],
      );
    });

    test('never mutates the catalog it filters', () {
      final List<Track> input = <Track>[...catalog];
      selectAvailableTracks(
        input,
        unavailableSourceIds: const <String>{'jellyfin'},
        isAvailableOffline: _never,
      );
      expect(_uris(input), _uris(catalog),
          reason: 'filtering is a view, never a removal');
    });

    test('restores the full catalog the moment the source is reachable', () {
      final List<Track> hidden = selectAvailableTracks(
        catalog,
        unavailableSourceIds: const <String>{'jellyfin'},
        isAvailableOffline: _never,
      );
      expect(hidden, hasLength(2));
      final List<Track> restored = selectAvailableTracks(
        catalog,
        unavailableSourceIds: const <String>{},
        isAvailableOffline: _never,
      );
      expect(_uris(restored), _uris(catalog));
    });

    test('can hold back more than one source at once', () {
      final List<Track> result = selectAvailableTracks(
        catalog,
        unavailableSourceIds: const <String>{'jellyfin', 'subsonic'},
        isAvailableOffline: _never,
      );
      expect(_uris(result), <String>['file:///music/a.mp3']);
    });
  });

  group('countUnavailableTracks', () {
    test('is zero when nothing is held back', () {
      expect(
        countUnavailableTracks(
          catalog,
          unavailableSourceIds: const <String>{},
          isAvailableOffline: _never,
        ),
        0,
      );
    });

    test('counts the hidden rows, excluding offline-available ones', () {
      expect(
        countUnavailableTracks(
          catalog,
          unavailableSourceIds: const <String>{'jellyfin'},
          isAvailableOffline: _never,
        ),
        2,
      );
      expect(
        countUnavailableTracks(
          catalog,
          unavailableSourceIds: const <String>{'jellyfin'},
          isAvailableOffline: (Track t) => t.uri == 'jellyfin:2',
        ),
        1,
      );
    });
  });
}
