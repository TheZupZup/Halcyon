import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/android_connectivity_service.dart';
import 'package:linthra/core/services/connectivity_service.dart';

void main() {
  group('AndroidConnectivityService', () {
    test('maps the platform vocabulary onto download policy states', () {
      expect(
        AndroidConnectivityService.decodePlatformStatus('unmetered'),
        NetworkStatus.wifi,
      );
      expect(
        AndroidConnectivityService.decodePlatformStatus('metered'),
        NetworkStatus.mobile,
      );
      expect(
        AndroidConnectivityService.decodePlatformStatus('offline'),
        NetworkStatus.offline,
      );
      expect(
        AndroidConnectivityService.decodePlatformStatus('unknown'),
        NetworkStatus.unknown,
      );
      expect(
        AndroidConnectivityService.decodePlatformStatus('unexpected'),
        NetworkStatus.unknown,
      );
      expect(
        AndroidConnectivityService.decodePlatformStatus(null),
        NetworkStatus.unknown,
      );
    });

    test('currentStatus reads the injected platform value', () async {
      final service = AndroidConnectivityService(
        statusReader: () async => 'metered',
        statusEvents: const Stream<Object?>.empty(),
      );

      expect(await service.currentStatus(), NetworkStatus.mobile);
    });

    test('currentStatus fails closed when the platform channel throws', () async {
      final service = AndroidConnectivityService(
        statusReader: () => Future<Object?>.error(Exception('channel failed')),
        statusEvents: const Stream<Object?>.empty(),
      );

      expect(await service.currentStatus(), NetworkStatus.unknown);
    });

    test('statusStream maps changes and suppresses duplicates', () async {
      final events = StreamController<Object?>();
      final service = AndroidConnectivityService(
        statusReader: () async => 'unmetered',
        statusEvents: events.stream,
      );
      final values = <NetworkStatus>[];
      final subscription = service.statusStream.listen(values.add);

      events
        ..add('unmetered')
        ..add('unmetered')
        ..add('metered')
        ..add('offline');
      await events.close();
      await subscription.asFuture<void>();

      expect(
        values,
        <NetworkStatus>[
          NetworkStatus.wifi,
          NetworkStatus.mobile,
          NetworkStatus.offline,
        ],
      );
    });

    test('statusStream emits unknown instead of exposing channel errors',
        () async {
      final events = StreamController<Object?>();
      final service = AndroidConnectivityService(
        statusReader: () async => 'unmetered',
        statusEvents: events.stream,
      );
      final values = <NetworkStatus>[];
      final subscription = service.statusStream.listen(values.add);

      events
        ..add('unmetered')
        ..addError(Exception('private platform detail'));
      await events.close();
      await subscription.asFuture<void>();

      expect(
        values,
        <NetworkStatus>[NetworkStatus.wifi, NetworkStatus.unknown],
      );
    });
  });
}
