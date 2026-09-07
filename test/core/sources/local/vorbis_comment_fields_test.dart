import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/vorbis_comment_fields.dart';

import 'audio_tag_fixtures.dart';

void main() {
  group('VorbisCommentFields.parse', () {
    test('keeps the field names the package folds together', () {
      final Map<String, List<String>>? fields = VorbisCommentFields.parse(
        AudioTagFixtures.flac(
          title: 'Song',
          artist: 'Featured Guest',
          albumArtist: 'Various Artists',
          album: 'Comp',
        ),
      );

      expect(fields?['ARTIST'], <String>['Featured Guest']);
      expect(fields?['ALBUMARTIST'], <String>['Various Artists']);
      expect(fields?['TITLE'], <String>['Song']);
    });

    test('keeps repeated fields in order, the spec way to write a collab', () {
      final Map<String, List<String>>? fields = VorbisCommentFields.parse(
        AudioTagFixtures.flac(
          artist: 'Queen',
          artists: <String>['David Bowie'],
        ),
      );

      expect(fields?['ARTIST'], <String>['Queen', 'David Bowie']);
    });

    test('reads the same fields whatever order they were written in', () {
      Map<String, List<String>>? read({required bool albumArtistFirst}) =>
          VorbisCommentFields.parse(AudioTagFixtures.flac(
            artist: 'Performer',
            albumArtist: 'Album Artist',
            albumArtistFirst: albumArtistFirst,
          ));

      expect(read(albumArtistFirst: false)?['ARTIST'], <String>['Performer']);
      expect(read(albumArtistFirst: true)?['ARTIST'], <String>['Performer']);
      expect(
        read(albumArtistFirst: true)?['ALBUMARTIST'],
        <String>['Album Artist'],
      );
    });

    test('a non-FLAC file is not guessed at', () {
      expect(
          VorbisCommentFields.parse(AudioTagFixtures.wav(title: 'X')), isNull);
      expect(
        VorbisCommentFields.parse(AudioTagFixtures.mp3(title: 'X')),
        isNull,
      );
      expect(VorbisCommentFields.parse(Uint8List(0)), isNull);
    });

    test('a truncated file returns null rather than a partial answer', () {
      final Uint8List full = AudioTagFixtures.flac(title: 'Song', artist: 'A');
      for (final int keep in <int>[4, 8, 20, full.length - 1]) {
        expect(
          VorbisCommentFields.parse(Uint8List.sublistView(full, 0, keep)),
          isNull,
          reason: 'truncated to $keep bytes',
        );
      }
    });

    test('a comment with no separator is skipped, not fatal', () {
      final Uint8List bytes = AudioTagFixtures.flacWithRawComments(
          <String>['NOSEPARATOR', 'ARTIST=A']);

      expect(VorbisCommentFields.parse(bytes)?['ARTIST'], <String>['A']);
    });

    test('field names are matched case-insensitively', () {
      final Uint8List bytes =
          AudioTagFixtures.flacWithRawComments(<String>['artist=Lowercase']);

      expect(
          VorbisCommentFields.parse(bytes)?['ARTIST'], <String>['Lowercase']);
    });

    test('a value containing = keeps everything after the first one', () {
      final Uint8List bytes =
          AudioTagFixtures.flacWithRawComments(<String>['ARTIST=A=B']);

      expect(VorbisCommentFields.parse(bytes)?['ARTIST'], <String>['A=B']);
    });
  });
}
