import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

Map<String, String> _hostedPackagesFromLockfile(String contents) {
  final Map<String, String> result = <String, String>{};
  String? currentPackage;
  String? currentVersion;
  bool currentIsHosted = false;
  bool inPackages = false;

  void flush() {
    if (currentPackage != null && currentIsHosted && currentVersion != null) {
      result[currentPackage!] = currentVersion!;
    }
  }

  for (final String line in const LineSplitter().convert(contents)) {
    if (!inPackages) {
      if (line == 'packages:') {
        inPackages = true;
      }
      continue;
    }

    if (line.isNotEmpty && !line.startsWith(' ')) {
      break;
    }

    final RegExpMatch? packageMatch =
        RegExp(r'^  ([A-Za-z0-9_]+):$').firstMatch(line);
    if (packageMatch != null) {
      flush();
      currentPackage = packageMatch.group(1);
      currentVersion = null;
      currentIsHosted = false;
      continue;
    }

    if (currentPackage == null) {
      continue;
    }

    if (line.trim() == 'source: hosted') {
      currentIsHosted = true;
      continue;
    }

    final String trimmed = line.trim();
    if (trimmed.startsWith('version:')) {
      String value = trimmed.substring('version:'.length).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      currentVersion = value;
    }
  }

  flush();
  return result;
}

void main() {
  group('Flatpak offline build inputs', () {
    test('template resolves the committed lockfile before a no-pub build', () {
      final String template = _read('flatpak/flatpak-flutter.yml');

      expect(template, contains('flutter pub get --enforce-lockfile'));
      expect(template, contains('flutter build linux --release --no-pub'));
    });

    test('generated build primes pub offline and never resolves during build',
        () {
      final String manifest =
          _read('flatpak/io.github.thezupzup.linthra.yml');
      final String buildOptions = manifest
          .split('    build-options:')[1]
          .split('    build-commands:')[0];

      expect(manifest, contains('      - setup-flutter.sh'));
      expect(
        manifest,
        contains('      - flutter build linux --release --no-pub'),
      );
      expect(
        buildOptions,
        isNot(contains('--share=network')),
        reason:
            'Runtime network access must never leak into the build sandbox.',
      );

      final List<FileSystemEntity> sdkModules = Directory(
        'flatpak/generated/modules',
      ).listSync().where((FileSystemEntity entity) {
        return entity is File &&
            RegExp(r'flutter-sdk-[^/]+\.json$').hasMatch(entity.path);
      }).toList();
      expect(sdkModules, hasLength(1));

      final String sdkModule = (sdkModules.single as File).readAsStringSync();
      expect(
        sdkModule,
        contains(r'flutter pub get --offline $@'),
        reason: 'setup-flutter.sh must be incapable of reaching pub.dev.',
      );
    });

    test('every hosted pubspec.lock package is predeclared with a hash', () {
      final Map<String, String> hosted =
          _hostedPackagesFromLockfile(_read('pubspec.lock'));
      expect(hosted, isNotEmpty);

      final Object? decoded = jsonDecode(
        _read('flatpak/generated/sources/pubspec.json'),
      );
      expect(decoded, isA<List<dynamic>>());
      final List<dynamic> sources = decoded! as List<dynamic>;

      final Set<String> destinations = <String>{};
      final Set<String> hashFiles = <String>{};
      for (final dynamic source in sources) {
        if (source is! Map<String, dynamic>) {
          continue;
        }
        final String? dest = source['dest'] as String?;
        final String? destFilename = source['dest-filename'] as String?;
        if (dest != null) destinations.add(dest);
        if (destFilename != null) hashFiles.add(destFilename);

        if (source['type'] == 'archive') {
          expect(
            source['sha256'],
            isA<String>().having((String value) => value.length, 'length', 64),
            reason: 'Every downloaded archive must be content-addressed.',
          );
        }
      }

      for (final MapEntry<String, String> package in hosted.entries) {
        final String basename = '${package.key}-${package.value}';
        expect(
          destinations,
          contains('.pub-cache/hosted/pub.dev/$basename'),
          reason: '${package.key} is hosted in pubspec.lock but is not '
              'predeclared for the Flatpak pub cache.',
        );
        expect(
          hashFiles,
          contains('$basename.sha256'),
          reason: '${package.key} has no generated hosted hash entry.',
        );
      }
    });

    test('native plugin download seams stay network-independent', () {
      final String cmake = _read('linux/CMakeLists.txt');
      final String pubSources =
          _read('flatpak/generated/sources/pubspec.json');

      expect(cmake, contains('FETCHCONTENT_SOURCE_DIR_SQLITE3'));
      expect(cmake, contains('MIMALLOC_USE_STATIC_LIBS OFF'));
      expect(pubSources, contains('sqlite-autoconf-'));
      expect(pubSources, contains('mimalloc-'));
    });

    test('top-level native archives in the generated manifest are hashed', () {
      final List<String> lines = const LineSplitter().convert(
        _read('flatpak/io.github.thezupzup.linthra.yml'),
      );

      for (int index = 0; index < lines.length; index++) {
        if (lines[index].trim() != '- type: archive') {
          continue;
        }

        final int end = index + 8 < lines.length ? index + 8 : lines.length;
        final Iterable<String> block = lines.sublist(index, end);
        expect(
          block.any((String line) => line.trim().startsWith('sha256:')),
          isTrue,
          reason: 'Archive source near line ${index + 1} is not hashed.',
        );
      }
    });
  });
}
