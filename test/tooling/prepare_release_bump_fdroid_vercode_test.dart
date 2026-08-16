import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final String repoRoot = _findRepoRoot();
  final String script = p.join(repoRoot, 'scripts', 'prepare_release_bump.py');

  test('release bump records the highest F-Droid split versionCode', () async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('linthra_fdroid_vercode_');
    addTearDown(() async => tmp.delete(recursive: true));

    Directory(p.join(tmp.path, 'lib', 'core')).createSync(recursive: true);
    Directory(p.join(
      tmp.path,
      'fastlane',
      'metadata',
      'android',
      'en-US',
      'changelogs',
    )).createSync(recursive: true);
    Directory(p.join(tmp.path, 'metadata')).createSync(recursive: true);

    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      'name: linthra\nversion: 0.2.1+201999\n',
    );
    File(p.join(tmp.path, 'lib', 'core', 'app_info.dart')).writeAsStringSync(
      "abstract final class AppInfo {\n"
      "  static const String _devVersionName = '0.2.1';\n"
      "}\n",
    );
    final File metadata =
        File(p.join(tmp.path, 'metadata', 'io.github.thezupzup.linthra.yml'));
    metadata.writeAsStringSync(
      'Name: Linthra\n'
      'CurrentVersion: 0.2.1\n'
      'CurrentVersionCode: 2019993\n'
      'VercodeOperation:\n'
      '  - "%c*10 + 1"\n'
      '  - "%c*10 + 2"\n'
      '  - "%c*10 + 3"\n'
      'Builds:\n'
      '  - versionName: 0.2.1\n'
      '    versionCode: 2019991\n',
    );

    final ProcessResult result = Process.runSync(
      'python3',
      <String>[
        script,
        '0.2.2',
        '--repo-root',
        tmp.path,
        '--changelog',
        'Linthra 0.2.2 test changelog.',
      ],
    );

    expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );

    final String after = metadata.readAsStringSync();
    expect(after, contains('CurrentVersion: 0.2.2'));
    expect(after, contains('CurrentVersionCode: 2029993'));
    expect(after, contains('  - "%c*10 + 1"'));
    expect(after, contains('  - "%c*10 + 2"'));
    expect(after, contains('  - "%c*10 + 3"'));
    expect(after, contains('versionName: 0.2.1'));
    expect(after, contains('versionCode: 2019991'));
  });

  test('unsupported F-Droid version-code expressions fail safely', () async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('linthra_fdroid_vercode_bad_');
    addTearDown(() async => tmp.delete(recursive: true));

    Directory(p.join(tmp.path, 'lib', 'core')).createSync(recursive: true);
    Directory(p.join(
      tmp.path,
      'fastlane',
      'metadata',
      'android',
      'en-US',
      'changelogs',
    )).createSync(recursive: true);
    Directory(p.join(tmp.path, 'metadata')).createSync(recursive: true);

    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      'name: linthra\nversion: 0.2.1+201999\n',
    );
    File(p.join(tmp.path, 'lib', 'core', 'app_info.dart')).writeAsStringSync(
      "abstract final class AppInfo {\n"
      "  static const String _devVersionName = '0.2.1';\n"
      "}\n",
    );
    File(p.join(tmp.path, 'metadata', 'io.github.thezupzup.linthra.yml'))
        .writeAsStringSync(
      'Name: Linthra\n'
      'CurrentVersion: 0.2.1\n'
      'CurrentVersionCode: 2019993\n'
      'VercodeOperation:\n'
      '  - "%c**2"\n',
    );

    final ProcessResult result = Process.runSync(
      'python3',
      <String>[
        script,
        '0.2.2',
        '--repo-root',
        tmp.path,
        '--changelog',
        'Linthra 0.2.2 test changelog.',
      ],
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Unsupported F-Droid VercodeOperation'));
    expect(result.stderr, contains('refusing to guess CurrentVersionCode'));
  });
}

String _findRepoRoot() {
  Directory d = Directory.current;
  while (true) {
    if (File(p.join(d.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(d.path, 'scripts')).existsSync()) {
      return d.path;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    d = parent;
  }
}
