import '../models/audio_output_device.dart';

/// Lists the audio outputs the host offers and moves playback onto one of them.
///
/// This is a *routing* seam, not a playback one: it never starts, stops or
/// re-loads a track. On Linux the implementation drives libmpv's `audio-device`
/// through media_kit, so switching moves the audio that is already playing.
///
/// Android is deliberately not implemented here. Output routing there belongs to
/// the platform (the system output picker, Bluetooth, Android Auto), and the app
/// must not fight it — so Android gets [NoopAudioOutputDeviceService] and the
/// Settings card is simply not shown, exactly like "Share Linthra" off Android.
///
/// Implementations must never throw into the UI. A backend that is not ready,
/// a device that disappeared mid-switch, or a host with no enumeration at all
/// all end as "no devices" / "nothing happened", never as an error dialog.
abstract interface class AudioOutputDeviceService {
  /// Whether this build can enumerate and choose an output. `false` off Linux
  /// (and in tests), so the UI can hide the card rather than offer a control
  /// that does nothing.
  bool get isSupported;

  /// The outputs the host currently offers, [AudioOutputDevice.systemDefault]
  /// first. Empty when nothing could be enumerated.
  Future<List<AudioOutputDevice>> devices();

  /// Routes playback to [device].
  ///
  /// Applies to audio that is already playing *and* to the next player the
  /// engine creates, so the choice survives a stop/start without being
  /// re-applied by the caller. Passing [AudioOutputDevice.systemDefault] hands
  /// the decision back to the system.
  Future<void> select(AudioOutputDevice device);
}
