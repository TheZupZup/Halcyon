/// Parses the Linux XDG "user dirs" config format — `user-dirs.dirs`, as
/// written by `xdg-user-dirs-update` — to resolve `XDG_MUSIC_DIR`, without
/// ever invoking a shell.
///
/// The format `xdg-user-dirs-update` itself writes is a small set of
/// `KEY="value"` lines, where `value` is either `$HOME/relative/path` or an
/// absolute `/path`, e.g.:
///
/// ```text
/// XDG_MUSIC_DIR="$HOME/Music"
/// ```
///
/// This class only understands those two literal forms (see [_expand]), so it
/// can resolve `$HOME` with a plain string substitution instead of a shell —
/// a value like `XDG_MUSIC_DIR="$(rm -rf ~)"` is just unmatched text, never
/// executed. Anything outside those two forms (an unquoted value, `~`
/// shorthand, a missing key, a truncated line, ...) is treated as unusable and
/// yields `null`; this class has no opinion on what "unusable" should fall
/// back to — that's the resolver built on top of it (`LinuxMusicDirectory`).
class XdgUserDirs {
  const XdgUserDirs._();

  static final RegExp _musicDirLine = RegExp(
    r'^\s*XDG_MUSIC_DIR\s*=\s*"([^"]*)"\s*$',
  );

  /// Resolves `XDG_MUSIC_DIR` from the raw contents of a `user-dirs.dirs`
  /// file. Returns the expanded absolute path, or `null` when the file has no
  /// such entry, or the entry isn't in one of the two forms `xdg-user-dirs`
  /// itself writes.
  ///
  /// [home] is substituted for the literal `$HOME` token; it is never read
  /// from the environment by this class (see the resolver above it for that).
  static String? resolveMusicDirectory(
    String userDirsFileContents, {
    required String home,
  }) {
    for (final String line
        in userDirsFileContents.split(RegExp(r'\r\n|\r|\n'))) {
      final RegExpMatch? match = _musicDirLine.firstMatch(line);
      if (match == null) continue;
      return _expand(match.group(1)!, home: home);
    }
    return null;
  }

  /// Expands the two value forms `xdg-user-dirs` writes with plain string
  /// operations: `$HOME` alone (the "disabled" form — see
  /// [LinuxMusicDirectory]), `$HOME/...`, and an absolute `/...` path. Any
  /// other shape is rejected rather than guessed at.
  static String? _expand(String rawValue, {required String home}) {
    const String homeToken = r'$HOME';
    if (rawValue == homeToken) {
      return home;
    }
    if (rawValue.startsWith('$homeToken/')) {
      return home + rawValue.substring(homeToken.length);
    }
    if (rawValue.startsWith('/')) {
      return rawValue;
    }
    return null;
  }
}
