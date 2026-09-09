import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_output_device.dart';

void main() {
  group('audioOutputDevicesFromBackend', () {
    test('always offers the system default first', () {
      final List<AudioOutputDevice> devices = audioOutputDevicesFromBackend(
        <({String id, String description})>[
          (id: 'pipewire/alsa_output.usb-DAC', description: 'USB DAC'),
        ],
      );

      expect(devices.first, AudioOutputDevice.systemDefault);
      expect(devices.first.label, 'System default');
      expect(devices, hasLength(2));
    });

    test('keeps the backend description as the label', () {
      final List<AudioOutputDevice> devices = audioOutputDevicesFromBackend(
        <({String id, String description})>[
          (
            id: 'pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo',
            description: 'Built-in Audio Analog Stereo',
          ),
        ],
      );

      expect(
          devices[1].id, 'pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo');
      expect(devices[1].label, 'Built-in Audio Analog Stereo');
    });

    test('never renders a blank row for a device with no description', () {
      final List<AudioOutputDevice> devices = audioOutputDevicesFromBackend(
        <({String id, String description})>[
          (id: 'alsa/sysdefault:CARD=PCH', description: '   '),
        ],
      );

      expect(devices[1].label, 'sysdefault:CARD=PCH');
    });

    test('collapses the backend\'s own auto entry into the system default', () {
      // libmpv lists `auto` itself; the list must not show it twice.
      final List<AudioOutputDevice> devices = audioOutputDevicesFromBackend(
        <({String id, String description})>[
          (id: 'auto', description: 'Autoselect device'),
          (id: 'pulse/headset', description: 'Headset'),
        ],
      );

      expect(
        devices.map((AudioOutputDevice device) => device.id),
        <String>['auto', 'pulse/headset'],
      );
      expect(devices.first.label, 'System default');
    });

    test('drops duplicate ids and blank ids', () {
      final List<AudioOutputDevice> devices = audioOutputDevicesFromBackend(
        <({String id, String description})>[
          (id: 'pulse/headset', description: 'Headset'),
          (id: 'pulse/headset', description: 'Headset (alias)'),
          (id: '  ', description: 'Nothing'),
        ],
      );

      expect(devices, hasLength(2));
      expect(devices[1].label, 'Headset');
    });
  });

  group('AudioOutputDevice.isPersistableId', () {
    test('remembers PipeWire and PulseAudio node names', () {
      expect(
        AudioOutputDevice.isPersistableId(
          'pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo',
        ),
        isTrue,
      );
      expect(
        AudioOutputDevice.isPersistableId('pulse/bluez_output.AC_12_2F_00_11'),
        isTrue,
      );
    });

    test('remembers ALSA devices named by card, not by index', () {
      expect(
        AudioOutputDevice.isPersistableId('alsa/sysdefault:CARD=PCH'),
        isTrue,
      );
    });

    test('does not remember numeric ALSA card handles', () {
      // hw:1,0 is a card *index*: plugging in a USB DAC renumbers it, so a
      // stored value would silently route to a different device next boot.
      expect(AudioOutputDevice.isPersistableId('alsa/hw:1,0'), isFalse);
      expect(AudioOutputDevice.isPersistableId('alsa/plughw:2,0'), isFalse);
      expect(AudioOutputDevice.isPersistableId('alsa/hw:0'), isFalse);
    });

    test('does not remember the system default or an empty id', () {
      expect(AudioOutputDevice.isPersistableId('auto'), isFalse);
      expect(AudioOutputDevice.isPersistableId(''), isFalse);
      expect(AudioOutputDevice.isPersistableId('pulse/'), isFalse);
    });
  });
}
