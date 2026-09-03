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

  test('Flatpak CI installs manifest dependencies and builds the real package', () {
    expect(workflow, contains('--install-deps-from=flathub'));
    expect(workflow, contains('--install-deps-only'));
    expect(workflow, contains('--repo=repo-ci'));
    expect(workflow, contains('io.github.thezupzup.linthra.yml'));
    expect(workflow, contains('flatpak build-update-repo repo-ci'));
  });

  test('packaging-relevant changes trigger the workflow', () {
    for (final String path in <String>[
      "'flatpak/**'",
      "'linux/packaging/**'",
      "'linux/CMakeLists.txt'",
      "'pubspec.lock'",
      "'.flutter-version'",
      "'third_party/**'",
    ]) {
      expect(workflow, contains(path), reason: 'Missing trigger path: $path');
    }
  });
}
