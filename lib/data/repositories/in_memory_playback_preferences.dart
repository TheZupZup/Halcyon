import '../../core/models/playback_state.dart';
import '../../core/repositories/playback_preferences.dart';

/// A non-persistent [PlaybackPreferences] for development and tests.
class InMemoryPlaybackPreferences implements PlaybackPreferences {
  InMemoryPlaybackPreferences({
    bool normalizeVolume = false,
    double volume = 1.0,
    String? audioOutputDeviceId,
  })  : _normalizeVolume = normalizeVolume,
        _volume = PlaybackState.sanitizeVolume(volume),
        _audioOutputDeviceId = audioOutputDeviceId;

  bool _normalizeVolume;
  double _volume;
  String? _audioOutputDeviceId;

  @override
  Future<bool> normalizeVolume() async => _normalizeVolume;

  @override
  Future<void> setNormalizeVolume(bool value) async {
    _normalizeVolume = value;
  }

  @override
  Future<double> volume() async => _volume;

  @override
  Future<void> setVolume(double value) async {
    _volume = PlaybackState.sanitizeVolume(value);
  }

  @override
  Future<String?> audioOutputDeviceId() async => _audioOutputDeviceId;

  @override
  Future<void> setAudioOutputDeviceId(String? id) async {
    _audioOutputDeviceId = (id == null || id.isEmpty) ? null : id;
  }
}
