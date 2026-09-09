import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/audio_output_device.dart';
import '../../../core/services/audio_output_device_service.dart';
import '../../../data/repositories/audio_output_device_service_provider.dart';
import '../../../data/repositories/playback_preferences_provider.dart';

/// What the "Audio output" card shows.
class AudioOutputSettingsState {
  const AudioOutputSettingsState({
    this.devices = const <AudioOutputDevice>[],
    this.selected = AudioOutputDevice.systemDefault,
    this.hasEnumerated = false,
    this.savedDeviceUnavailable = false,
  });

  /// The outputs the host offers, system default first. Empty either because
  /// nothing has been enumerated yet ([hasEnumerated] false) or because the
  /// backend reported none.
  final List<AudioOutputDevice> devices;

  /// The output playback is currently routed to.
  final AudioOutputDevice selected;

  /// Whether the device list has been asked for at least once.
  final bool hasEnumerated;

  /// Whether a previously chosen output was missing at startup, so playback
  /// fell back to the system default. Surfaced once, then cleared on the next
  /// choice.
  final bool savedDeviceUnavailable;

  /// Whether [selected] will still be in effect after a restart. False for the
  /// system default (there is nothing to remember) and for devices named by an
  /// unstable handle, which Linthra deliberately does not store.
  bool get isRemembered => AudioOutputDevice.isPersistableId(selected.id);

  AudioOutputSettingsState copyWith({
    List<AudioOutputDevice>? devices,
    AudioOutputDevice? selected,
    bool? hasEnumerated,
    bool? savedDeviceUnavailable,
  }) {
    return AudioOutputSettingsState(
      devices: devices ?? this.devices,
      selected: selected ?? this.selected,
      hasEnumerated: hasEnumerated ?? this.hasEnumerated,
      savedDeviceUnavailable:
          savedDeviceUnavailable ?? this.savedDeviceUnavailable,
    );
  }
}

/// Owns the "Audio output" choice: which device playback is routed to, and
/// whether that choice is remembered.
///
/// The routing itself lives in [AudioOutputDeviceService]; this notifier holds
/// the policy around it, which is the part worth testing:
///
///  * a stored device is re-applied on launch, so the choice survives a restart
///    without the user re-picking it;
///  * a stored device that is *not* in the list any more (unplugged headset,
///    another machine, a renamed sink) is dropped rather than pushed at the
///    backend, and playback stays on the system default;
///  * a device whose id will not survive a reboot is applied but not stored,
///    so nothing silently routes to a different card next boot.
///
/// [build] is deliberately cheap when nothing is stored: it does not enumerate,
/// so launching the app never probes the audio backend just to confirm the
/// default. The Settings card calls [refresh] when it is opened.
class AudioOutputController extends AsyncNotifier<AudioOutputSettingsState> {
  /// The output currently pushed at the backend. It starts as the system
  /// default because that is what a fresh process is already on, and it is what
  /// keeps a refresh from re-routing audio it has not been asked to move.
  String _appliedId = AudioOutputDevice.systemDefaultId;

  @override
  Future<AudioOutputSettingsState> build() async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return const AudioOutputSettingsState();

    final String? storedId =
        await ref.read(playbackPreferencesProvider).audioOutputDeviceId();
    if (storedId == null) return const AudioOutputSettingsState();

    return _resolve(storedId);
  }

  /// Re-reads the host's output list and re-applies the current choice.
  ///
  /// Called when the Settings card is opened and by its refresh action, so a
  /// device plugged in while the app was running shows up.
  Future<void> refresh() async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return;

    final AudioOutputSettingsState current =
        state.valueOrNull ?? const AudioOutputSettingsState();
    state = const AsyncValue<AudioOutputSettingsState>.loading()
        .copyWithPrevious(state);
    state = await AsyncValue.guard(() async {
      final String? storedId =
          await ref.read(playbackPreferencesProvider).audioOutputDeviceId();
      // Fall back to the live selection when nothing is stored: a device picked
      // by an unstable id is session-only, and refreshing the list must not
      // look like the user reset it to the system default.
      return _resolve(storedId ?? current.selected.id);
    });
  }

  /// Routes playback to [device] and remembers it when its id is stable.
  Future<void> select(AudioOutputDevice device) async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return;

    await _apply(device);
    await ref.read(playbackPreferencesProvider).setAudioOutputDeviceId(
          AudioOutputDevice.isPersistableId(device.id) ? device.id : null,
        );

    final AudioOutputSettingsState current =
        state.valueOrNull ?? const AudioOutputSettingsState();
    state = AsyncData<AudioOutputSettingsState>(
      current.copyWith(selected: device, savedDeviceUnavailable: false),
    );
  }

  /// Routes to [device] unless the backend is already on it.
  ///
  /// Re-asking for the output that is already in use would make every refresh
  /// (and every launch on a machine that never changed its output) a routing
  /// call into libmpv for no reason.
  Future<void> _apply(AudioOutputDevice device) async {
    if (device.id == _appliedId) return;
    await ref.read(audioOutputDeviceServiceProvider).select(device);
    _appliedId = device.id;
  }

  Future<AudioOutputSettingsState> _resolve(String desiredId) async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    final List<AudioOutputDevice> devices = await service.devices();

    if (devices.isEmpty) {
      // The backend could not be asked. That is not evidence the chosen device
      // is gone, so nothing is cleared and nothing is re-routed — the card just
      // reports that it found no outputs.
      return const AudioOutputSettingsState(hasEnumerated: true);
    }

    for (final AudioOutputDevice device in devices) {
      if (device.id != desiredId) continue;
      await _apply(device);
      return AudioOutputSettingsState(
        devices: devices,
        selected: device,
        hasEnumerated: true,
      );
    }

    // The chosen output is not on this machine any more. Fall back to the
    // system default and forget it, so the next launch does not keep trying a
    // name that no longer means anything.
    final bool wasStored = desiredId != AudioOutputDevice.systemDefaultId;
    if (wasStored) {
      await ref.read(playbackPreferencesProvider).setAudioOutputDeviceId(null);
      await _apply(AudioOutputDevice.systemDefault);
    }
    return AudioOutputSettingsState(
      devices: devices,
      hasEnumerated: true,
      savedDeviceUnavailable: wasStored,
    );
  }
}

final audioOutputControllerProvider =
    AsyncNotifierProvider<AudioOutputController, AudioOutputSettingsState>(
  AudioOutputController.new,
);
