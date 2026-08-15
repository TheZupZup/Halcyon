import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';

void main() {
  group('HostPlatform.fromOperatingSystem', () {
    test('maps every operating system dart:io reports', () {
      expect(HostPlatform.fromOperatingSystem('android'), HostPlatform.android);
      expect(HostPlatform.fromOperatingSystem('ios'), HostPlatform.ios);
      expect(HostPlatform.fromOperatingSystem('linux'), HostPlatform.linux);
      expect(HostPlatform.fromOperatingSystem('macos'), HostPlatform.macOS);
      expect(HostPlatform.fromOperatingSystem('windows'), HostPlatform.windows);
      expect(HostPlatform.fromOperatingSystem('fuchsia'), HostPlatform.other);
    });

    test('an unknown embedder falls into "other", never Android', () {
      // The important half: a platform nobody has thought about must not be
      // handed the Android bindings by accident. Every seam treats "other" the
      // way it treats desktop — as "not Android".
      expect(
          HostPlatform.fromOperatingSystem('someFutureOs'), HostPlatform.other);
      expect(HostPlatform.fromOperatingSystem('').isAndroid, isFalse);
      expect(HostPlatform.fromOperatingSystem('Android').isAndroid, isFalse,
          reason: 'dart:io reports lowercase; matching must stay exact');
    });
  });

  group('classification', () {
    test('only Android is Android', () {
      expect(HostPlatform.android.isAndroid, isTrue);
      for (final HostPlatform other in HostPlatform.values.where(
        (HostPlatform p) => p != HostPlatform.android,
      )) {
        expect(other.isAndroid, isFalse,
            reason: '${other.label} is not Android');
      }
    });

    test('Linux, macOS and Windows are desktop; Android and iOS are not', () {
      expect(HostPlatform.linux.isDesktop, isTrue);
      expect(HostPlatform.macOS.isDesktop, isTrue);
      expect(HostPlatform.windows.isDesktop, isTrue);
      expect(HostPlatform.android.isDesktop, isFalse);
      expect(HostPlatform.ios.isDesktop, isFalse);
      expect(HostPlatform.other.isDesktop, isFalse);
    });

    test('labels are stable, lowercase and secret-free', () {
      // Diagnostics embed these, so they must never grow into a device string.
      for (final HostPlatform platform in HostPlatform.values) {
        expect(platform.label, matches(RegExp(r'^[a-z]+$')));
      }
      expect(HostPlatform.macOS.label, 'macos');
    });
  });

  group('HostPlatform.current', () {
    test('agrees with dart:io on whatever host is running the suite', () {
      // Not a tautology: it is the one assertion that the production default
      // still reads the real OS rather than a hardcoded value.
      expect(
        HostPlatform.current,
        HostPlatform.fromOperatingSystem(Platform.operatingSystem),
      );
      expect(HostPlatform.current.isAndroid, Platform.isAndroid);
    });
  });
}
