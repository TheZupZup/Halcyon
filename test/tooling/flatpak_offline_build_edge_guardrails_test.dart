import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _manifestPath = 'flatpak/io.github.thezupzup.linthra.yml';
const String _generatedPubSourcesPath = 'flatpak/generated/sources/pubspec.json';

/// The main offline-build guard intentionally supports only the block mapping
/// form emitted by flatpak-flutter today. A sequence entry whose dash is on a
/// line by itself is valid YAML, but the line-oriented mapping collector does
/// not interpret it. Fail closed on that form instead of letting a source skip
/// the content-addressing audit.
void _expectNoBareDashSequenceEntries(String manifest) {
  final List<String> lines = const LineSplitter().convert(manifest);
  for (int index = 0; index < lines.length; index++) {
    final String trimmed = lines[index].trim();
    if (trimmed == '-') {
      fail(
        'Unsupported bare-dash YAML sequence entry near line ${index + 1}. '
        'Regenerate the Flatpak manifest with the mapping key on the same line '
        'as the dash, or teach the offline guard this form before accepting it.',
      );
    }
  }
}

Iterable<Map<String, dynamic>> _sourceMaps(Object? decoded) sync* {
  if (decoded is! List<dynamic>) return;
  for (final Object? source in decoded) {
    if (source is Map<String, dynamic>) yield source;
  }
}

bool _isSqlitePrefetch(Map<String, dynamic> source) {
  final Object? url = source['url'];
  final Object? dest = source['dest'];
  return url is String &&
      dest is String &&
      url.contains('sqlite-autoconf-') &&
      dest.contains('/_deps/sqlite3-subbuild/sqlite3-populate-prefix/src');
}

bool _isMimallocPrefetch(Map<String, dynamic> source) {
  final Object? url = source['url'];
  final Object? dest = source['dest'];
  return url is String &&
      dest is String &&
      url.contains('/mimalloc/archive/refs/tags/') &&
      dest.startsWith('./build/linux/') &&
      dest.endsWith('/release');
}

void _expectNativePrefetchesRemainFiles(Object? decoded) {
  final List<Map<String, dynamic>> sources = _sourceMaps(decoded).toList();
  final List<Map<String, dynamic>> sqlite =
      sources.where(_isSqlitePrefetch).toList();
  final List<Map<String, dynamic>> mimalloc =
      sources.where(_isMimallocPrefetch).toList();

  expect(
    sqlite,
    isNotEmpty,
    reason: 'The generated sources contain no SQLite FetchContent prefetch.',
  );
  expect(
    mimalloc,
    isNotEmpty,
    reason: 'The generated sources contain no mimalloc prefetch.',
  );

  for (final Map<String, dynamic> source in <Map<String, dynamic>>[
    ...sqlite,
    ...mimalloc,
  ]) {
    expect(
      source['type'],
      'file',
      reason: '${source['url']} must remain a Flatpak file source. An archive '
          'source would be unpacked, so the tarball would no longer exist at '
          'the filename CMake expects during the download-disabled build.',
    );
  }
}

void main() {
  group('Flatpak offline build edge guardrails', () {
    test('generated manifest avoids unsupported bare-dash mappings', () {
      _expectNoBareDashSequenceEntries(File(_manifestPath).readAsStringSync());
    });

    test('a bare-dash mapping fails closed', () {
      const String fixture = '''
sources:
  -
    type: archive
    url: https://example.invalid/source.tar.gz
''';

      expect(
        () => _expectNoBareDashSequenceEntries(fixture),
        throwsA(isA<TestFailure>()),
      );
    });

    test('SQLite and mimalloc prefetches remain file sources', () {
      final Object? decoded =
          jsonDecode(File(_generatedPubSourcesPath).readAsStringSync());
      _expectNativePrefetchesRemainFiles(decoded);
    });

    test('changing a native prefetch to archive is rejected', () {
      final Object? decoded =
          jsonDecode(File(_generatedPubSourcesPath).readAsStringSync());
      final List<Map<String, dynamic>> sources =
          _sourceMaps(decoded).map(Map<String, dynamic>.from).toList();
      final int index = sources.indexWhere(_isSqlitePrefetch);
      expect(index, isNonNegative);
      sources[index]['type'] = 'archive';

      expect(
        () => _expectNativePrefetchesRemainFiles(sources),
        throwsA(isA<TestFailure>()),
      );
    });
  });
}
