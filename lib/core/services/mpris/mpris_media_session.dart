import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import '../../models/playback_state.dart';
import '../../repositories/download_repository.dart';
import '../../repositories/favorites_repository.dart';
import '../../repositories/music_library_repository.dart';
import '../../repositories/playlist_repository.dart';
import '../media_artwork_source.dart';
import '../media_session_binding.dart';
import '../playback_controller.dart';
import 'mpris_player_object.dart';

/// Opens a session-bus connection. Injectable so a test never touches a bus.
typedef DBusClientFactory = DBusClient Function();

/// Linthra's MPRIS presence on the session bus: the connection, the well-known
/// name, the exported object, and the subscription that keeps it current.
///
/// [MprisPlayerObject] does the translating; this class does the owning. The
/// split matters for shutdown as much as for testing — a media player that
/// leaves `org.mpris.MediaPlayer2.linthra` on the bus after it exits leaves a
/// ghost in every shell that was listening.
class MprisMediaSession implements MediaSession {
  MprisMediaSession._(
      this._client, this._object, this._subscription, this.name);

  /// The bus name Linthra owns, e.g. `org.mpris.MediaPlayer2.linthra`.
  final String name;

  final DBusClient _client;
  final MprisPlayerObject _object;
  final StreamSubscription<PlaybackState> _subscription;
  bool _detached = false;

  static const String _baseName = 'org.mpris.MediaPlayer2.linthra';

  /// Connects, claims a name, exports the player object and starts mirroring
  /// [controller]. Returns null when there is no usable session bus.
  ///
  /// Best-effort by design: a headless machine, a Flatpak without the bus
  /// socket, or a shell that never shows up are all "no desktop controls", not
  /// "Linthra failed to start". Anything that goes wrong here is unwound before
  /// returning, so a half-connected client never survives a failed attach.
  static Future<MprisMediaSession?> connect(
    PlaybackController controller, {
    MediaArtworkSource? artwork,
    DBusClientFactory clientFactory = DBusClient.session,
    int? processId,
  }) async {
    DBusClient? client;
    try {
      client = clientFactory();
      final String? name = await _claimName(client, processId ?? pid);
      if (name == null) {
        await client.close();
        return null;
      }

      final MprisPlayerObject object =
          MprisPlayerObject(controller, artwork: artwork);
      await client.registerObject(object);

      final MprisMediaSession session = MprisMediaSession._(
        client,
        object,
        // Subscribed after the object is exported so the first notification a
        // shell can receive always describes an object it can already read.
        controller.stateStream.listen(null),
        name,
      );
      session._start(controller);
      return session;
    } catch (_) {
      // Leave nothing half-open behind a failed attach.
      try {
        await client?.close();
      } catch (_) {
        // Closing a client that never connected can throw; ignore.
      }
      return null;
    }
  }

  /// Claims [_baseName], falling back to the spec's per-instance form.
  ///
  /// MPRIS says a player that cannot take the plain name should append
  /// `.instance<pid>`, so a second Linthra window is still individually
  /// controllable instead of silently invisible to every shell.
  static Future<String?> _claimName(DBusClient client, int processId) async {
    for (final String candidate in <String>[
      _baseName,
      '$_baseName.instance$processId',
    ]) {
      final DBusRequestNameReply reply = await client.requestName(
        candidate,
        flags: <DBusRequestNameFlag>{DBusRequestNameFlag.doNotQueue},
      );
      if (reply == DBusRequestNameReply.primaryOwner ||
          reply == DBusRequestNameReply.alreadyOwner) {
        return candidate;
      }
    }
    return null;
  }

  /// Mirrors [controller] onto the bus, one `PropertiesChanged` per real change.
  ///
  /// Diffed rather than emitted per tick: the state stream also carries position
  /// updates, and a signal several times a second per listening shell is exactly
  /// the kind of chatter that makes a player unpleasant to have on a desktop.
  /// `Position` is not in the diff at all — the spec has shells extrapolate it
  /// and listen for `Seeked` instead, which the player object emits.
  void _start(PlaybackController controller) {
    Map<String, DBusValue> previous =
        _object.properties(MprisPlayerObject.playerInterface);

    _subscription.onData((PlaybackState _) {
      final Map<String, DBusValue> current =
          _object.properties(MprisPlayerObject.playerInterface);
      final Map<String, DBusValue> changed = <String, DBusValue>{};
      for (final MapEntry<String, DBusValue> entry in current.entries) {
        if (entry.key == 'Position') continue;
        if (previous[entry.key] != entry.value) {
          changed[entry.key] = entry.value;
        }
      }
      previous = current;
      if (changed.isEmpty) return;
      unawaited(_emit(changed));
    });
  }

  Future<void> _emit(Map<String, DBusValue> changed) async {
    if (_detached) return;
    try {
      await _object.emitPropertiesChanged(
        MprisPlayerObject.playerInterface,
        changedProperties: changed,
      );
    } catch (_) {
      // A shell that vanished, or a bus that went away, must not take playback
      // down with it.
    }
  }

  /// Releases the name, unexports the object and closes the connection.
  ///
  /// Idempotent and never throws: shutdown runs it best-effort alongside every
  /// other teardown step.
  @override
  Future<void> detach() async {
    if (_detached) return;
    _detached = true;
    await _guard(_subscription.cancel);
    await _guard(() => _client.unregisterObject(_object));
    await _guard(() => _client.releaseName(name));
    await _guard(_client.close);
  }

  static Future<void> _guard(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      // Best-effort: one failed step must not skip the ones behind it.
    }
  }
}

/// The Linux [MediaSessionBinding]: MPRIS, or nothing at all.
///
/// Mirrors [AudioServiceMediaSessionBinding]'s shape so
/// [PlatformMediaSessionBinding] routes to it exactly the way it routes to
/// Android's — and so `audio_service` stays untouched on desktop.
class MprisMediaSessionBinding implements MediaSessionBinding {
  const MprisMediaSessionBinding({
    DBusClientFactory clientFactory = DBusClient.session,
  }) : _clientFactory = clientFactory;

  final DBusClientFactory _clientFactory;

  @override
  bool get isSupported => true;

  @override
  Future<MediaSession?> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
  }) {
    // The repositories are Android Auto's browse tree. MPRIS has no browsing —
    // `HasTrackList` is false — so they are deliberately unused here.
    return MprisMediaSession.connect(
      controller,
      artwork: artwork,
      clientFactory: _clientFactory,
    );
  }
}
