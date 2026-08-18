import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/host_platform.dart';
import 'xdg_user_dirs.dart';

/// Resolves the Linux XDG Music directory (`$XDG_MUSIC_DIR`) to *suggest* as
/// the starting folder in the desktop folder chooser — this never scans a
/// folder itself, and the user remains free to navigate anywhere else in the
/// chooser.
///
/// Reads `user-dirs.dirs` the way `xdg-user-dirs-update` writes it (via
/// [XdgUserDirs]) instead of assuming `~/Music`, so a localized or
/// user-renamed Music directory (`~/Musique`, `~/My Music`, a directory with
/// non-ASCII characters, ...) is suggested correctly. No shell is ever
/// invoked — the config file is read and parsed as plain text.
///
/// Resolution fails safe to `null` — "suggest nothing, let the chooser fall
/// back to its own default" — whenever the result can't be trusted: off
/// Linux, no `$HOME` in the environment, no config file, no `XDG_MUSIC_DIR`
/// entry, a value in a form `xdg-user-dirs` doesn't itself write, the entry
/// disabled (pointing at `$HOME` itself — `xdg-user-dirs`'s own way of saying
/// "no separate Music folder"), or a resolved directory that doesn't actually
/// exist.
class LinuxMusicDirectory {
  const LinuxMusicDirectory();

  /// Resolves the current user's Music directory, or `null` per the class doc
  /// above.
  ///
  /// [host] and [environment] are injection points for tests, defaulting to
  /// the real host platform and process environment; the running app never
  /// passes them.
  Future<String?> resolve({
    HostPlatform? host,
    Map<String, String>? environment,
  }) async {
    if ((host ?? HostPlatform.current) != HostPlatform.linux) {
      return null;
    }
    final Map<String, String> env = environment ?? Platform.environment;
    final String? home = _nonEmpty(env['HOME']);
    if (home == null) {
      return null;
    }

    final String configHome =
        _nonEmpty(env['XDG_CONFIG_HOME']) ?? p.join(home, '.config');
    final File userDirsFile = File(p.join(configHome, 'user-dirs.dirs'));

    final String? contents = await _readIfExists(userDirsFile);
    if (contents == null) {
      return null;
    }

    final String? resolved =
        XdgUserDirs.resolveMusicDirectory(contents, home: home);
    if (resolved == null) {
      return null;
    }
    // Disabled: xdg-user-dirs represents "no separate Music dir" by pointing
    // the entry at $HOME itself. Suggesting the whole home directory as a
    // music folder default would be worse than suggesting nothing.
    if (p.equals(resolved, home)) {
      return null;
    }
    if (!Directory(resolved).existsSync()) {
      return null;
    }
    return resolved;
  }

  static Future<String?> _readIfExists(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}
