import '../models/cache_size.dart';

/// The named number-of-upcoming-tracks presets offered for smart pre-cache,
/// shown in Settings (smallest first). The small values keep playback seamless
/// without hoarding the cache; the larger ones let users warm a longer run of
/// the queue. Anything in between — up to [kMaxPrecacheCount] — is reachable as
/// a custom value, so this list is just the convenient one-tap choices.
const List<int> kPrecacheCountOptions = <int>[1, 3, 5, 10, 20, 50];

/// How many upcoming tracks smart pre-cache warms when the user hasn't chosen.
/// Modest by design — a few tracks ahead, never the whole queue. Kept at 3 so
/// upgrading users see no change in behaviour.
const int kDefaultPrecacheCount = 3;

/// Safe bounds for the pre-cache count (inclusive). The minimum keeps the
/// feature meaningful (at least the next track); the maximum stops a custom
/// value from queuing a flood of downloads — pre-cache warms the next few
/// songs, never the whole library.
const int kMinPrecacheCount = 1;
const int kMaxPrecacheCount = 200;

/// Clamps an arbitrary pre-cache count into the supported range so a corrupt,
/// out-of-range, or hand-typed value can never disable pre-cache or queue
/// thousands of downloads. A value below [kMinPrecacheCount] is treated as junk
/// and restored to [kDefaultPrecacheCount]; a value above [kMaxPrecacheCount] is
/// capped at the maximum; any value already in range — a [kPrecacheCountOptions]
/// preset or a custom number — is kept as-is.
int sanitizePrecacheCount(int value) {
  if (value < kMinPrecacheCount) return kDefaultPrecacheCount;
  if (value > kMaxPrecacheCount) return kMaxPrecacheCount;
  return value;
}

/// Whether [count] is one of the named [kPrecacheCountOptions], so the picker
/// can show it as a selected preset rather than a custom value.
bool isPrecacheCountPreset(int count) => kPrecacheCountOptions.contains(count);

/// How Linthra should use metered networks such as LTE/5G or a metered hotspot.
enum MobileDataProfile {
  /// Remote downloads and automatic cache wait for an unmetered network.
  wifiOnly,

  /// User-requested downloads may use metered data, but automatic smart
  /// pre-cache is paused to avoid background consumption.
  saveData,

  /// User-requested downloads and automatic smart pre-cache may use metered
  /// data. Offline and unknown-network safeguards still apply downstream.
  unlimited;

  /// Whether an explicit user download may start on a metered network.
  bool get allowsMeteredDownloads => this != MobileDataProfile.wifiOnly;

  /// Whether the profile deliberately pauses automatic smart pre-cache.
  bool get pausesSmartPrecache => this == MobileDataProfile.saveData;
}

/// The user's download/offline preferences.
///
/// These are kept behind an interface so the [DownloadRepository] and cache
/// manager can consult them without binding to a storage plugin. The policy
/// lives in the repository; this only remembers the choices:
///  - Mobile-data profile: Wi-Fi only, save data, or unlimited.
///  - "Max cache size": the byte ceiling the offline cache is kept under, with
///    least-recently-used eviction once a new download would exceed it.
///  - Smart pre-cache "on/off" and "how many upcoming tracks": whether, and how
///    far ahead, playback warms the next queued tracks into the cache.
abstract interface class DownloadPreferences {
  /// The user's metered-network policy. Defaults to [MobileDataProfile.wifiOnly].
  Future<MobileDataProfile> mobileDataProfile();

  Future<void> setMobileDataProfile(MobileDataProfile profile);

  /// Legacy compatibility for call sites that only need a yes/no answer.
  ///
  /// `true` means explicit downloads may use a metered network. New UI should
  /// use [mobileDataProfile] so it can distinguish save-data and unlimited.
  Future<bool> allowMobileData();

  Future<void> setAllowMobileData(bool value);

  /// The maximum total size of the offline cache in bytes. Defaults to
  /// [CacheSize.defaultLimit] when the user hasn't chosen one.
  Future<int> maxCacheBytes();

  Future<void> setMaxCacheBytes(int bytes);

  /// Whether smart pre-cache is on: upcoming queued tracks are warmed into the
  /// cache ahead of play. Defaults to `true`. Pre-cached bytes are bounded by
  /// [maxCacheBytes], skipped when the connection/profile does not allow them,
  /// and evicted before any user download.
  Future<bool> preloadEnabled();

  Future<void> setPreloadEnabled(bool value);

  /// How many upcoming tracks smart pre-cache warms ahead of the current one.
  /// A [kPrecacheCountOptions] preset or any custom value within
  /// [kMinPrecacheCount]–[kMaxPrecacheCount]; defaults to
  /// [kDefaultPrecacheCount].
  Future<int> precacheCount();

  Future<void> setPrecacheCount(int value);
}
