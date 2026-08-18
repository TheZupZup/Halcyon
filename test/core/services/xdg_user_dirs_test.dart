import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/xdg_user_dirs.dart';

void main() {
  group('XdgUserDirs.resolveMusicDirectory', () {
    const home = '/home/alex';

    test('resolves the stock XDG_MUSIC_DIR="\$HOME/Music" entry', () {
      const contents = '''
# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_MUSIC_DIR="\$HOME/Music"
XDG_PICTURES_DIR="\$HOME/Pictures"
''';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        '/home/alex/Music',
      );
    });

    test('resolves a localized directory name', () {
      const contents = 'XDG_MUSIC_DIR="\$HOME/Musique"';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        '/home/alex/Musique',
      );
    });

    test('resolves a directory name containing spaces', () {
      const contents = 'XDG_MUSIC_DIR="\$HOME/My Music"';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        '/home/alex/My Music',
      );
    });

    test('resolves a directory name containing non-ASCII characters', () {
      const contents = 'XDG_MUSIC_DIR="\$HOME/Música 音楽"';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        '/home/alex/Música 音楽',
      );
    });

    test('resolves an absolute-path value unchanged', () {
      const contents = 'XDG_MUSIC_DIR="/mnt/music"';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        '/mnt/music',
      );
    });

    test('resolves the disabled form (pointing at \$HOME itself)', () {
      const contents = 'XDG_MUSIC_DIR="\$HOME"';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        home,
      );
    });

    test('returns null when the file has no XDG_MUSIC_DIR entry', () {
      const contents = '''
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_DOWNLOAD_DIR="\$HOME/Downloads"
''';
      expect(XdgUserDirs.resolveMusicDirectory(contents, home: home), isNull);
    });

    test('returns null for an empty file', () {
      expect(XdgUserDirs.resolveMusicDirectory('', home: home), isNull);
    });

    test('returns null for an unquoted value', () {
      const contents = r'XDG_MUSIC_DIR=$HOME/Music';
      expect(XdgUserDirs.resolveMusicDirectory(contents, home: home), isNull);
    });

    test('returns null for a value using ~ instead of \$HOME', () {
      const contents = 'XDG_MUSIC_DIR="~/Music"';
      expect(XdgUserDirs.resolveMusicDirectory(contents, home: home), isNull);
    });

    test('returns null for a truncated (unterminated-quote) line', () {
      const contents = 'XDG_MUSIC_DIR="\$HOME/Music';
      expect(XdgUserDirs.resolveMusicDirectory(contents, home: home), isNull);
    });

    test('returns null for a relative value with no \$HOME prefix', () {
      const contents = 'XDG_MUSIC_DIR="Music"';
      expect(XdgUserDirs.resolveMusicDirectory(contents, home: home), isNull);
    });

    // Regression guard for "no shell evaluation": a shell command substitution
    // embedded in the value must be treated as ordinary unmatched text (and so
    // rejected, since it isn't the documented `$HOME/...` or `/...` form), never
    // executed or passed to a shell.
    test('never evaluates shell content embedded in the value', () {
      const contents = r'XDG_MUSIC_DIR="$(touch /tmp/xdg-user-dirs-pwned)"';
      expect(XdgUserDirs.resolveMusicDirectory(contents, home: home), isNull);
    });

    test('is tolerant of surrounding whitespace and other entries', () {
      const contents = '''
XDG_DOWNLOAD_DIR="\$HOME/Downloads"
   XDG_MUSIC_DIR="\$HOME/Music"
XDG_VIDEOS_DIR="\$HOME/Videos"
''';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        '/home/alex/Music',
      );
    });

    test('handles Windows-style line endings', () {
      const contents = 'XDG_DESKTOP_DIR="\$HOME/Desktop"\r\n'
          'XDG_MUSIC_DIR="\$HOME/Music"\r\n';
      expect(
        XdgUserDirs.resolveMusicDirectory(contents, home: home),
        '/home/alex/Music',
      );
    });
  });
}
