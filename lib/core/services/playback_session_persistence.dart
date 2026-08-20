import 'dart:async';
import 'dart:io' show File;

import '../models/persisted_playback_session.dart';
import '../models/playback_state.dart';
import '../models/track.dart';
import '../repositories/playback_session_store.dart';
import '../sources/music_provider.dart';
import 'local_playback_controller.dart';

/// Persists logical playback state across unexpected process restarts and
/// restores it as a **paused** queue on the next launch.
///
/// Writes only [PersistedPlaybackSession] documents (logical track identity,
/// modes, position) — never stream URLs or tokens. On restore, remote tracks
/// are loaded through the engine's normal resolver path and [autoplay] stays
/// off so a crash/restart never blasts audio. Invalid/stale rows are dropped;
/// a wholly unusable record is cleared and never blocks startup.
class PlaybackSessionPersistence {
  PlaybackSessionPersistence({
    required PlaybackSessionStore store,
    required LocalPlaybackController controller,
    required Stream<PlaybackState> playbackStates,
    bool Function(MusicProvider provider)? isRemoteProviderAvailable,
    bool Function(String localUri)? localFileExists,
    Duration positionSaveInterval = const Duration(seconds: 2),
  })  : _store = store,
        _controller = controller,
        _isRemoteProviderAvailable = isRemoteProviderAvailable,
        _localFileExists = localFileExists ?? _defaultLocalFileExists,
        _positionSaveInterval = positionSaveInterval {
    _subscription = playbackStates.listen(_onPlaybackState);
  }

  final PlaybackSessionStore _store;
  final LocalPlaybackController _controller;
  final bool Function(MusicProvider provider)? _isRemoteProviderAvailable;
  final bool Function(String localUri) _localFileExists;
  final Duration _positionSaveInterval;

  StreamSubscription<PlaybackState>? _subscription;
  Timer? _positionTimer;
  PlaybackState? _lastPersisted;
  bool _restoring = false;
  bool _disposed = false;

  /// Loads any persisted session, sanitizes it, and restores it paused onto
  /// the local engine. Best-effort: failures are swallowed and the bad record
  /// is cleared so startup can never be blocked by restore.
  Future<void> restore() async {
    if (_disposed) return;
    _restoring = true;
    try {
      final PersistedPlaybackSession? raw = await _store.load();
      if (raw == null) return;

      final PersistedPlaybackSession? session =
          PersistedPlaybackSession.fromJson(
        raw.toJson(),
        isTrackRestorable: _isTrackRestorable,
      );
      if (session == null || session.current == null) {
        await _store.clear();
        return;
      }

      await _controller.restoreSession(
        tracks: session.tracks,
        startIndex: session.currentIndex,
        position: session.position,
        shuffleEnabled: session.shuffleEnabled,
        repeatMode: session.repeatMode,
        originalOrder: session.originalOrder,
      );
    } catch (_) {
      try {
        await _store.clear();
      } catch (_) {
        // Ignore: a clear failure must not block startup either.
      }
    } finally {
      _restoring = false;
    }
  }

  void _onPlaybackState(PlaybackState state) {
    if (_disposed || _restoring) return;

    if (state.currentTrack == null) {
      _positionTimer?.cancel();
      _positionTimer = null;
      _lastPersisted = null;
      unawaited(_clearQuietly());
      return;
    }

    // Persist immediately on structural / mode / status changes; debounce the
    // high-frequency position ticks while playing.
    final bool structuralChange = _lastPersisted == null ||
        _lastPersisted!.currentTrack?.uri != state.currentTrack?.uri ||
        !_listEqualsByUri(_lastPersisted!.upNext, state.upNext) ||
        !_listEqualsByUri(_lastPersisted!.previous, state.previous) ||
        _lastPersisted!.shuffleEnabled != state.shuffleEnabled ||
        _lastPersisted!.repeatMode != state.repeatMode ||
        _lastPersisted!.status != state.status;

    if (structuralChange) {
      _positionTimer?.cancel();
      _positionTimer = null;
      unawaited(_persist(state));
      return;
    }

    if (state.status == PlaybackStatus.playing) {
      _positionTimer ??= Timer(_positionSaveInterval, () {
        _positionTimer = null;
        unawaited(_persist(state));
      });
    } else {
      _positionTimer?.cancel();
      _positionTimer = null;
      unawaited(_persist(state));
    }
  }

  Future<void> _persist(PlaybackState state) async {
    final Track? current = state.currentTrack;
    if (current == null) return;

    final PersistedPlaybackSession? session =
        PersistedPlaybackSession.fromPlayback(
      previous: state.previous,
      current: current,
      upNext: state.upNext,
      position: state.position,
      shuffleEnabled: state.shuffleEnabled,
      repeatMode: state.repeatMode,
      // The live controller does not expose originalOrder on PlaybackState; a
      // shuffled queue is persisted in its effective order and restored as
      // already-shuffled (originalOrder null → unshuffle becomes a no-op until
      // the user toggles shuffle off/on). That keeps the document free of a
      // second secret-bearing surface while still restoring useful up-next.
      originalOrder: null,
    );
    if (session == null) return;

    try {
      await _store.save(session);
      _lastPersisted = state;
    } catch (_) {
      // Non-fatal: persistence must never break playback.
    }
  }

  Future<void> _clearQuietly() async {
    try {
      await _store.clear();
    } catch (_) {
      // Non-fatal.
    }
  }

  bool _isTrackRestorable(Track track) {
    if (!isLogicalTrackUri(track.uri)) return false;
    final MusicProvider provider = MusicProviders.forTrackUri(track.uri);
    if (identical(provider, MusicProviders.local)) {
      return _localFileExists(track.uri);
    }
    final bool Function(MusicProvider)? available = _isRemoteProviderAvailable;
    if (available == null) return true;
    return available(provider);
  }

  static bool _defaultLocalFileExists(String uri) {
    // content:// and similar non-file local identities are kept; only plain
    // filesystem paths are probed so a missing file after a move is dropped.
    if (uri.contains(':') && !uri.startsWith('/')) return true;
    try {
      return File(uri).existsSync();
    } catch (_) {
      return false;
    }
  }

  static bool _listEqualsByUri(List<Track> a, List<Track> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].uri != b[i].uri) return false;
    }
    return true;
  }

  /// Stops listening. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }
}
