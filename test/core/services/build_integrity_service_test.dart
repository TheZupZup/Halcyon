import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/build_integrity_service.dart';

void main() {
  group('BuildIntegrityStatus', () {
    test('warns for an unknown release signature', () {
      const status = BuildIntegrityStatus(
        state: BuildIntegrityState.unofficial,
        certificateSha256: 'deadbeef',
      );

      expect(status.shouldWarn, isTrue);
      expect(status.label, 'UNOFFICIAL BUILD');
    });

    test('fails closed when Android provenance cannot be verified', () {
      const status = BuildIntegrityStatus.unavailable();

      expect(status.shouldWarn, isTrue);
      expect(status.label, 'Build could not be verified');
    });

    test('does not warn for the official signing identity', () {
      const status = BuildIntegrityStatus(
        state: BuildIntegrityState.official,
        certificateSha256: 'trusted',
      );

      expect(status.shouldWarn, isFalse);
      expect(status.label, 'Official signed build');
    });

    test('development and non-Android hosts do not interrupt developers', () {
      const development = BuildIntegrityStatus(
        state: BuildIntegrityState.development,
      );
      const unsupported = BuildIntegrityStatus.unsupported();

      expect(development.shouldWarn, isFalse);
      expect(unsupported.shouldWarn, isFalse);
    });
  });
}
