import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_output_device.dart';
import 'package:linthra/core/services/linux_audio_output_device_service.dart';

/// The media_kit/libmpv calls themselves are not exercised here: `flutter test`
/// does not assemble the native Linux bundle, so building a real `Player` would
/// make these tests depend on libmpv and on the host's sound card. The seams
/// stand in for exactly those two calls, and what is asserted is the behaviour
/// around them — how a raw device list becomes the list Settings shows, and
/// that a backend which fails is reported as "nothing found" rather than an
/// error thrown into the UI.
void main() {
  group('LinuxAudioOutputDeviceService', () {
    test('reports itself supported', () {
      expect(LinuxAudioOutputDeviceService().isSupported, isTrue);
    });

    test('maps the backend list, system default first', () async {
      final LinuxAudioOutputDeviceService service =
          LinuxAudioOutputDeviceService(
        probe: () async => <({String id, String description})>[
          (id: 'auto', description: 'Autoselect device'),
          (id: 'pipewire/hdmi', description: 'HDMI / DisplayPort'),
        ],
        apply: (_) async {},
      );

      final List<AudioOutputDevice> devices = await service.devices();

      expect(devices.first, AudioOutputDevice.systemDefault);
      expect(devices[1].id, 'pipewire/hdmi');
      expect(devices[1].label, 'HDMI / DisplayPort');
    });

    test('a backend that cannot be asked reports no devices, not an error',
        () async {
      final LinuxAudioOutputDeviceService service =
          LinuxAudioOutputDeviceService(
        probe: () async => throw StateError('libmpv is not answering'),
        apply: (_) async {},
      );

      expect(await service.devices(), isEmpty);
    });

    test('passes the device id straight through to the backend', () async {
      String? applied;
      final LinuxAudioOutputDeviceService service =
          LinuxAudioOutputDeviceService(
        probe: () async => const <({String id, String description})>[],
        apply: (String id) async => applied = id,
      );

      final bool routed = await service.select(
        const AudioOutputDevice(id: 'pulse/headset', label: 'Headset'),
      );

      expect(applied, 'pulse/headset');
      expect(routed, isTrue);
    });

    test('a device that vanished mid-switch reports failure, not an error',
        () async {
      final LinuxAudioOutputDeviceService service =
          LinuxAudioOutputDeviceService(
        probe: () async => const <({String id, String description})>[],
        apply: (_) async => throw StateError('device is gone'),
      );

      // Reported rather than thrown, so Settings keeps working — but reported,
      // so the caller does not go on to remember an output that never started.
      expect(
        await service.select(
          const AudioOutputDevice(id: 'pulse/headset', label: 'Headset'),
        ),
        isFalse,
      );
    });

    test('a probe that never answers is an enumeration failure', () async {
      // The real timeout path: `_readDevices` deliberately lets a
      // TimeoutException out rather than falling back to libmpv's seeded
      // `[auto]` state, because a caller comparing a saved device against that
      // one-entry list would conclude the device had been removed.
      final LinuxAudioOutputDeviceService service =
          LinuxAudioOutputDeviceService(
        probe: () async => throw TimeoutException('libmpv never answered'),
        apply: (_) async {},
      );

      expect(await service.devices(), isEmpty);
    });
  });
}
