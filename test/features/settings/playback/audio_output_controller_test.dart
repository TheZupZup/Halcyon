import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_output_device.dart';
import 'package:linthra/core/services/audio_output_device_service.dart';
import 'package:linthra/data/repositories/audio_output_device_service_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/audio_output_controller.dart';

/// A stand-in for libmpv: it reports whatever device list the test sets up and
/// records every routing call, so the controller's policy can be asserted
/// without a sound card.
class _FakeService implements AudioOutputDeviceService {
  _FakeService({
    this.isSupported = true,
    List<AudioOutputDevice>? devices,
  }) : available = devices ?? <AudioOutputDevice>[];

  @override
  final bool isSupported;

  List<AudioOutputDevice> available;
  final List<AudioOutputDevice> routed = <AudioOutputDevice>[];
  int enumerations = 0;

  @override
  Future<List<AudioOutputDevice>> devices() async {
    enumerations++;
    return available;
  }

  @override
  Future<void> select(AudioOutputDevice device) async => routed.add(device);
}

void main() {
  const AudioOutputDevice headset = AudioOutputDevice(
    id: 'pipewire/alsa_output.usb-headset',
    label: 'USB Headset',
  );
  const AudioOutputDevice builtIn = AudioOutputDevice(
    id: 'pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo',
    label: 'Built-in Audio',
  );
  const AudioOutputDevice unstable = AudioOutputDevice(
    id: 'alsa/hw:2,0',
    label: 'Some card',
  );

  ProviderContainer containerFor(
    _FakeService service,
    InMemoryPlaybackPreferences preferences,
  ) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        audioOutputDeviceServiceProvider.overrideWithValue(service),
        playbackPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AudioOutputController at startup', () {
    test('does not probe the backend when nothing is saved', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.enumerations, 0);
      expect(service.routed, isEmpty);
      expect(state.selected, AudioOutputDevice.systemDefault);
      expect(state.hasEnumerated, isFalse);
    });

    test('re-applies a saved device that is still there', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[
          AudioOutputDevice.systemDefault,
          builtIn,
          headset,
        ],
      );
      final ProviderContainer container = containerFor(
        service,
        InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id),
      );

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.routed, <AudioOutputDevice>[headset]);
      expect(state.selected, headset);
      expect(state.savedDeviceUnavailable, isFalse);
    });

    test('falls back to the system default when the saved device is gone',
        () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, builtIn],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id);
      final ProviderContainer container = containerFor(service, preferences);

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      // Nothing was routed: playback never left the system default, so there
      // is nothing to move it back to.
      expect(service.routed, isEmpty);
      expect(state.selected, AudioOutputDevice.systemDefault);
      expect(state.savedDeviceUnavailable, isTrue);
      // Forgotten, so the next launch does not keep chasing a name that no
      // longer means anything on this machine.
      expect(await preferences.audioOutputDeviceId(), isNull);
    });

    test('a backend that reports nothing is not treated as "device gone"',
        () async {
      final _FakeService service = _FakeService();
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id);
      final ProviderContainer container = containerFor(service, preferences);

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.routed, isEmpty);
      expect(state.hasEnumerated, isTrue);
      expect(state.devices, isEmpty);
      expect(await preferences.audioOutputDeviceId(), headset.id);
    });

    test('does nothing at all where the platform owns output routing',
        () async {
      final _FakeService service = _FakeService(isSupported: false);
      final ProviderContainer container = containerFor(
        service,
        InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id),
      );

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.enumerations, 0);
      expect(service.routed, isEmpty);
      expect(state.selected, AudioOutputDevice.systemDefault);
    });
  });

  group('AudioOutputController.select', () {
    test('routes playback and remembers a stable device', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences();
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      expect(service.routed, <AudioOutputDevice>[headset]);
      expect(await preferences.audioOutputDeviceId(), headset.id);
      expect(
        container.read(audioOutputControllerProvider).requireValue.selected,
        headset,
      );
    });

    test('applies an unstable device but does not remember it', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, unstable],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences();
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(unstable);

      expect(service.routed, <AudioOutputDevice>[unstable]);
      expect(await preferences.audioOutputDeviceId(), isNull);
      expect(
        container.read(audioOutputControllerProvider).requireValue.isRemembered,
        isFalse,
      );
    });

    test('going back to the system default clears the stored device', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id);
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(AudioOutputDevice.systemDefault);

      expect(
        service.routed,
        <AudioOutputDevice>[headset, AudioOutputDevice.systemDefault],
      );
      expect(await preferences.audioOutputDeviceId(), isNull);
    });

    test('re-picking the output already in use does not re-route', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      expect(service.routed, <AudioOutputDevice>[headset]);
    });
  });

  group('AudioOutputController.refresh', () {
    test('picks up a device that was plugged in after launch', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);

      service.available = <AudioOutputDevice>[
        AudioOutputDevice.systemDefault,
        headset,
      ];
      await container.read(audioOutputControllerProvider.notifier).refresh();

      expect(
        container.read(audioOutputControllerProvider).requireValue.devices,
        contains(headset),
      );
    });

    test('keeps a session-only choice across a refresh', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, unstable],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(unstable);

      await container.read(audioOutputControllerProvider.notifier).refresh();

      // Nothing was stored (the id is unstable), so the refresh must fall back
      // to the live selection rather than looking like a reset.
      expect(
        container.read(audioOutputControllerProvider).requireValue.selected,
        unstable,
      );
    });

    test('reports a chosen device that disappeared while running', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      service.available = <AudioOutputDevice>[AudioOutputDevice.systemDefault];
      await container.read(audioOutputControllerProvider.notifier).refresh();

      final AudioOutputSettingsState state =
          container.read(audioOutputControllerProvider).requireValue;
      expect(state.selected, AudioOutputDevice.systemDefault);
      expect(state.savedDeviceUnavailable, isTrue);
      expect(service.routed.last, AudioOutputDevice.systemDefault);
    });
  });
}
