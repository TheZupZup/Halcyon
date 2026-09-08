import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/repositories/secure_storage_exception.dart';

/// The one door between Linthra's provider credentials and platform secure
/// storage.
///
/// Used by the Jellyfin, Navidrome/Subsonic, Plex and Audiobookshelf session
/// stores, which are the credential path this class exists to hold to one set
/// of rules. (The GitHub Sponsors token store calls `flutter_secure_storage`
/// directly and is separate work; it stores no provider credential.)
///
/// The rules, stated once:
///
/// * Linthra has no fallback of its own. If the platform store can't take a
///   value, the write fails: Linthra writes nothing to preferences, the
///   database, a cache, a log, or any file of its own, in plaintext or
///   otherwise. A failed read is a failure, not an empty result.
/// * A platform failure is translated into a [SecureStorageException] carrying
///   only an operation and a cause. The platform's own error text is inspected
///   to classify it and then dropped, so nothing derived from a stored value
///   can travel further (see [SecureStorageException]).
/// * Nothing here logs. Not the value, not the key, not the platform message.
///
/// What the platform then does with the value is the platform's business, and
/// differs by more than just OS. On Android it is the Keystore-backed store.
/// On Linux it is `flutter_secure_storage_linux`, a thin wrapper over
/// libsecret, which picks its own backend: a native build talks to the
/// freedesktop Secret Service (the desktop keyring), while inside a Flatpak
/// with the Secret portal available libsecret keeps its own encrypted file
/// under the app's data directory, with the master secret handed over by the
/// portal from the host keyring. Both are libsecret-managed and encrypted at
/// rest; neither is something Linthra writes or can read around.
///
/// The failure kinds below are written for the Linux stack because that is
/// where secure storage can realistically be missing or locked; the mapping is
/// harmless on the others.
class SecureSessionStorage {
  const SecureSessionStorage({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  /// The value stored under [key], or `null` when there is none.
  ///
  /// Throws [SecureStorageException] when the platform store could not be
  /// read: a missing, locked or denied keyring is *not* reported as "no value",
  /// because that would look exactly like a clean sign-out and would quietly
  /// discard a credential that is still there.
  Future<String?> read({required String key}) =>
      _guard(SecureStorageOperation.read, () => _storage.read(key: key));

  /// Stores [value] under [key], replacing any previous value.
  Future<void> write({required String key, required String value}) => _guard(
        SecureStorageOperation.write,
        () => _storage.write(key: key, value: value),
      );

  /// Removes whatever is stored under [key]. Succeeds when there was nothing.
  Future<void> delete({required String key}) =>
      _guard(SecureStorageOperation.delete, () => _storage.delete(key: key));

  Future<T> _guard<T>(
    SecureStorageOperation operation,
    Future<T> Function() call,
  ) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      throw SecureStorageException(
        operation: operation,
        failure: _classify(error.code, error.message),
      );
    } on MissingPluginException {
      // No secure-storage implementation registered for this platform at all.
      throw SecureStorageException(
        operation: operation,
        failure: SecureStorageFailure.unavailable,
      );
    }
  }
}

/// Classify a platform error into a cause, from its code and message.
///
/// The strings matched here are the ones the Linux stack actually produces.
/// `flutter_secure_storage_linux` catches libsecret's `GError` message (or its
/// own "Failed to unlock the keyring" when the keyring warm-up store fails) and
/// returns it as a `PlatformException` with the code "Libsecret error", so the
/// distinctions a user can act on (no service, locked, refused) are only
/// available in that text. It is read here and never kept.
SecureStorageFailure _classify(String code, String? message) {
  final String text = '$code ${message ?? ''}'.toLowerCase();

  // The plugin's own keyring warm-up (a dummy store, done before every read)
  // failing, and libsecret's dismissed-prompt path: the service is there, the
  // secrets are not reachable until the user unlocks it.
  if (text.contains('failed to unlock') ||
      text.contains('locked') ||
      text.contains('dismissed') ||
      text.contains('cancelled') ||
      text.contains('canceled')) {
    return SecureStorageFailure.locked;
  }

  // Nothing owns org.freedesktop.secrets on the session bus (no keyring daemon
  // running), or a sandbox's D-Bus filter is hiding the name from us: what a
  // Flatpak sees on a host that provides neither the Secret portal nor a
  // reachable Secret Service.
  if (text.contains('serviceunknown') ||
      text.contains('namehasnoowner') ||
      text.contains('was not provided by any .service files') ||
      text.contains('no such name') ||
      text.contains('not provided')) {
    return SecureStorageFailure.unavailable;
  }

  // The service answered and said no, including the Flatpak D-Bus proxy
  // rejecting a call to a name the manifest does not grant.
  if (text.contains('accessdenied') ||
      text.contains('access denied') ||
      text.contains('permission denied') ||
      text.contains('not allowed') ||
      text.contains('rejected send message')) {
    return SecureStorageFailure.denied;
  }

  return SecureStorageFailure.unknown;
}
