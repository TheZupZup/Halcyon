import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

typedef _HostedPackage = ({String version, String sha256});

String _read(String path) => File(path).readAsStringSync();

bool _isRemoteUrl(Object? value) {
  return value is String &&
      (value.startsWith('https://') || value.startsWith('http://'));
}

Iterable<Map<String, dynamic>> _maps(Object? value) sync* {
  if (value is! List<dynamic>) return;
  for (final Object? item in value) {
    if (item is Map<String, dynamic>) yield item;
  }
}

void _expectRemoteSourcesHashed(Object? value, String context) {
  for (final Map<String, dynamic> source in _maps(value)) {
    final Object? type = source['type'];
    final Object? url = source['url'];
    if ((type != 'archive' && type != 'file') || !_isRemoteUrl(url)) {
      continue;
    }

    final Object? digest = source['sha256'];
    expect(
      digest,
      isA<String>().having(
        (String value) => _sha256.hasMatch(value),
        'valid SHA-256',
        isTrue,
      ),
      reason: '$context remote $type source is not content-addressed: $url',
    );
  }
}

void _expectJsonSourcesHashed(Object? value, String context) {
  if (value is Map<String, dynamic>) {
    if (value.containsKey('sources')) {
      _expectRemoteSourcesHashed(value['sources'], context);
    }
    for (final Object? child in value.values) {
      _expectJsonSourcesHashed(child, context);
    }
    return;
  }

  if (value is List<dynamic>) {
    for (final Object? child in value) {
      _expectJsonSourcesHashed(child, context);
    }
  }
}

