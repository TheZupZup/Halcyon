import 'dart:async';

import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
import 'cast_service.dart';

/// The shipped [CastService]: casting is not reachable in this build, so it
/// honestly reports [CastAvailability.unavailable] and no-ops every command.
///
/// It exists so the now-playing screen can show a real cast button backed by a
/// real (if inert) service, and so swapping in a live backend later is a
/// provider change with no UI edits. It never invents devices or pretends to
/// connect.
///
/// Two situations produce it, told apart by [message]:
///  - the platform has no cast backend (Linux and every non-mobile target),
///    which needs no explanation beyond the UI's own platform copy; and
///  - the security containment ([CastContainment]), which passes
///    [CastContainment.userMessage] so the sheet can say casting is *temporarily*
///    off rather than unsupported here.
class UnavailableCastService implements CastService {
  UnavailableCastService({this.message});

  /// A calm, secret-free explanation for the cast sheet, or null to let the UI
  /// use its own platform wording. Never carries security detail.
  final String? message;

  final StreamController<CastState> _states =
      StreamController<CastState>.broadcast();

  @override
  CastState get state => CastState(message: message);

  @override
  Stream<CastState> get stateStream =>
      Stream<CastState>.value(state).asBroadcastStream();

  @override
  CastPlaybackStatus get playbackStatus => CastPlaybackStatus.idle;

  @override
  Stream<CastPlaybackStatus> get playbackStream =>
      const Stream<CastPlaybackStatus>.empty();

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> connect(CastDevice device) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> volumeUp() async {}

  @override
  Future<void> volumeDown() async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}
