import '../platform/host_platform.dart';
import '../repositories/download_repository.dart';
import '../repositories/favorites_repository.dart';
import '../repositories/music_library_repository.dart';
import '../repositories/playlist_repository.dart';
import 'linthra_audio_handler.dart';
import 'media_artwork_source.dart';
import 'playback_controller.dart';

/// Attaches Linthra's playback to the platform's media session — the thing that
/// draws the notification / lock-screen controls and answers Android Auto.
///
/// The session is a *platform integration*, not a playback engine: whether one
/// exists says nothing about whether audio can play. Android has one
/// (`audio_service`, behind [LinthraAudioHandler]); Linux has none yet, and
/// MPRIS — the desktop equivalent — is a later PR.
///
/// The seam exists so startup can ask for a session without knowing which
/// platform it is on, and so the Android-only plugin is never *touched* on a
/// platform that has no implementation for it. Calling into `audio_service` off
/// Android does not merely fail; it fails after `AudioService.init` has already
/// half-configured its statics (it builds a cache manager and installs handler
/// callbacks before the first platform call throws), which is the kind of
/// half-initialised state that is easy to trip over later.
abstract interface class MediaSessionBinding {
  /// Whether this platform has a media session Linthra can attach to. Read by
  /// diagnostics; startup does not need to branch on it.
  bool get isSupported;

  /// Attaches the session, returning whether one is now live.
  ///
  /// Best-effort and never throws: a platform without the native setup (or a
  /// test host with no bindings) reports `false` and the app carries on. The
  /// repositories are what Android Auto browses; they are ignored where there
  /// is no session.
  Future<bool> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
  });
}

/// The Android media session, backed by `audio_service`.
///
/// A thin wrapper over [connectMediaSession] so the `audio_service` import stays
/// confined to [LinthraAudioHandler]'s file and this one line of routing.
class AudioServiceMediaSessionBinding implements MediaSessionBinding {
  const AudioServiceMediaSessionBinding();

  @override
  bool get isSupported => true;

  @override
  Future<bool> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
  }) async {
    final LinthraAudioHandler? handler = await connectMediaSession(
      controller,
      library,
      playlists: playlists,
      favorites: favorites,
      downloads: downloads,
      artwork: artwork,
    );
    return handler != null;
  }
}

/// The explicit "this platform has no media session" binding.
///
/// Used on Linux (and every other desktop) until MPRIS lands. It is deliberately
/// a real, named class rather than a silent `if`: an inert session is a fact
/// about the platform that diagnostics can report and tests can assert on, and
/// it makes the missing desktop integration visible in the code instead of
/// implied by its absence.
class UnsupportedMediaSessionBinding implements MediaSessionBinding {
  const UnsupportedMediaSessionBinding();

  @override
  bool get isSupported => false;

  @override
  Future<bool> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
  }) async =>
      false;
}

/// The default [MediaSessionBinding]: the real `audio_service` session on
/// Android, an inert one everywhere else.
///
/// This is the one place that knows about the platform split, mirroring
/// `PlatformShareService` and `PlatformFolderPickerService`. The Android
/// delegate is only ever *reached* on Android, so `audio_service` cannot
/// initialise on a platform that has no implementation for it.
class PlatformMediaSessionBinding implements MediaSessionBinding {
  const PlatformMediaSessionBinding({
    HostPlatform? host,
    MediaSessionBinding androidBinding =
        const AudioServiceMediaSessionBinding(),
    MediaSessionBinding fallbackBinding =
        const UnsupportedMediaSessionBinding(),
  })  : _host = host,
        _androidBinding = androidBinding,
        _fallbackBinding = fallbackBinding;

  // Null means "read the real host". Resolved lazily rather than in the
  // initialiser list so the class stays const-constructible.
  final HostPlatform? _host;
  final MediaSessionBinding _androidBinding;
  final MediaSessionBinding _fallbackBinding;

  MediaSessionBinding get _delegate => (_host ?? HostPlatform.current).isAndroid
      ? _androidBinding
      : _fallbackBinding;

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<bool> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
  }) =>
      _delegate.attach(
        controller,
        library,
        playlists: playlists,
        favorites: favorites,
        downloads: downloads,
        artwork: artwork,
      );
}
