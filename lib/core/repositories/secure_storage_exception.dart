/// Why a platform secure-storage (keyring) operation failed.
///
/// The Linux implementation of `flutter_secure_storage` is a thin libsecret
/// wrapper, so on that platform these map onto the freedesktop Secret Service:
/// no provider running, a locked keyring, or a sandbox that refuses the
/// service. Android's Keystore fails far more rarely, but the same kinds
/// describe it well enough for a message, and the app behaves identically on
/// both: it stays signed out and says so.
enum SecureStorageFailure {
  /// No secure storage to talk to: no Secret Service on the session bus (bare
  /// window manager, no keyring daemon), or a sandbox that hides the name.
  unavailable,

  /// Secure storage exists but is locked, or the unlock prompt was dismissed.
  locked,

  /// Secure storage answered and refused. Distinct from [unavailable]: the
  /// service is there, the access is not granted.
  denied,

  /// Anything else the platform reported. Recoverable in the same way (retry,
  /// or sign in again), just not attributable to a specific cause.
  unknown,
}

/// Which operation failed, so a message can say whether a credential failed to
/// be saved, read back, or removed.
enum SecureStorageOperation { read, write, delete }

/// A secure-storage failure, carrying only what is safe to show and log.
///
/// Deliberately narrow: it holds the [operation] and a [failure] kind and
/// **nothing from the platform error**: not the message, not the details, not
/// the key, and above all not the value that was being stored. Platform error
/// text is classified into [SecureStorageFailure] at the boundary and then
/// dropped, so no part of a token, password or session secret can reach a log,
/// a diagnostics report, an exception message, or a crash report through this
/// type.
class SecureStorageException implements Exception {
  const SecureStorageException({
    required this.operation,
    required this.failure,
  });

  final SecureStorageOperation operation;
  final SecureStorageFailure failure;

  /// A short, secret-free sentence telling the user what to do next.
  ///
  /// Callers prefix it with their own provider-specific lead ("Couldn't save
  /// your Jellyfin session on this device."), so the phrasing here stays
  /// generic and actionable.
  String get remedy {
    switch (failure) {
      case SecureStorageFailure.unavailable:
        return 'This device has no keyring available to store it securely.';
      case SecureStorageFailure.locked:
        return 'Unlock your keyring and try again.';
      case SecureStorageFailure.denied:
        return 'Your keyring refused access to Linthra.';
      case SecureStorageFailure.unknown:
        return 'Try again.';
    }
  }

  @override
  String toString() =>
      'SecureStorageException(${operation.name}: ${failure.name})';
}
