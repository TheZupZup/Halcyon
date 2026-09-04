import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String workflow;

  setUpAll(() {
    workflow = File(
      '.github/workflows/flatpak-build.yml',
    ).readAsStringSync();
  });

  test('Flatpak CI stays read-only and fork-safe', () {
    expect(workflow, contains('permissions:\n  contents: read'));
    expect(workflow, isNot(contains(r'secrets.')));
    expect(workflow, isNot(contains('contents: write')));
  });

  test('Flatpak CI does not depend on a restored build cache', () {
    expect(workflow, isNot(contains('actions/cache@')));
    expect(workflow, contains('--disable-cache'));
    expect(workflow, contains('--force-clean'));
  });

  test(
    'Flatpak CI installs manifest dependencies and builds the real package',
    () {
      expect(workflow, contains('--install-deps-from=flathub'));
      expect(workflow, contains('--install-deps-only'));
      expect(workflow, contains('--repo=repo-ci'));
      expect(workflow, contains('io.github.thezupzup.linthra.yml'));
      expect(workflow, contains('flatpak build-update-repo repo-ci'));
    },
  );

  // The job installs its host tools with --no-install-recommends, so anything a
  // dependency merely recommends has to be named explicitly. elfutils is the
  // one that bit: flatpak-builder only recommends it, and without its `eu-strip`
  // the build dies on the first native module, long before Linthra is reached.
  test('Flatpak CI installs the host tools the build and smoke need', () {
    for (final String package in <String>[
      // appstreamcli, for the metainfo validation step.
      'appstream',
      // desktop-file-validate, for the desktop entry.
      'desktop-file-utils',
      // eu-strip / eu-elfcompress, which flatpak-builder uses to split debug
      // symbols out of every module it builds.
      'elfutils',
      'flatpak-builder',
      // xwininfo and xprop, which the launch smoke reads window identity with.
      'x11-utils',
      // The headless display and session bus the smoke launches into.
      'xvfb',
      'dbus-x11',
    ]) {
      // Either a continuation line or the last entry of the list.
      expect(
        workflow,
        anyOf(
          contains('            $package \\\n'),
          contains('            $package\n'),
        ),
        reason: 'Missing host package: $package',
      );
    }
  });

  test('packaging-relevant changes trigger the workflow', () {
    for (final String path in <String>[
      "'flatpak/**'",
      "'linux/packaging/**'",
      "'linux/CMakeLists.txt'",
      "'linux/runner/**'",
      "'pubspec.lock'",
      "'.flutter-version'",
      "'third_party/**'",
      "'tool/branding/linthra_icon.svg'",
    ]) {
      expect(workflow, contains(path), reason: 'Missing trigger path: $path');
    }
  });
}
