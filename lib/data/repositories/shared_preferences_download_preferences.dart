import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/cache_size.dart';
import '../../core/repositories/download_preferences.dart';

/// A [DownloadPreferences] backed by `shared_preferences`. These choices are
/// small scalars, so they live next to the other small user preferences rather
/// than in the SQLite catalog.
class SharedPreferencesDownloadPreferences implements DownloadPreferences {
  const SharedPreferencesDownloadPreferences();

  static const String _mobileDataProfileKey = 'downloads_mobile_data_profile';
  static const String _allowMobileDataKey = 'downloads_allow_mobile_data';
  static const String _maxCacheBytesKey = 'downloads_max_cache_bytes';
  static const String _preloadEnabledKey = 'downloads_preload_enabled';
  static const String _precacheCountKey = 'downloads_precache_count';

  @override
  Future<MobileDataProfile> mobileDataProfile() async {
    final prefs = await SharedPreferences.getInstance();
    switch (prefs.getString(_mobileDataProfileKey)) {
      case 'saveData':
        return MobileDataProfile.saveData;
      case 'unlimited':
        return MobileDataProfile.unlimited;
      case 'wifiOnly':
        return MobileDataProfile.wifiOnly;
    }

    // Migrate the former boolean without changing an upgrading user's choice.
    return (prefs.getBool(_allowMobileDataKey) ?? false)
        ? MobileDataProfile.unlimited
        : MobileDataProfile.wifiOnly;
  }

  @override
  Future<void> setMobileDataProfile(MobileDataProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mobileDataProfileKey, profile.name);
    // Keep the legacy value synchronized for older code and backup readers.
    await prefs.setBool(
      _allowMobileDataKey,
      profile.allowsMeteredDownloads,
    );
  }

  @override
  Future<bool> allowMobileData() async =>
      (await mobileDataProfile()).allowsMeteredDownloads;

  @override
  Future<void> setAllowMobileData(bool value) => setMobileDataProfile(
        value ? MobileDataProfile.unlimited : MobileDataProfile.wifiOnly,
      );

  @override
  Future<int> maxCacheBytes() async {
    final prefs = await SharedPreferences.getInstance();
    final int? stored = prefs.getInt(_maxCacheBytesKey);
    if (stored == null) return CacheSize.defaultLimit;
    return CacheSize.clamp(stored);
  }

  @override
  Future<void> setMaxCacheBytes(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_maxCacheBytesKey, CacheSize.clamp(bytes));
  }

  @override
  Future<bool> preloadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_preloadEnabledKey) ?? true;
  }

  @override
  Future<void> setPreloadEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preloadEnabledKey, value);
  }

  @override
  Future<int> precacheCount() async {
    final prefs = await SharedPreferences.getInstance();
    final int? stored = prefs.getInt(_precacheCountKey);
    if (stored == null) return kDefaultPrecacheCount;
    return sanitizePrecacheCount(stored);
  }

  @override
  Future<void> setPrecacheCount(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_precacheCountKey, sanitizePrecacheCount(value));
  }
}
