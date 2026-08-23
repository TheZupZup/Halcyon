import 'dart:io';

import 'package:flutter/services.dart';

import 'build_integrity_service.dart';

/// Android implementation backed by `BuildIntegrityChannel.kt`.
///
/// The native side hashes the APK's current signing certificate with SHA-256
/// and compares it with the public certificate fingerprint already pinned in
/// Linthra's F-Droid reproducible-build metadata. No private key material ever
/// enters the app.
class AndroidBuildIntegrityService implements BuildIntegrityService {
  const AndroidBuildIntegrityService();

  static const MethodChannel _channel =
      MethodChannel('io.github.thezupzup.linthra/build_integrity');

  @override
  Future<BuildIntegrityStatus> check() async {
    if (!Platform.isAndroid) {
      return const BuildIntegrityStatus.unsupported();
    }
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMapMethod<Object?, Object?>('getBuildIntegrity');
      if (raw == null) {
        return const BuildIntegrityStatus.unavailable();
      }
      final String state = raw['status']?.toString() ?? 'unavailable';
      final String? certificate = raw['certificateSha256']?.toString();
      return BuildIntegrityStatus(
        state: switch (state) {
          'official' => BuildIntegrityState.official,
          'unofficial' => BuildIntegrityState.unofficial,
          'development' => BuildIntegrityState.development,
          'unsupported' => BuildIntegrityState.unsupported,
          _ => BuildIntegrityState.unavailable,
        },
        certificateSha256: certificate,
      );
    } on MissingPluginException {
      return const BuildIntegrityStatus.unavailable();
    } on PlatformException {
      return const BuildIntegrityStatus.unavailable();
    }
  }
}
