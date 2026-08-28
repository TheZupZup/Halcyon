import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Guards active/current Linthra license declarations against metadata drift.
///
/// Historical releases and docs/licenses/MPL-2.0.txt intentionally remain MPL.
void main() {
  const String current = 'AGPL-3.0-or-later';
  const String agpl = 'GNU AFFERO GENERAL PUBLIC LICENSE';
  const String mpl = 'Mozilla Public License Version 2.0';
  const String storeLicense = 'GNU Affero General Public License v3.0 or later';
  final String root = _repoRoot();

  late String license;
  late String fdroid;
  late String cargo;
  late String about;
  late String readme;
  late String contributing;
  late String fastlane;
  late String historical;

  setUpAll(() {
    license = _read(root, 'LICENSE');
    fdroid = _read(root, 'metadata/io.github.thezupzup.linthra.yml');
    cargo = _read(root, 'native/linthra_core/Cargo.toml');
    about = _read(root, 'lib/features/settings/hub/about_screen.dart');
    readme = _read(root, 'README.md');
    contributing = _read(root, 'CONTRIBUTING.md');
    const String storeDir = 'fastlane/metadata/android/en-US';
    const String storeFile = 'full_description.txt';
    fastlane = _read(root, '$storeDir/$storeFile');
    historical = _read(root, 'docs/licenses/MPL-2.0.txt');
  });

  test('F-Droid metadata keeps the current license', () {
    expect(_hasLine(fdroid, 'License: $current'), isTrue);
  });

  test('Rust metadata keeps the current license', () {
    expect(_hasLine(cargo, 'license = "$current"'), isTrue);
  });

  test('About exposes the current license', () {
    expect(about, contains('License ($current)'));
    expect(about, isNot(contains('License (MPL-2.0)')));
  });

  test('README and contribution terms keep the current license', () {
    expect(readme, contains('[$current](./LICENSE)'));
    expect(readme, contains('License: $current'));
    expect(contributing, contains('[$current](./LICENSE)'));
  });

  test('Android store metadata names the GNU AGPL', () {
    expect(fastlane, contains(storeLicense));
  });

  test('top-level LICENSE is AGPLv3', () {
    expect(license, contains(agpl));
    expect(license, contains('Version 3, 19 November 2007'));
    expect(license, contains('Remote Network Interaction'));
    expect(license, isNot(contains(mpl)));
  });

  test('historical MPL-2.0 text remains preserved', () {
    expect(historical, contains(mpl));
    expect(historical, isNot(contains(agpl)));
  });
}

bool _hasLine(String text, String expected) {
  int count = 0;
  for (final String line in text.split('\n')) {
    if (line.trimRight() == expected) {
      count++;
    }
  }
  return count == 1;
}

String _read(String root, String relativePath) {
  final File file = File(p.join(root, relativePath));
  expect(file.existsSync(), isTrue, reason: 'Missing $relativePath');
  return file.readAsStringSync();
}

String _repoRoot() {
  Directory directory = Directory.current;
  while (true) {
    final File pubspec = File(p.join(directory.path, 'pubspec.yaml'));
    final Directory metadata = Directory(p.join(directory.path, 'metadata'));
    if (pubspec.existsSync() && metadata.existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    directory = parent;
  }
}
