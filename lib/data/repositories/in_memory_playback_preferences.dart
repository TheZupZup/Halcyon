import '../../core/repositories/playback_preferences.dart';

/// A non-persistent [PlaybackPreferences] for development and tests.
class InMemoryPlaybackPreferences implements PlaybackPreferences {
  InMemoryPlaybackPreferences({
    bool normalizeVolume = false,
    String? audioOutputDeviceId,
  })  : _normalizeVolume = normalizeVolume,
        _audioOutputDeviceId = audioOutputDeviceId;

  bool _normalizeVolume;
  String? _audioOutputDeviceId;

  @override
  Future<bool> normalizeVolume() async => _normalizeVolume;

  @override
  Future<void> setNormalizeVolume(bool value) async {
    _normalizeVolume = value;
  }

  @override
  Future<String?> audioOutputDeviceId() async => _audioOutputDeviceId;

  @override
  Future<void> setAudioOutputDeviceId(String? id) async {
    _audioOutputDeviceId = (id == null || id.isEmpty) ? null : id;
  }
}
