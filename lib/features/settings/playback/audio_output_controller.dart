import 'dart:async';

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
    this.selectionFailed = false,
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

  /// Whether the last attempt to route audio was refused by the backend, so
  /// playback is still on [selected]. Cleared by the next successful choice.
  final bool selectionFailed;

  /// Whether [selected] will still be in effect after a restart. False for the
  /// system default (there is nothing to remember) and for devices named by an
  /// unstable handle, which Linthra deliberately does not store.
  bool get isRemembered => AudioOutputDevice.isPersistableId(selected.id);

  AudioOutputSettingsState copyWith({
    List<AudioOutputDevice>? devices,
    AudioOutputDevice? selected,
    bool? hasEnumerated,
    bool? savedDeviceUnavailable,
    bool? selectionFailed,
  }) {
    return AudioOutputSettingsState(
      devices: devices ?? this.devices,
      selected: selected ?? this.selected,
      hasEnumerated: hasEnumerated ?? this.hasEnumerated,
      savedDeviceUnavailable:
          savedDeviceUnavailable ?? this.savedDeviceUnavailable,
      selectionFailed: selectionFailed ?? this.selectionFailed,
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
///    so nothing silently routes to a different card next boot;
///  * a backend that could not be enumerated, or that refused a switch, changes
///    nothing — neither what is stored nor what is shown as playing.
///
/// [build] is deliberately cheap when nothing is stored: it does not enumerate,
/// so launching the app never probes the audio backend just to confirm the
/// default. The Settings card calls [refresh] when it is opened.
class AudioOutputController extends AsyncNotifier<AudioOutputSettingsState> {
  /// The output currently pushed at the backend. It starts as the system
  /// default because that is what a fresh process is already on, and it is what
  /// keeps a refresh from re-routing audio it has not been asked to move. It
  /// only ever advances on a switch the backend accepted, so a refused one is
  /// retried rather than assumed done.
  String _appliedId = AudioOutputDevice.systemDefaultId;

  /// Serializes [select] and [refresh].
  ///
  /// Both route audio, write the preference and publish state. Two of them in
  /// flight at once can finish in the opposite order and leave playback on the
  /// output the listener picked *first*, so they queue instead: the last
  /// gesture is the last one applied.
  Future<void> _operations = Future<void>.value();

  @override
  Future<AudioOutputSettingsState> build() async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return const AudioOutputSettingsState();

    final String? storedId =
        await ref.read(playbackPreferencesProvider).audioOutputDeviceId();
    if (storedId == null) return const AudioOutputSettingsState();

    // Nothing has been routed yet, so the system default is what is playing.
    return _resolve(storedId, AudioOutputDevice.systemDefault);
  }

  /// Re-reads the host's output list and re-applies the current choice.
  ///
  /// Called when the Settings card is opened and by its refresh action, so a
  /// device plugged in while the app was running shows up.
  Future<void> refresh() async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return;

    return _enqueue(() async {
      // Let an in-flight build settle first: Riverpod publishes its result when
      // it completes, which would land on top of everything below.
      try {
        await future;
      } catch (_) {
        // A failed build is not this refresh's problem; it re-enumerates below.
      }

      final AudioOutputSettingsState current =
          state.valueOrNull ?? const AudioOutputSettingsState();
      state = const AsyncValue<AudioOutputSettingsState>.loading()
          .copyWithPrevious(state);
      state = await AsyncValue.guard(() async {
        final String? storedId =
            await ref.read(playbackPreferencesProvider).audioOutputDeviceId();
        // Fall back to the live selection when nothing is stored: a device
        // picked by an unstable id is session-only, and refreshing the list
        // must not look like the user reset it to the system default.
        final AudioOutputSettingsState resolved =
            await _resolve(storedId ?? current.selected.id, current.selected);
        // Carry the "your saved output is gone" notice across a refresh. By
        // the time the card is opened the stored id has already been dropped,
        // so re-deriving the flag here would always come back false and quietly
        // erase the one explanation the listener has for why playback moved.
        // The next explicit choice clears it.
        return resolved.copyWith(
          savedDeviceUnavailable:
              resolved.savedDeviceUnavailable || current.savedDeviceUnavailable,
        );
      });
    });
  }

  /// Routes playback to [device] and remembers it when its id is stable.
  Future<void> select(AudioOutputDevice device) async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return;

    return _enqueue(() async {
      state = const AsyncValue<AudioOutputSettingsState>.loading()
          .copyWithPrevious(state);
      final AudioOutputSettingsState current =
          state.valueOrNull ?? const AudioOutputSettingsState();

      if (!await _apply(device)) {
        // The backend refused — the device disappeared between the list and the
        // tap. Playback is still where it was, so nothing is stored and nothing
        // is shown as switched; the card says the switch did not happen.
        state = AsyncData<AudioOutputSettingsState>(
          current.copyWith(selectionFailed: true),
        );
        return;
      }

      await ref.read(playbackPreferencesProvider).setAudioOutputDeviceId(
            AudioOutputDevice.isPersistableId(device.id) ? device.id : null,
          );
      state = AsyncData<AudioOutputSettingsState>(
        current.copyWith(
          selected: device,
          savedDeviceUnavailable: false,
          selectionFailed: false,
        ),
      );
    });
  }

  /// Runs [operation] after every operation already queued.
  Future<void> _enqueue(Future<void> Function() operation) {
    final Future<void> queued = _operations.then((_) => operation());
    // The chain swallows failures so one refused switch cannot wedge every
    // later choice; the caller still sees the original future.
    _operations = queued.then((_) {}, onError: (Object _) {});
    return queued;
  }

  /// Routes to [device] unless the backend is already on it, reporting whether
  /// the backend is on it afterwards.
  ///
  /// Re-asking for the output already in use would make every refresh (and
  /// every launch on a machine that never changed its output) a routing call
  /// into libmpv for no reason.
  Future<bool> _apply(AudioOutputDevice device) async {
    if (device.id == _appliedId) return true;
    if (!await ref.read(audioOutputDeviceServiceProvider).select(device)) {
      return false;
    }
    _appliedId = device.id;
    return true;
  }

  Future<AudioOutputSettingsState> _resolve(
    String desiredId,
    AudioOutputDevice currentSelection,
  ) async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    final List<AudioOutputDevice> devices = await service.devices();

    if (devices.isEmpty) {
      // The backend could not be asked. That is not evidence the chosen device
      // is gone, so nothing is cleared, nothing is re-routed, and the live
      // selection is kept — dropping it here would make the *next* refresh
      // route away from an output the listener is still using. The card just
      // reports that it found no outputs.
      return AudioOutputSettingsState(
        selected: currentSelection,
        hasEnumerated: true,
      );
    }

    for (final AudioOutputDevice device in devices) {
      if (device.id != desiredId) continue;
      final bool routed = await _apply(device);
      return AudioOutputSettingsState(
        devices: devices,
        selected: routed ? device : currentSelection,
        hasEnumerated: true,
        selectionFailed: !routed,
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
