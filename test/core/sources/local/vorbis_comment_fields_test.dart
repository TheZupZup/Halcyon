import 'dart:io';
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

  group('VorbisCommentFields.read', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('linthra_vorbis_');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    File write(String name, Uint8List bytes) =>
        File('${root.path}/$name')..writeAsBytesSync(bytes, flush: true);

    test('finds the comments behind megabytes of other metadata', () async {
      // A FLAC with embedded cover art carries a PICTURE block ahead of its
      // comments, routinely several MiB. Reading a fixed prefix would miss the
      // comments on exactly those files and fall back to the merged list,
      // silently losing the distinction this class exists to keep.
      final File file = write(
        'with-art.flac',
        AudioTagFixtures.flac(
          artist: 'Featured Guest',
          albumArtist: 'Various Artists',
          paddingBefore: 4 * 1024 * 1024,
        ),
      );

      final Map<String, List<String>>? fields =
          await VorbisCommentFields.read(file);

      expect(fields?['ARTIST'], <String>['Featured Guest']);
      expect(fields?['ALBUMARTIST'], <String>['Various Artists']);
    });

    test('reads a plain file the same way', () async {
      final File file = write(
        'plain.flac',
        AudioTagFixtures.flac(artist: 'Solo Act'),
      );

      expect(
        (await VorbisCommentFields.read(file))?['ARTIST'],
        <String>['Solo Act'],
      );
    });

    test('a missing or non-FLAC file is null, never a throw', () async {
      expect(await VorbisCommentFields.read(File('${root.path}/gone.flac')),
          isNull);
      expect(
        await VorbisCommentFields.read(
          write('song.wav', AudioTagFixtures.wav(title: 'X')),
        ),
        isNull,
      );
    });

    test('a file truncated mid-block is null, not a partial answer', () async {
      final Uint8List full = AudioTagFixtures.flac(
        artist: 'Performer',
        paddingBefore: 8192,
      );
      final File file = write(
        'cut.flac',
        Uint8List.sublistView(full, 0, full.length - 40),
      );

      expect(await VorbisCommentFields.read(file), isNull);
    });

    test('a FLAC with no comment block at all is null', () async {
      // STREAMINFO marked as the last block: valid, just untagged.
      final Uint8List bytes = Uint8List.fromList(<int>[
        0x66, 0x4C, 0x61, 0x43, // fLaC
        0x80, 0x00, 0x00, 0x22, // STREAMINFO, last block, 34 bytes
        ...List<int>.filled(34, 0),
      ]);

      expect(await VorbisCommentFields.read(write('bare.flac', bytes)), isNull);
    });
  });
}
