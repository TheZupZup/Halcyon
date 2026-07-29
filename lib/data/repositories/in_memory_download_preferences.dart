import '../../core/models/cache_size.dart';
import '../../core/repositories/download_preferences.dart';

/// A non-persistent [DownloadPreferences] for development and tests.
class InMemoryDownloadPreferences implements DownloadPreferences {
  InMemoryDownloadPreferences({
    MobileDataProfile? mobileDataProfile,
    bool allowMobileData = false,
    int maxCacheBytes = CacheSize.defaultLimit,
    bool preloadEnabled = true,
    int precacheCount = kDefaultPrecacheCount,
  })  : _mobileDataProfile = mobileDataProfile ??
            (allowMobileData
                ? MobileDataProfile.unlimited
                : MobileDataProfile.wifiOnly),
        _maxCacheBytes = maxCacheBytes,
        _preloadEnabled = preloadEnabled,
        _precacheCount = sanitizePrecacheCount(precacheCount);

  MobileDataProfile _mobileDataProfile;
  int _maxCacheBytes;
  bool _preloadEnabled;
  int _precacheCount;

  @override
  Future<MobileDataProfile> mobileDataProfile() async => _mobileDataProfile;

  @override
  Future<void> setMobileDataProfile(MobileDataProfile profile) async {
    _mobileDataProfile = profile;
  }

  @override
  Future<bool> allowMobileData() async =>
      _mobileDataProfile.allowsMeteredDownloads;

  @override
  Future<void> setAllowMobileData(bool value) async {
    _mobileDataProfile =
        value ? MobileDataProfile.unlimited : MobileDataProfile.wifiOnly;
  }

  @override
  Future<int> maxCacheBytes() async => _maxCacheBytes;

  @override
  Future<void> setMaxCacheBytes(int bytes) async {
    _maxCacheBytes = bytes;
  }

  @override
  Future<bool> preloadEnabled() async => _preloadEnabled;

  @override
  Future<void> setPreloadEnabled(bool value) async {
    _preloadEnabled = value;
  }

  @override
  Future<int> precacheCount() async => _precacheCount;

  @override
  Future<void> setPrecacheCount(int value) async {
    _precacheCount = sanitizePrecacheCount(value);
  }
}
