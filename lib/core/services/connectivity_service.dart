/// Network reachability, abstracted so downloads can enforce the user's
/// mobile-data preference without binding policy code to Android APIs.
///
/// The historical enum names are kept to avoid churn, but policy is based on
/// Android's metering signal rather than a guessed transport name:
///
///  - [offline]: no active connection — downloads wait.
///  - [wifi]: the active connection is **unmetered** — downloads are allowed.
///    This is normally Wi-Fi or Ethernet, but can also be unmetered cellular.
///  - [mobile]: the active connection is **metered** — downloads are allowed only
///    when the user has turned on "Allow mobile data". Metered Wi-Fi also lands
///    here, which avoids treating a paid hotspot as free data.
///  - [unknown]: metering couldn't be determined. Treated conservatively like
///    [mobile], so an unusual device or platform failure is never assumed free.
enum NetworkStatus { offline, wifi, mobile, unknown }

abstract interface class ConnectivityService {
  /// Emits whenever the active network or its metering state changes.
  Stream<NetworkStatus> get statusStream;

  /// One-shot read of the current status.
  Future<NetworkStatus> currentStatus();
}
