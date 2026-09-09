/// The user's playback preferences.
///
/// Kept behind an interface (like [DownloadPreferences]) so the playback layer
/// can consult the user's choices without binding to a storage plugin.
///
///  - "Normalize volume": when on, playback applies a track's ReplayGain so
///    songs play at a more even loudness. Off by default — the safe choice, so
///    audio is never altered unless the listener opts in.
///  - The playback volume the desktop controls set, so a window that is closed
///    and reopened comes back at the level it was left at.
abstract interface class PlaybackPreferences {
  /// Whether volume normalization (ReplayGain) is applied during playback.
  /// Defaults to `false`, so audio plays untouched out of the box.
  Future<bool> normalizeVolume();

  Future<void> setNormalizeVolume(bool value);

  /// The listener's persisted playback volume, 0.0–1.0. Defaults to `1.0` (full
  /// volume) when nothing has been stored yet.
  ///
  /// Implementations sanitize what they read: a missing, out-of-range, or
  /// otherwise unusable stored value comes back as the default rather than
  /// reaching the audio engine.
  Future<double> volume();

  /// Stores [value] as the playback volume, sanitized to 0.0–1.0.
  Future<void> setVolume(double value);
}
