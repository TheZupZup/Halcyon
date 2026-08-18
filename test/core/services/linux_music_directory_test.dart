import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/linux_music_directory.dart';
import 'package:path/path.dart' as p;

void main() {
  group('LinuxMusicDirectory.resolve', () {
    late Directory tempHome;
    const resolver = LinuxMusicDirectory();

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('linthra-xdg-home-');
    });

    tearDown(() {
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    /// Writes `~/.config/user-dirs.dirs` with [contents] and creates
    /// [musicDirName] (when given) under the temp home so an existence check
    /// finds a real directory, mirroring a genuine XDG setup.
    Future<void> writeUserDirs(
      String contents, {
      String? musicDirName,
    }) async {
      final Directory configDir = Directory(p.join(tempHome.path, '.config'))
        ..createSync(recursive: true);
      File(p.join(configDir.path, 'user-dirs.dirs'))
          .writeAsStringSync(contents);
      if (musicDirName != null) {
        Directory(p.join(tempHome.path, musicDirName)).createSync();
      }
    }

    Map<String, String> envFor(
      Directory home, {
      String? xdgConfigHome,
    }) {
      return {
        'HOME': home.path,
        if (xdgConfigHome != null) 'XDG_CONFIG_HOME': xdgConfigHome,
      };
    }

    test('resolves XDG_MUSIC_DIR="\$HOME/Music"', () async {
      await writeUserDirs(
        'XDG_MUSIC_DIR="\$HOME/Music"',
        musicDirName: 'Music',
      );

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, p.join(tempHome.path, 'Music'));
    });

    test('resolves a localized directory such as "\$HOME/Musique"', () async {
      await writeUserDirs(
        'XDG_MUSIC_DIR="\$HOME/Musique"',
        musicDirName: 'Musique',
      );

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, p.join(tempHome.path, 'Musique'));
    });

    test('resolves a directory containing spaces', () async {
      await writeUserDirs(
        'XDG_MUSIC_DIR="\$HOME/My Music"',
        musicDirName: 'My Music',
      );

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, p.join(tempHome.path, 'My Music'));
    });

    test('resolves a directory containing non-ASCII characters', () async {
      const dirName = 'Música 音楽';
      await writeUserDirs(
        'XDG_MUSIC_DIR="\$HOME/$dirName"',
        musicDirName: dirName,
      );

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, p.join(tempHome.path, dirName));
    });

    test('falls back to null when user-dirs.dirs is missing', () async {
      // No writeUserDirs() call — ~/.config/user-dirs.dirs doesn't exist.
      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, isNull);
    });

    test('falls back to null when XDG_MUSIC_DIR is missing from the file',
        () async {
      await writeUserDirs('XDG_DESKTOP_DIR="\$HOME/Desktop"');

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, isNull);
    });

    test('falls back to null for a malformed value', () async {
      await writeUserDirs(r'XDG_MUSIC_DIR=$HOME/Music'); // unquoted

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, isNull);
    });

    test(
        'falls back to null when the entry is disabled (XDG_MUSIC_DIR="\$HOME")',
        () async {
      await writeUserDirs('XDG_MUSIC_DIR="\$HOME"');

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, isNull);
    });

    test('falls back to null when the resolved directory does not exist',
        () async {
      // Entry present and well-formed, but nothing was created on disk for it.
      await writeUserDirs('XDG_MUSIC_DIR="\$HOME/Music"');

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, isNull);
    });

    test('falls back to null when \$HOME is not set', () async {
      await writeUserDirs(
        'XDG_MUSIC_DIR="\$HOME/Music"',
        musicDirName: 'Music',
      );

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: const {},
      );

      expect(result, isNull);
    });

    test('honours XDG_CONFIG_HOME when set, instead of ~/.config', () async {
      final Directory customConfigParent =
          Directory.systemTemp.createTempSync('linthra-xdg-config-');
      addTearDown(() {
        if (customConfigParent.existsSync()) {
          customConfigParent.deleteSync(recursive: true);
        }
      });
      final String customConfigHome =
          p.join(customConfigParent.path, 'xdg-config');
      Directory(customConfigHome).createSync(recursive: true);
      File(p.join(customConfigHome, 'user-dirs.dirs'))
          .writeAsStringSync('XDG_MUSIC_DIR="\$HOME/Music"');
      Directory(p.join(tempHome.path, 'Music')).createSync();

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome, xdgConfigHome: customConfigHome),
      );

      expect(result, p.join(tempHome.path, 'Music'));
    });

    test(
        'ignores a stray ~/.config/user-dirs.dirs when XDG_CONFIG_HOME '
        'points elsewhere', () async {
      // ~/.config has a usable entry, but XDG_CONFIG_HOME redirects to a
      // directory with no user-dirs.dirs at all — that redirection must win.
      await writeUserDirs(
        'XDG_MUSIC_DIR="\$HOME/Music"',
        musicDirName: 'Music',
      );
      final Directory emptyConfigParent =
          Directory.systemTemp.createTempSync('linthra-xdg-empty-config-');
      addTearDown(() {
        if (emptyConfigParent.existsSync()) {
          emptyConfigParent.deleteSync(recursive: true);
        }
      });

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome, xdgConfigHome: emptyConfigParent.path),
      );

      expect(result, isNull);
    });

    test('never touches a shell or process to resolve the value', () async {
      // No `Process` is ever started by the resolver; a value that looks like
      // a shell command substitution just fails to match the supported forms
      // and is rejected, rather than being executed.
      final String marker =
          p.join(tempHome.path, 'xdg-user-dirs-should-not-run');
      await writeUserDirs('XDG_MUSIC_DIR="\$(touch $marker)"');

      final result = await resolver.resolve(
        host: HostPlatform.linux,
        environment: envFor(tempHome),
      );

      expect(result, isNull);
      expect(File(marker).existsSync(), isFalse);
    });

    for (final host in [
      HostPlatform.android,
      HostPlatform.macOS,
      HostPlatform.windows,
      HostPlatform.ios,
      HostPlatform.other,
    ]) {
      test('is a no-op off Linux (${host.label})', () async {
        await writeUserDirs(
          'XDG_MUSIC_DIR="\$HOME/Music"',
          musicDirName: 'Music',
        );

        final result = await resolver.resolve(
          host: host,
          environment: envFor(tempHome),
        );

        expect(result, isNull);
      });
    }

    test(
        'an explicit Linux host never disagrees with the real host on a '
        'non-Linux test runner', () async {
      // Guards the injection itself, mirroring the pattern used for
      // PlatformFolderPickerService: passing the real platform must behave
      // identically to passing nothing.
      await writeUserDirs(
        'XDG_MUSIC_DIR="\$HOME/Music"',
        musicDirName: 'Music',
      );
      final env = envFor(tempHome);

      final withExplicitHost =
          await resolver.resolve(host: HostPlatform.current, environment: env);
      final withDefaultHost = await resolver.resolve(environment: env);

      expect(withExplicitHost, withDefaultHost);
    });
  });
}
