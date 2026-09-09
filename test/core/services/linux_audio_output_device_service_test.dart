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

      await service.select(
        const AudioOutputDevice(id: 'pulse/headset', label: 'Headset'),
      );

      expect(applied, 'pulse/headset');
    });

    test('a device that vanished mid-switch leaves playback alone', () async {
      final LinuxAudioOutputDeviceService service =
          LinuxAudioOutputDeviceService(
        probe: () async => const <({String id, String description})>[],
        apply: (_) async => throw StateError('device is gone'),
      );

      await expectLater(
        service.select(
          const AudioOutputDevice(id: 'pulse/headset', label: 'Headset'),
        ),
        completes,
      );
    });
  });
}
