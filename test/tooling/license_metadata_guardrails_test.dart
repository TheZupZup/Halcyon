import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Cross-file guardrails for Linthra's active project license.
///
/// Historical releases and `docs/licenses/MPL-2.0.txt` intentionally keep
/// MPL-2.0 references. These tests only pin active/current license surfaces.
void main() {
  const String currentLicense = 'AGPL-3.0-or-later';
  const String agplTitle = 'GNU AFFERO GENERAL PUBLIC LICENSE';
  const String mplTitle = 'Mozilla Public License Version 2.0';
  final String root = _repoRoot();

  late String licenseText;
  late String fdroidMetadata;
  late String cargoToml;
  late String aboutScreen;
  late String readme;
  late String contributing;
  late String fastlaneDescription;
  late String historicalMpl;

  setUpAll(() {
    licenseText = _read(root, 'LICENSE');
    fdroidMetadata =
        _read(root, 'metadata/io.github.thezupzup.linthra.yml');
    cargoToml = _read(root, 'native/linthra_core/Cargo.toml');
    aboutScreen = _read(root, 'lib/features/settings/hub/about_screen.dart');
    readme = _read(root, 'README.md');
    contributing = _read(root, 'CONTRIBUTING.md');
    fastlaneDescription =
        _read(root, 'fastlane/metadata/android/en-US/full_description.txt');
    historicalMpl = _read(root, 'docs/licenses/MPL-2.0.txt');
  });

  group('active Linthra license metadata', () {
    test('F-Droid metadata declares AGPL-3.0-or-later exactly once', () {
      final RegExp pattern = RegExp(
        r'^License:\s*(\S+)\s*$',
        multiLine: true,
      );
      final List<RegExpMatch> matches =
          pattern.allMatches(fdroidMetadata).toList();

      expect(matches, hasLength(1));
      expect(matches.single.group(1), currentLicense);
    });

    test('Rust core metadata declares AGPL-3.0-or-later', () {
      final RegExp pattern = RegExp(
        r'^license\s*=\s*"([^"]+)"\s*$',
        multiLine: true,
      );
      final RegExpMatch? match = pattern.firstMatch(cargoToml);

      expect(match, isNotNull);
      expect(match!.group(1), currentLicense);
    });

    test('About screen exposes the current license', () {
      expect(aboutScreen, contains('License ($currentLicense)'));
      expect(aboutScreen, isNot(contains('License (MPL-2.0)')));
    });

    test('README and contribution terms point to the current license', () {
      expect(readme, contains('[$currentLicense](./LICENSE)'));
      expect(readme, contains('License: $currentLicense'));
      expect(contributing, contains('[$currentLicense](./LICENSE)'));
    });

    test('Android store metadata names the GNU AGPL', () {
      expect(
        fastlaneDescription,
        contains('GNU Affero General Public License v3.0 or later'),
      );
    });
  });

  group('license texts', () {
    test('top-level LICENSE is GNU AGPLv3, not MPL-2.0', () {
      expect(licenseText, contains(agplTitle));
      expect(licenseText, contains('Version 3, 19 November 2007'));
      expect(licenseText, contains('Remote Network Interaction'));
      expect(licenseText, isNot(contains(mplTitle)));
    });

    test('historical MPL-2.0 text remains preserved separately', () {
      expect(historicalMpl, contains(mplTitle));
      expect(historicalMpl, isNot(contains(agplTitle)));
    });
  });
}

String _read(String root, String relativePath) {
  final File file = File(p.join(root, relativePath));
  expect(file.existsSync(), isTrue, reason: 'Missing $relativePath');
  return file.readAsStringSync();
}

String _repoRoot() {
  Directory directory = Directory.current;
  while (true) {
    if (File(p.join(directory.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(directory.path, 'metadata')).existsSync()) {
      return directory.path;
    }

    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    directory = parent;
  }
}
