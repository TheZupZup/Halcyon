/// Runtime provenance of the installed Linthra build.
enum BuildIntegrityState {
  /// Signed with the official Linthra release certificate.
  official,

  /// Android release whose current signing certificate is not recognized.
  unofficial,

  /// A debuggable/development build. Useful for local development and CI, but
  /// intentionally not treated as an official release.
  development,

  /// Android build whose signing certificate could not be verified.
  unavailable,

  /// Host where APK signing does not apply (Linux today).
  unsupported,
}

/// Result returned by [BuildIntegrityService].
class BuildIntegrityStatus {
  const BuildIntegrityStatus({
    required this.state,
    this.certificateSha256,
  });

  const BuildIntegrityStatus.unsupported()
      : state = BuildIntegrityState.unsupported,
        certificateSha256 = null;

  const BuildIntegrityStatus.unavailable()
      : state = BuildIntegrityState.unavailable,
        certificateSha256 = null;

  final BuildIntegrityState state;

  /// Lower-case SHA-256 digest of the current Android signing certificate when
  /// the platform could read it. This is public certificate data, never a key
  /// or secret.
  final String? certificateSha256;

  /// Unknown release signatures and verification failures both warn. Failing
  /// closed is deliberate: if Linthra cannot prove an Android release came from
  /// the official signing identity, users should not silently be told it did.
  bool get shouldWarn =>
      state == BuildIntegrityState.unofficial ||
      state == BuildIntegrityState.unavailable;

  String get label => switch (state) {
        BuildIntegrityState.official => 'Official signed build',
        BuildIntegrityState.unofficial => 'UNOFFICIAL BUILD',
        BuildIntegrityState.development => 'Development build',
        BuildIntegrityState.unavailable => 'Build could not be verified',
        BuildIntegrityState.unsupported => 'Not applicable on this platform',
      };
}

/// Reads the platform's package-signing identity and classifies it.
abstract interface class BuildIntegrityService {
  Future<BuildIntegrityStatus> check();
}

/// Default for tests and non-production containers: no platform call.
class UnsupportedBuildIntegrityService implements BuildIntegrityService {
  const UnsupportedBuildIntegrityService();

  @override
  Future<BuildIntegrityStatus> check() async =>
      const BuildIntegrityStatus.unsupported();
}
