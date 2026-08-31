import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/reachability.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_availability.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/source_availability.dart';

void main() {
  group('SourceAvailability', () {
    test('separates "configured" from "available"', () {
      // The whole point of #536: a saved session is not a reachable server.
      expect(SourceAvailability.unreachable.isConfigured, isTrue);
      expect(SourceAvailability.unreachable.isAvailable, isFalse);
      expect(SourceAvailability.authenticationError.isConfigured, isTrue);
      expect(SourceAvailability.authenticationError.isAvailable, isFalse);
      expect(SourceAvailability.checking.isConfigured, isTrue);
      expect(SourceAvailability.notConfigured.isConfigured, isFalse);
      expect(SourceAvailability.available.isAvailable, isTrue);
    });

    test('hides tracks only for a proven failure', () {
      expect(SourceAvailability.unreachable.hidesTracks, isTrue);
      expect(SourceAvailability.authenticationError.hidesTracks, isTrue);
      // "We haven't checked yet" must never blank a library.
      expect(SourceAvailability.checking.hidesTracks, isFalse);
      expect(SourceAvailability.available.hidesTracks, isFalse);
      expect(SourceAvailability.notConfigured.hidesTracks, isFalse);
    });
  });

  group('SourceAvailabilityState', () {
    test('compares by status and timestamp', () {
      final DateTime at = DateTime(2026, 8, 31, 12);
      expect(
        const SourceAvailabilityState(status: SourceAvailability.available),
        equals(
          const SourceAvailabilityState(status: SourceAvailability.available),
        ),
      );
      expect(
        SourceAvailabilityState(
            status: SourceAvailability.available, lastCheckedAt: at),
        isNot(equals(
          const SourceAvailabilityState(status: SourceAvailability.available),
        )),
      );
      expect(
        const SourceAvailabilityState.checking(),
        isNot(equals(const SourceAvailabilityState.notConfigured())),
      );
    });

    test('named constructors carry no timestamp', () {
      expect(const SourceAvailabilityState.checking().lastCheckedAt, isNull);
      expect(
        const SourceAvailabilityState.notConfigured().status,
        SourceAvailability.notConfigured,
      );
    });
  });

  group('configuredSourceAvailabilityLabel', () {
    test('only an available server reads as "connected"', () {
      expect(
        configuredSourceAvailabilityLabel(SourceAvailability.available),
        'connected',
      );
      // The bug in #536: a saved session for a LAN-only server reported
      // "connected" from anywhere. It must now name what is really wrong.
      expect(
        configuredSourceAvailabilityLabel(SourceAvailability.unreachable),
        'configured (server unreachable)',
      );
      expect(
        configuredSourceAvailabilityLabel(
            SourceAvailability.authenticationError),
        'configured (authentication error)',
      );
      expect(
        configuredSourceAvailabilityLabel(SourceAvailability.checking),
        'configured (checking)',
      );
      expect(
        configuredSourceAvailabilityLabel(SourceAvailability.notConfigured),
        'configured (not checked)',
      );
    });

    test('every non-available label still says the server is configured', () {
      for (final SourceAvailability availability in SourceAvailability.values) {
        if (availability == SourceAvailability.available) continue;
        expect(
          configuredSourceAvailabilityLabel(availability),
          startsWith('configured'),
          reason: '$availability must not read as signed out',
        );
      }
    });
  });

  group('availabilityFromReachability', () {
    test('maps every playback-path reachability signal', () {
      expect(
        availabilityFromReachability(ReachabilityStatus.reachable),
        SourceAvailability.available,
      );
      expect(
        availabilityFromReachability(ReachabilityStatus.authFailure),
        SourceAvailability.authenticationError,
      );
      for (final ReachabilityStatus offline in <ReachabilityStatus>[
        ReachabilityStatus.serverUnreachable,
        ReachabilityStatus.timeout,
        ReachabilityStatus.networkUnavailable,
      ]) {
        expect(
          availabilityFromReachability(offline),
          SourceAvailability.unreachable,
          reason: '$offline should read as unreachable',
        );
      }
    });
  });

  group('jellyfinAvailabilityFromError', () {
    test('only a rejected session is an authentication error', () {
      expect(
        jellyfinAvailabilityFromError(JellyfinErrorKind.unauthorized),
        SourceAvailability.authenticationError,
      );
      for (final JellyfinErrorKind kind in JellyfinErrorKind.values) {
        if (kind == JellyfinErrorKind.unauthorized) continue;
        expect(
          jellyfinAvailabilityFromError(kind),
          SourceAvailability.unreachable,
          reason: '$kind should read as unreachable',
        );
      }
    });

    test('never reports a failure as available', () {
      for (final JellyfinErrorKind kind in JellyfinErrorKind.values) {
        expect(
          jellyfinAvailabilityFromError(kind).isAvailable,
          isFalse,
          reason: '$kind must not look available',
        );
      }
    });
  });
}
