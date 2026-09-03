import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// This regression file intentionally keeps a small line-oriented YAML fixture
// in the exact layout the guard audits. Analysis and tests still run normally.
// dart format off

const String _manifestPath = 'flatpak/io.github.thezupzup.linthra.yml';
const String _generatedPubSourcesPath = 'flatpak/generated/sources/pubspec.json';

/// The main offline-build guard intentionally supports only the block mapping
/// form emitted by flatpak-flutter today. A sequence entry whose dash is on a
/// line by itself is valid YAML, but the line-oriented mapping collector does
/// not interpret it. Fail closed on that form instead of letting a source skip
/// the content-addressing audit.
void _expectNoBareDashSequenceEntries(String manifest) {
  final lines = const LineSplitter().convert(manifest);
  for (var index = 0; index < lines.length; index++) {
    final trimmed = lines[index].trim();
    if (trimmed != '-') continue;

    fail(
      'Unsupported bare-dash YAML sequence entry near line ${index + 1}. '
      'Regenerate the Flatpak manifest with the mapping key on the same line '
      'as the dash, or teach the offline guard this form before accepting it.',
    );
  }
}

Iterable<Map<String, dynamic>> _sourceMaps(Object? decoded) sync* {
  if (decoded is! List<dynamic>) return;
  for (final source in decoded) {
    if (source is Map<String, dynamic>) yield source;
  }
}

bool _isSqlitePrefetch(Map<String, dynamic> source) {
  final url = source['url'];
  final dest = source['dest'];
  return url is String &&
      dest is String &&
      url.contains('sqlite-autoconf-') &&
      dest.contains('/_deps/sqlite3-subbuild/sqlite3-populate-prefix/src');
}

bool _isMimallocPrefetch(Map<String, dynamic> source) {
  final url = source['url'];
  final dest = source['dest'];
  return url is String &&
      dest is String &&
      url.contains('/mimalloc/archive/refs/tags/') &&
      dest.startsWith('./build/linux/') &&
      dest.endsWith('/release');
}

void _expectNativePrefetchesRemainFiles(Object? decoded) {
  final sources = _sourceMaps(decoded).toList();
  final sqlite = sources.where(_isSqlitePrefetch).toList();
  final mimalloc = sources.where(_isMimallocPrefetch).toList();

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

  final prefetches = <Map<String, dynamic>>[];
  prefetches.addAll(sqlite);
  prefetches.addAll(mimalloc);
  for (final source in prefetches) {
    expect(
      source['type'],
      'file',
      reason: '${source['url']} must remain a Flatpak file source. An archive '
          'source would be unpacked, so the tarball would no longer exist at '
          'the filename CMake expects during the download-disabled build.',
    );
  }
}

Object? _readGeneratedSources() {
  final contents = File(_generatedPubSourcesPath).readAsStringSync();
  return jsonDecode(contents);
}

void main() {
  group('Flatpak offline build edge guardrails', () {
    test('generated manifest avoids unsupported bare-dash mappings', () {
      final manifest = File(_manifestPath).readAsStringSync();
      _expectNoBareDashSequenceEntries(manifest);
    });

    test('a bare-dash mapping fails closed', () {
      const fixture = '''
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
      _expectNativePrefetchesRemainFiles(_readGeneratedSources());
    });

    test('changing a native prefetch to archive is rejected', () {
      final decoded = _readGeneratedSources();
      final sources = <Map<String, dynamic>>[];
      for (final source in _sourceMaps(decoded)) {
        sources.add(Map<String, dynamic>.from(source));
      }

      final index = sources.indexWhere(_isSqlitePrefetch);
      expect(index, greaterThanOrEqualTo(0));
      sources[index]['type'] = 'archive';

      expect(
        () => _expectNativePrefetchesRemainFiles(sources),
        throwsA(isA<TestFailure>()),
      );
    });
  });
}
