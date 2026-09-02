import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';

void main() {
  group('IoAudioFileScanner', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('linthra_scan_test');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('lists every file recursively, including non-audio files', () async {
      final nested = Directory('${root.path}/Album')..createSync();
      File('${root.path}/a.mp3').writeAsStringSync('x');
      File('${nested.path}/b.flac').writeAsStringSync('x');
      File('${nested.path}/notes.txt').writeAsStringSync('x');

      const scanner = IoAudioFileScanner();
      final files = await scanner.listFiles(root.path);

      expect(files, hasLength(3));
      expect(files.every((path) => File(path).existsSync()), isTrue);
      expect(files.any((path) => path.endsWith('a.mp3')), isTrue);
      expect(files.any((path) => path.endsWith('b.flac')), isTrue);
      expect(files.any((path) => path.endsWith('notes.txt')), isTrue);
    });

    test('walks several directory levels deep', () async {
      final albumDir = Directory('${root.path}/Artist/Album');
      albumDir.createSync(recursive: true);
      final discDir = Directory('${albumDir.path}/Disc 2');
      discDir.createSync();
      // An empty directory in the tree must not break the walk.
      Directory('${root.path}/Empty').createSync();
      File('${root.path}/top.mp3').writeAsStringSync('x');
      File('${albumDir.path}/mid.flac').writeAsStringSync('x');
      File('${discDir.path}/deep.ogg').writeAsStringSync('x');

      const scanner = IoAudioFileScanner();
      final files = await scanner.listFiles(root.path);

      expect(files, hasLength(3));
      expect(files.any((path) => path.endsWith('top.mp3')), isTrue);
      expect(files.any((path) => path.endsWith('mid.flac')), isTrue);
      expect(files.any((path) => path.endsWith('deep.ogg')), isTrue);
    });

    test('raises a recoverable scan error for a folder that is gone', () async {
      // A selected folder that no longer resolves — unmounted drive, deleted
      // folder, or a revoked Flatpak portal document — must not look like a
      // successful scan of an empty folder: that result would be persisted and
      // would wipe a catalog the user's files are still behind.
      const scanner = IoAudioFileScanner();

      await expectLater(
        scanner.listFiles('${root.path}/missing'),
        throwsA(
          isA<FolderScanException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains("couldn't find the selected folder"),
              contains('selecting the folder again'),
            ),
          ),
        ),
      );
    });
  });
}
