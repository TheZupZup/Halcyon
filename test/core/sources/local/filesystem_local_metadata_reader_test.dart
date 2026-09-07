import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';

import 'audio_tag_fixtures.dart';

void main() {
  const FilesystemLocalMetadataReader reader = FilesystemLocalMetadataReader();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linthra_tag_reader_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// Writes [bytes] as [name] under the temp root and returns its path.
  String write(String name, Uint8List bytes) {
    final File file = File('${root.path}/$name');
    file.writeAsBytesSync(bytes, flush: true);
    return file.path;
  }

  group('tagged files', () {
    test('an ID3v2 MP3 gives its title, both artists, album and track', () {
      final String path = write(
        'song.mp3',
        AudioTagFixtures.mp3(
          title: 'Blue Monday',
          artist: 'New Order',
          albumArtist: 'New Order',
          album: 'Power, Corruption & Lies',
          track: '3/8',
        ),
      );

      return reader.readFromPath(path).then((LocalAudioMetadata? metadata) {
        expect(metadata, isNotNull);
        expect(metadata!.title, 'Blue Monday');
        expect(metadata.artist, 'New Order');
        expect(metadata.albumArtist, 'New Order');
        expect(metadata.album, 'Power, Corruption & Lies');
        expect(metadata.trackNumber, 3);
      });
    });

    test('an MP3 keeps the track artist and the album artist apart', () async {
      // The compilation case, and the reason the reader parses ID3 rather than
      // taking the package's merged `artist`: TPE1 is who played this track,
      // TPE2 is who the album belongs to, and collapsing them splits an album.
      final String path = write(
        'compilation.mp3',
        AudioTagFixtures.mp3(
          title: 'Guest Spot',
          artist: 'Featured Guest',
          albumArtist: 'Various Artists',
          album: 'A Compilation',
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.artist, 'Featured Guest');
      expect(metadata.albumArtist, 'Various Artists');
    });

    test('a FLAC gives its Vorbis comments and a real duration', () async {
      final String path = write(
        'song.flac',
        AudioTagFixtures.flac(
          title: 'Teardrop',
          artist: 'Massive Attack',
          album: 'Mezzanine',
          track: '2',
          sampleRate: 44100,
          totalSamples: 44100 * 5,
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Teardrop');
      expect(metadata.artist, 'Massive Attack');
      expect(metadata.album, 'Mezzanine');
      expect(metadata.trackNumber, 2);
      // Duration comes from STREAMINFO, not from the filename — the one thing a
      // filename can never supply.
      expect(metadata.duration, const Duration(seconds: 5));
    });

    test('a WAV gives its RIFF INFO tags', () async {
      final String path = write(
        'song.wav',
        AudioTagFixtures.wav(
          title: 'Sample',
          artist: 'Field Recordist',
          album: 'Recordings',
          track: '7',
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Sample');
      expect(metadata.artist, 'Field Recordist');
      expect(metadata.album, 'Recordings');
      expect(metadata.trackNumber, 7);
    });

    test('non-ASCII tags survive the round trip', () async {
      final String path = write(
        'accents.flac',
        AudioTagFixtures.flac(
          title: 'Où est la mer',
          artist: 'Éliane Radigue',
          album: 'Trilogie de la Mort',
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Où est la mer');
      expect(metadata.artist, 'Éliane Radigue');
    });
  });

  group('files that carry nothing usable', () {
    test('an untagged file reads as no metadata rather than failing', () async {
      final String path = write('bare.flac', AudioTagFixtures.flac());

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      // A FLAC with no comments still has a duration, so this is not null — but
      // nothing that would override the filename.
      expect(metadata?.title, isNull);
      expect(metadata?.artist, isNull);
      expect(metadata?.album, isNull);
    });

    test('blank tags fall back instead of showing an empty title', () async {
      final String path = write(
        'blank.mp3',
        AudioTagFixtures.mp3(title: '   ', artist: '', album: 'Real Album'),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, isNull);
      expect(metadata.artist, isNull);
      expect(metadata.album, 'Real Album');
    });

    test('a truncated file reads as null, not an exception', () async {
      final Uint8List full = AudioTagFixtures.flac(title: 'Cut Short');
      final String path = write(
        'truncated.flac',
        Uint8List.sublistView(full, 0, full.length ~/ 2),
      );

      await expectLater(reader.readFromPath(path), completion(isNull));
    });

    test('a file that is not audio at all reads as null', () async {
      final String path = write(
        'notes.mp3',
        Uint8List.fromList('this is plain text, not an MP3'.codeUnits),
      );

      await expectLater(reader.readFromPath(path), completion(isNull));
    });

    test('an empty file reads as null', () async {
      final String path = write('empty.flac', Uint8List(0));

      await expectLater(reader.readFromPath(path), completion(isNull));
    });

    test('a missing file reads as null', () async {
      await expectLater(
        reader.readFromPath('${root.path}/never-existed.mp3'),
        completion(isNull),
      );
    });

    test('a directory named like a track reads as null', () async {
      final Directory directory = Directory('${root.path}/album.mp3');
      directory.createSync();

      await expectLater(
          reader.readFromPath(directory.path), completion(isNull));
    });
  });

  group('what the library actually shows', () {
    test('a tagged file beats the filename fallback', () async {
      final String path = write(
        '01 - untitled.flac',
        AudioTagFixtures.flac(
          title: 'The Real Title',
          artist: 'The Real Artist',
          album: 'The Real Album',
          track: '4',
        ),
      );

      final Track track = LocalTrackMapper.fromPath(
        path,
        metadata: await reader.readFromPath(path),
        scanRoot: root.path,
      );

      expect(track.title, 'The Real Title');
      expect(track.artistName, 'The Real Artist');
      expect(track.albumName, 'The Real Album');
      expect(track.trackNumber, 4);
      expect(track.duration, greaterThan(Duration.zero));
    });

    test('an untagged file still appears, from its filename', () async {
      final String path = write(
        '03 - Filename Title.flac',
        AudioTagFixtures.flac(),
      );

      final Track track = LocalTrackMapper.fromPath(
        path,
        metadata: await reader.readFromPath(path),
        scanRoot: root.path,
      );

      expect(track.title, 'Filename Title');
      expect(track.trackNumber, 3);
    });

    test('an unreadable file is still a track, never a dropped one', () async {
      final String path = write(
        '05 - Broken.mp3',
        Uint8List.fromList('not really an MP3'.codeUnits),
      );

      final Track track = LocalTrackMapper.fromPath(
        path,
        metadata: await reader.readFromPath(path),
        scanRoot: root.path,
      );

      expect(track.title, 'Broken');
      expect(track.trackNumber, 5);
    });
  });

  group('staying off the UI thread', () {
    // The tag parse itself is synchronous. If readFromPath did all its work
    // before returning, its Future would already be complete, and awaiting a
    // complete Future only schedules a microtask. The microtask queue drains
    // fully before the event loop gets another turn, so a scan of a whole
    // library would run as one unbroken chain: no frame rendered and no input
    // handled from the first file to the last. Nothing about that shows up in
    // a normal test, which is why these two assert it directly.

    test('one read reaches the event loop, not just the microtask queue',
        () async {
      final String path =
          write('One.flac', AudioTagFixtures.flac(title: 'One'));
      var reachedEventLoop = false;
      // Timer fires from the event loop; a microtask-only chain never lets it.
      Timer.run(() => reachedEventLoop = true);

      await reader.readFromPath(path);

      expect(
        reachedEventLoop,
        isTrue,
        reason: 'readFromPath returned without ever yielding to the event '
            'loop, so a scan would freeze the UI for its whole duration',
      );
    });

    test('a run of reads keeps letting the event loop in', () async {
      final List<String> paths = <String>[
        for (int i = 0; i < 20; i++)
          write('Track $i.flac', AudioTagFixtures.flac(title: 'T$i')),
      ];
      var ticks = 0;
      final Timer timer =
          Timer.periodic(const Duration(microseconds: 100), (_) => ticks++);
      addTearDown(timer.cancel);

      for (final String path in paths) {
        await reader.readFromPath(path);
      }

      // Not one tick per file exactly (timers are not that precise), but a
      // starved event loop scores zero, which is the failure being caught.
      expect(
        ticks,
        greaterThan(0),
        reason: 'the event loop never ran during a 20-file pass',
      );
    });

    test('a missing file still yields before giving up', () async {
      // The early return is the one path that skips the parse; it must not
      // become the fast synchronous path that starves everything after it.
      var reachedEventLoop = false;
      Timer.run(() => reachedEventLoop = true);

      expect(await reader.readFromPath('${root.path}/nope.flac'), isNull);
      expect(reachedEventLoop, isTrue);
    });
  });
}
