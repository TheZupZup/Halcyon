import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Cross-file guardrails for Linthra's active project license.
///
/// Historical releases and `docs/licenses/MPL-2.0.txt` intentionally keep
/// MPL-2.0 references. These tests only pin the surfaces that describe the
/// license of the current Linthra source tree, so a future metadata or UI edit
/// cannot silently drift one distribution channel back to MPL-2.0.
void main() {
  const String currentLicense = 'AGPL-3.0-or-later';
  final String root = _repoRoot();

  late String licenseText;
  late String fdroidMetadata;
  late String cargoToml;
  late String aboutScreen;
  late String readme;
  late String fastlaneDescription;
  late String historicalMpl;

  setUpAll(() {
    licenseText = _read(p.join(root, 'LICENSE'));
    fdroidMetadata =
        _read(p.join(root, 'metadata', 'io.github.thezupzup.linthra.yml'));
    cargoToml = _read(p.join(root, 'native', 'linthra_core', 'Cargo.toml'));
    aboutScreen = _read(
      p.join(root, 'lib', 'features', 'settings', 'hub', 'about_screen.dart'),
    );
    readme = _read(p.join(root, 'README.md'));
    fastlaneDescription = _read(p.join(
      root,
      'fastlane',
      'metadata',
      'android',
      'en-US',
      'full_description.txt',
    ));
    historicalMpl =
        _read(p.join(root, 'docs', 'licenses', 'MPL-2.0.txt'));
  });

  group('active Linthra license metadata', () {
    test('F-Droid metadata declares AGPL-3.0-or-later exactly once', () {
      final List<RegExpMatch> matches = RegExp(
        r'^License:\s*(\S+)\s*$',
        multiLine: true,
      ).allMatches(fdroidMetadata).toList();

      expect(
        matches,
        hasLength(1),
        reason: 'F-Droid metadata must have one unambiguous top-level License.',
      );
      expect(matches.single.group(1), currentLicense);
    });

    test('Rust core metadata declares AGPL-3.0-or-later', () {
      final RegExpMatch? match = RegExp(
        r'^license\s*=\s*"([^"]+)"\s*$',
        multiLine: true,
      ).firstMatch(cargoToml);

      expect(match, isNotNull, reason: 'Cargo.toml must declare a license.');
      expect(match!.group(1), currentLicense);
    });

    test('About screen exposes the current license, not MPL-2.0', () {
      expect(aboutScreen, contains('License ($currentLicense)'));
      expect(aboutScreen, isNot(contains('License (MPL-2.0)')));
    });

    test('README and Android store text describe the current AGPL license', () {
      expect(readme, contains('[AGPL-3.0-or-later](./LICENSE)'));
      expect(readme, contains('License: AGPL-3.0-or-later'));
      expect(
        fastlaneDescription,
        contains('GNU Affero General Public License v3.0 or later'),
      );
    });
  });

  group('license texts', () {
    test('top-level LICENSE is GNU AGPLv3, not the historical MPL text', () {
      expect(licenseText, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
      expect(licenseText, contains('Version 3, 19 November 2007'));
      expect(
        licenseText,
        contains(
          '13. Remote Network Interaction; Use with the GNU General Public License.',
        ),
      );
      expect(
        licenseText,
        isNot(contains('Mozilla Public License Version 2.0')),
      );
    });

    test('historical MPL-2.0 text remains preserved separately', () {
      expect(historicalMpl, contains('Mozilla Public License Version 2.0'));
      expect(
        historicalMpl,
        isNot(contains('GNU AFFERO GENERAL PUBLIC LICENSE')),
      );
    });
  });
}

String _read(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue, reason: 'Expected file is missing: $path');
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
