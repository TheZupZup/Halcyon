import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/android_build_integrity_service.dart';
import '../../core/services/build_integrity_service.dart';

/// Signing/provenance seam. Tests default to unsupported so they never invoke a
/// native method channel; production replaces it with the Android checker.
final buildIntegrityServiceProvider = Provider<BuildIntegrityService>((ref) {
  return const UnsupportedBuildIntegrityService();
});

/// One immutable check per application container. Package signing cannot change
/// while the installed process is running, so there is no reason to poll it.
final buildIntegrityStatusProvider = FutureProvider<BuildIntegrityStatus>((ref) {
  return ref.watch(buildIntegrityServiceProvider).check();
});

final platformBuildIntegrityServiceOverride =
    buildIntegrityServiceProvider.overrideWithValue(
  const AndroidBuildIntegrityService(),
);
