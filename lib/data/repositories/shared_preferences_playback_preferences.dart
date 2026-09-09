import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/playback_state.dart';
import '../../core/repositories/playback_preferences.dart';

/// A [PlaybackPreferences] backed by `shared_preferences`. Both choices are
/// small scalars, so they live next to the other small user choices in the
/// key/value store rather than in the SQLite catalog.
class SharedPreferencesPlaybackPreferences implements PlaybackPreferences {
  const SharedPreferencesPlaybackPreferences();

  static const String _normalizeVolumeKey = 'playback_normalize_volume';
  static const String _volumeKey = 'playback_volume';

  @override
  Future<bool> normalizeVolume() async {
    final prefs = await SharedPreferences.getInstance();
    // Default false: never alter audio unless the listener opts in.
    return prefs.getBool(_normalizeVolumeKey) ?? false;
  }

  @override
  Future<void> setNormalizeVolume(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_normalizeVolumeKey, value);
  }

  @override
  Future<double> volume() async {
    final prefs = await SharedPreferences.getInstance();
    // Sanitized on the way out, not trusted: the store is a plain file a user
    // (or a future bug) can leave a 7.5, a -1, or a NaN in, and an unbounded
    // value must never reach the audio engine. Nothing stored means full
    // volume, the level the app has always played at.
    final double? stored = prefs.getDouble(_volumeKey);
    return stored == null ? 1.0 : PlaybackState.sanitizeVolume(stored);
  }

  @override
  Future<void> setVolume(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeKey, PlaybackState.sanitizeVolume(value));
  }
}
