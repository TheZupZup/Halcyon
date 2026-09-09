/// One audio output Linthra can send playback to.
///
/// The [id] is the backend's own device name — on Linux that is libmpv's
/// `audio-device` value, e.g. `pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo`.
/// It is what gets written back to the backend, so it is never localized,
/// prettified or rebuilt from [label].
///
/// [label] is what the listener reads. Backends hand out a description that is
/// usually already human-readable ("Built-in Audio Analog Stereo"); when one is
/// missing, [audioOutputDevicesFromBackend] falls back to the device part of the
/// id rather than showing an empty row.
class AudioOutputDevice {
  const AudioOutputDevice({required this.id, required this.label});

  /// The backend's device name. `auto` means "let the system decide".
  final String id;

  /// The human-readable name shown in Settings.
  final String label;

  /// libmpv's name for "let the system decide", and the value Linthra falls
  /// back to whenever a chosen device is gone.
  static const String systemDefaultId = 'auto';

  /// The always-available choice. Linthra never persists it: no stored value
  /// already means "system default", so an absent preference and this entry are
  /// the same state.
  static const AudioOutputDevice systemDefault = AudioOutputDevice(
    id: systemDefaultId,
    label: 'System default',
  );

  bool get isSystemDefault => id == systemDefaultId;

  /// Whether [id] is stable enough to remember across restarts.
  ///
  /// PipeWire and PulseAudio node names are derived from the hardware path
  /// (`pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo`,
  /// `pulse/bluez_output.AC_12_2F_...`) and name the same sink after a reboot.
  /// ALSA's numeric handles do not: `alsa/hw:1,0` is a card *index*, and
  /// plugging in a USB DAC or a dock renumbers the cards, so a stored one can
  /// silently point at a different device. Those stay a session-only choice —
  /// the user can still pick them, Linthra just does not remember them.
  static bool isPersistableId(String id) {
    if (id.isEmpty || id == systemDefaultId) return false;
    final int separator = id.indexOf('/');
    final String device = separator < 0 ? id : id.substring(separator + 1);
    if (device.isEmpty) return false;
    return !_numericAlsaHandle.hasMatch(device);
  }

  /// `hw:1`, `hw:1,0`, `plughw:2,0` — ALSA card/device *indexes*.
  static final RegExp _numericAlsaHandle = RegExp(r'^(plug)?hw:\d+(,\d+)*$');

  @override
  bool operator ==(Object other) =>
      other is AudioOutputDevice && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'AudioOutputDevice($id, $label)';
}

/// Maps a backend's raw device list onto Linthra's model.
///
/// Kept as a plain function over `(id, description)` records so the mapping —
/// the part with actual rules in it — is unit-testable without libmpv on the
/// machine running the tests.
///
/// The rules:
///  - [AudioOutputDevice.systemDefault] is always first and always present,
///    even on a backend that does not list `auto` itself, because it is the
///    safe choice the UI must always be able to offer.
///  - a device with no description is labelled with the device part of its id,
///    so a row is never blank.
///  - duplicate ids collapse to the first entry; some backends list the same
///    sink through more than one alias.
List<AudioOutputDevice> audioOutputDevicesFromBackend(
  Iterable<({String id, String description})> entries,
) {
  final List<AudioOutputDevice> devices = <AudioOutputDevice>[
    AudioOutputDevice.systemDefault,
  ];
  final Set<String> seen = <String>{AudioOutputDevice.systemDefaultId};

  for (final ({String id, String description}) entry in entries) {
    final String id = entry.id.trim();
    if (id.isEmpty || !seen.add(id)) continue;
    devices.add(
      AudioOutputDevice(id: id, label: _labelFor(id, entry.description)),
    );
  }
  return devices;
}

String _labelFor(String id, String description) {
  final String trimmed = description.trim();
  if (trimmed.isNotEmpty) return trimmed;
  final int separator = id.indexOf('/');
  final String device = separator < 0 ? id : id.substring(separator + 1);
  return device.isEmpty ? id : device;
}
