import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/playback_preferences.dart';

/// A [PlaybackPreferences] backed by `shared_preferences`. The choices are a
/// small bool and a short device id, so they live next to the other small user
/// choices in the key/value store rather than in the SQLite catalog.
class SharedPreferencesPlaybackPreferences implements PlaybackPreferences {
  const SharedPreferencesPlaybackPreferences();

  static const String _normalizeVolumeKey = 'playback_normalize_volume';
  static const String _audioOutputDeviceKey = 'playback_audio_output_device';

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
  Future<String?> audioOutputDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(_audioOutputDeviceKey);
    // An empty string is not a device; treat it as "system default" so a
    // half-written value can never route playback nowhere.
    return (stored == null || stored.isEmpty) ? null : stored;
  }

  @override
  Future<void> setAudioOutputDeviceId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await prefs.remove(_audioOutputDeviceKey);
      return;
    }
    await prefs.setString(_audioOutputDeviceKey, id);
  }
}