Map<String, _HostedPackage> _hostedPackagesFromLockfile(String contents) {
  final Map<String, _HostedPackage> result = <String, _HostedPackage>{};
  String? currentPackage;
  String? currentVersion;
  String? currentSha256;
  bool currentIsHosted = false;
  bool inPackages = false;

  void flush() {
    if (currentPackage != null &&
        currentIsHosted &&
        currentVersion != null &&
        currentSha256 != null) {
      result[currentPackage!] = (
        version: currentVersion!,
        sha256: currentSha256!,
      );
    }
  }

  for (final String line in const LineSplitter().convert(contents)) {
    if (!inPackages) {
      if (line == 'packages:') inPackages = true;
      continue;
    }

    if (line.isNotEmpty && !line.startsWith(' ')) break;

    final RegExpMatch? packageMatch =
        RegExp(r'^  ([A-Za-z0-9_]+):$').firstMatch(line);
    if (packageMatch != null) {
      flush();
      currentPackage = packageMatch.group(1);
      currentVersion = null;
      currentSha256 = null;
      currentIsHosted = false;
      continue;
    }

    if (currentPackage == null) continue;

    final String trimmed = line.trim();
    if (trimmed == 'source: hosted') {
      currentIsHosted = true;
    } else if (trimmed.startsWith('version:')) {
      currentVersion = _unquote(trimmed.substring('version:'.length).trim());
    } else if (trimmed.startsWith('sha256:')) {
      currentSha256 = _unquote(trimmed.substring('sha256:'.length).trim());
    }
  }

  flush();
  return result;
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

String? _yamlScalar(List<String> block, String key) {
  final String prefix = '$key:';
  for (final String line in block) {
    final String trimmed = line.trim();
    if (!trimmed.startsWith(prefix)) continue;
    return _unquote(trimmed.substring(prefix.length).trim());
  }
  return null;
}

void _expectManifestRemoteSourcesHashed(String manifest) {
  final List<String> lines = const LineSplitter().convert(manifest);

  for (int index = 0; index < lines.length; index++) {
    final String line = lines[index];
    final RegExpMatch? typeMatch = RegExp(
      r'''^- type:\s*["']?(archive|file)["']?$''',
    ).firstMatch(line.trim());
    if (typeMatch == null) continue;

    final int indent = line.length - line.trimLeft().length;
    final List<String> block = <String>[line];
    for (int peerIndex = index + 1; peerIndex < lines.length; peerIndex++) {
      final String peer = lines[peerIndex];
      if (peer.trim().isEmpty) {
        block.add(peer);
        continue;
      }

      final int peerIndent = peer.length - peer.trimLeft().length;
      if (peerIndent < indent) break;
      if (peerIndent == indent && peer.trimLeft().startsWith('- ')) break;
      block.add(peer);
    }

    final String? url = _yamlScalar(block, 'url');
    if (!_isRemoteUrl(url)) continue;

    final String? digest = _yamlScalar(block, 'sha256');
    expect(
      digest != null && _sha256.hasMatch(digest),
      isTrue,
      reason: 'Remote ${typeMatch.group(1)} source near line '
          '${index + 1} is missing its own valid SHA-256: $url',
    );
  }
}

void _expectNoBuildNetworkGrant(String manifest) {
  bool inFinishArgs = false;
  final List<String> lines = const LineSplitter().convert(manifest);

  for (int index = 0; index < lines.length; index++) {
    final String line = lines[index];
    if (line == 'finish-args:') {
      inFinishArgs = true;
      continue;
    }
    if (inFinishArgs && line.isNotEmpty && !line.startsWith(' ')) {
      inFinishArgs = false;
    }

    if (line.contains('--share=network') && !inFinishArgs) {
      fail(
        'Build-time network grant near generated manifest line '
        '${index + 1}: $line',
      );
    }
  }
}

String _linthraModule(String manifest) {
  const String marker = '  - name: linthra\n';
  final int start = manifest.indexOf(marker);
  expect(
    start,
    isNonNegative,
    reason: 'Generated manifest has no linthra module',
  );

  final int nextModule = manifest.indexOf('\n  - name:', start + marker.length);
  if (nextModule == -1) return manifest.substring(start);
  return manifest.substring(start, nextModule);
}

void main() {
  test('Flatpak build inputs stay complete and network-independent', () {
    final String template = _read('flatpak/flatpak-flutter.yml');
    final String manifest =
        _read('flatpak/io.github.thezupzup.linthra.yml');
    final String cmake = _read('linux/CMakeLists.txt');

    expect(template, contains('flutter pub get --enforce-lockfile'));
    expect(template, contains('flutter build linux --release --no-pub'));

    final String linthraModule = _linthraModule(manifest);
    final int setupIndex = linthraModule.indexOf('      - setup-flutter.sh');
    final int buildIndex = linthraModule.indexOf(
      '      - flutter build linux --release --no-pub',
    );
    expect(setupIndex, isNonNegative);
    expect(buildIndex, greaterThan(setupIndex));

    _expectNoBuildNetworkGrant(manifest);
    _expectManifestRemoteSourcesHashed(manifest);

    final List<File> generatedModules = Directory('flatpak/generated/modules')
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.json'))
        .toList();
    expect(generatedModules, isNotEmpty);

    final List<File> sdkModules = generatedModules
        .where((File file) => file.path.contains('flutter-sdk-'))
        .toList();
    expect(sdkModules, hasLength(1));

    for (final File module in generatedModules) {
      final String contents = module.readAsStringSync();
      expect(
        contents,
        isNot(contains('--share=network')),
        reason: '${module.path} grants build-time network access',
      );
      final Object? decoded = jsonDecode(contents);
      _expectJsonSourcesHashed(decoded, module.path);
    }

    final Map<String, dynamic> sdk =
        jsonDecode(sdkModules.single.readAsStringSync())
            as Map<String, dynamic>;
    final List<Map<String, dynamic>> setupSources = _maps(sdk['sources'])
        .where(
          (Map<String, dynamic> source) =>
              source['dest-filename'] == 'setup-flutter.sh',
        )
        .toList();
    expect(setupSources, hasLength(1));
    expect(
      setupSources.single['commands'],
      contains(r'flutter pub get --offline $@'),
    );

    final String pubSourcesText =
        _read('flatpak/generated/sources/pubspec.json');
    final Object? pubSources = jsonDecode(pubSourcesText);
    _expectRemoteSourcesHashed(
      pubSources,
      'flatpak/generated/sources/pubspec.json',
    );

    final List<Map<String, dynamic>> pubSourceMaps = _maps(pubSources).toList();
    final Map<String, _HostedPackage> hosted =
        _hostedPackagesFromLockfile(_read('pubspec.lock'));
    expect(hosted, isNotEmpty);

    for (final MapEntry<String, _HostedPackage> package in hosted.entries) {
      final String basename = '${package.key}-${package.value.version}';
      final String destination = '.pub-cache/hosted/pub.dev/$basename';
      final String hashFilename = '$basename.sha256';

      final List<Map<String, dynamic>> archives = pubSourceMaps
          .where(
            (Map<String, dynamic> source) =>
                source['type'] == 'archive' &&
                source['dest'] == destination,
          )
          .toList();
      expect(
        archives,
        hasLength(1),
        reason: '$basename is missing from the generated Flatpak pub cache',
      );
      expect(
        archives.single['sha256'],
        package.value.sha256,
        reason: '$basename archive SHA-256 drifted from pubspec.lock',
      );

      final List<Map<String, dynamic>> hashEntries = pubSourceMaps
          .where(
            (Map<String, dynamic> source) =>
                source['dest-filename'] == hashFilename,
          )
          .toList();
      expect(
        hashEntries,
        hasLength(1),
        reason: '$basename has no generated hosted-hash entry',
      );
      expect(
        hashEntries.single['contents'],
        package.value.sha256,
        reason: '$basename hosted-hash contents drifted from pubspec.lock',
      );
    }

    expect(cmake, contains('FETCHCONTENT_SOURCE_DIR_SQLITE3'));
    expect(cmake, contains('MIMALLOC_USE_STATIC_LIBS OFF'));
    expect(pubSourcesText, contains('sqlite-autoconf-'));
    expect(pubSourcesText, contains('mimalloc-'));

    final String smoke = _read('scripts/flatpak_offline_build_smoke.sh');
    expect(smoke, contains('--download-only'));
    expect(smoke, contains('--disable-cache'));
    expect(smoke, contains('--disable-download'));
  });

  test('manifest hash belongs to the same source mapping', () {
    const String manifest = '''
sources:
  - type: archive
    url: https://example.invalid/first.tar.gz
  - type: archive
    url: https://example.invalid/second.tar.gz
    sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
''';

    expect(
      () => _expectManifestRemoteSourcesHashed(manifest),
      throwsA(anything),
    );
  });

  test('remote file sources require their own SHA-256', () {
    expect(
      () => _expectRemoteSourcesHashed(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'file',
            'url': 'https://example.invalid/sqlite.tar.gz',
          },
        ],
        'fixture',
      ),
      throwsA(anything),
    );
  });

  test('network grant outside runtime finish args is rejected', () {
    const String manifest = '''
finish-args:
  - --share=network
modules:
  - name: native
    build-options:
      build-args:
        - --share=network
''';

    expect(
      () => _expectNoBuildNetworkGrant(manifest),
      throwsA(anything),
    );
  });
}
