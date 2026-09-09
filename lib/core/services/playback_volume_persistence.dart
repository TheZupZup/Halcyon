import 'dart:async';

import '../models/playback_state.dart';
import '../repositories/playback_preferences.dart';
import 'playback_controller.dart';

/// Remembers the desktop volume across launches.
///
/// The engine is the source of truth while the app runs (the slider, MPRIS, and
/// a mute all go through [PlaybackController]), so this listens to the state
/// stream rather than being written to from the UI: whatever changes the level,
/// the same value is what gets stored.
///
/// Restore is deliberately one-way and sanitized. [PlaybackPreferences] hands
/// back a level clamped to 0.0–1.0, and this applies it once at startup before
/// anything can play — so a corrupt or out-of-range stored value can never
/// reach the audio engine, and a level restored from disk never surprises the
/// listener mid-track.
///
/// Mute is intentionally *not* persisted: coming back to a player that is
/// silent for a reason nothing on screen explains is the worst version of this
/// feature. A new launch always starts unmuted at the stored level.
class PlaybackVolumePersistence {
  PlaybackVolumePersistence({
    required PlaybackPreferences preferences,
    required PlaybackController controller,
    required Stream<PlaybackState> playbackStates,
    Duration saveDebounce = const Duration(milliseconds: 500),
  })  : _preferences = preferences,
        _controller = controller,
        _saveDebounce = saveDebounce {
    _subscription = playbackStates.listen(_onPlaybackState);
  }

  final PlaybackPreferences _preferences;
  final PlaybackController _controller;
  final Duration _saveDebounce;

  StreamSubscription<PlaybackState>? _subscription;
  Timer? _saveTimer;
  double? _lastSeen;
  bool _disposed = false;

  /// The writes, one after another. Every save joins this chain, so two of them
  /// can never overlap (and land out of order), and [dispose] has one thing to
  /// await to know the last level actually reached disk.
  Future<void> _writes = Future<void>.value();

  /// Loads the stored volume and applies it to the controller.
  ///
  /// Best-effort: a store that throws leaves playback at full volume rather
  /// than blocking startup.
  Future<void> restore() async {
    if (_disposed) return;
    try {
      final double stored =
          PlaybackState.sanitizeVolume(await _preferences.volume());
      if (_disposed) return;
      _lastSeen = stored;
      _controller.setVolume(stored);
    } catch (_) {
      // Ignore: a failed restore must never stop the app from launching.
    }
  }

  void _onPlaybackState(PlaybackState state) {
    if (_disposed) return;
    final double volume = state.volume;
    if (volume == _lastSeen) return;
    _lastSeen = volume;
    // Debounced: a drag emits a state per pointer move, and each write is a
    // disk touch. The last value in a burst is the one worth keeping.
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () {
      _saveTimer = null;
      unawaited(_persist(volume));
    });
  }

  Future<void> _persist(double volume) {
    _writes = _writes.then((_) async {
      try {
        await _preferences.setVolume(volume);
      } catch (_) {
        // Ignore: failing to remember a volume must never break playback.
      }
    });
    return _writes;
  }

  /// Stops listening, flushes a pending save, and waits for any write already
  /// in flight — so a level changed just before shutdown is on disk by the time
  /// the app is allowed to exit, whether its debounce had fired yet or not.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final bool savePending = _saveTimer != null;
    _saveTimer?.cancel();
    _saveTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final double? pending = _lastSeen;
    if (savePending && pending != null) unawaited(_persist(pending));
    await _writes;
  }
}
