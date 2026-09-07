import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/mpris/mpris_media_session.dart';
import 'package:linthra/core/services/mpris/mpris_player_object.dart';

import '../../../features/player/fake_playback_controller.dart';

/// One signal the object asked the bus to send.
class _Signal {
  _Signal(this.interface, this.name, this.values);

  final String interface;
  final String name;
  final List<DBusValue> values;
}

/// A [DBusClient] that answers like a bus without being one.
///
/// Subclassed rather than mocked because `DBusClient` is a concrete class, and
/// its constructor is lazy — nothing connects until a method is called, and
/// every method a session touches is overridden here. So these tests exercise
/// the real ownership code (claim, export, subscribe, release) with no session
/// bus, no daemon, and no leftover name on a developer's desktop.
class _FakeBus extends DBusClient {
  _FakeBus({this.takenNames = const <String>{}})
      : super(DBusAddress('unix:path=/nonexistent/linthra-test-bus'));

  /// Names some other client already owns.
  final Set<String> takenNames;

  final List<String> requestedNames = <String>[];
  final List<String> releasedNames = <String>[];
  final List<DBusObject> registered = <DBusObject>[];
  final List<DBusObject> unregistered = <DBusObject>[];
  final List<_Signal> signals = <_Signal>[];
  int closeCalls = 0;

  @override
  Future<DBusRequestNameReply> requestName(
    String name, {
    Set<DBusRequestNameFlag> flags = const <DBusRequestNameFlag>{},
  }) async {
    requestedNames.add(name);
    return takenNames.contains(name)
        ? DBusRequestNameReply.exists
        : DBusRequestNameReply.primaryOwner;
  }

  @override
  Future<DBusReleaseNameReply> releaseName(String name) async {
    releasedNames.add(name);
    return DBusReleaseNameReply.released;
  }

  @override
  Future<void> registerObject(DBusObject object) async {
    object.client = this;
    registered.add(object);
  }

  @override
  Future<void> unregisterObject(DBusObject object) async {
    unregistered.add(object);
    object.client = null;
  }

  @override
  Future<void> emitSignal({
    String? destination,
    required DBusObjectPath path,
    required String interface,
    required String name,
    Iterable<DBusValue> values = const <DBusValue>[],
  }) async {
    signals.add(_Signal(interface, name, values.toList()));
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

/// A bus that cannot be reached at all — a headless machine, a container, or a
/// Flatpak without the session-bus socket.
DBusClient _noBus() => throw const SocketException('no session bus');

Track _track(String id) => Track(id: id, title: id, uri: '/music/$id.flac');

void main() {
  late FakePlaybackController controller;

  setUp(() {
    controller = FakePlaybackController();
  });

  tearDown(() async {
    await controller.dispose();
  });

  group('connecting', () {
    test('claims the MPRIS name and exports the player object', () async {
      final _FakeBus bus = _FakeBus();

      final MprisMediaSession? session = await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
      );

      expect(session, isNotNull);
      expect(session!.name, 'org.mpris.MediaPlayer2.linthra');
      expect(bus.registered.single.path,
          DBusObjectPath('/org/mpris/MediaPlayer2'));
      await session.detach();
    });

    test('falls back to the per-instance name when the plain one is taken',
        () async {
      // A second Linthra window: the spec says append .instance<pid> rather
      // than give up, so each is still individually controllable.
      final _FakeBus bus = _FakeBus(
        takenNames: <String>{'org.mpris.MediaPlayer2.linthra'},
      );

      final MprisMediaSession? session = await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
        processId: 4242,
      );

      expect(session!.name, 'org.mpris.MediaPlayer2.linthra.instance4242');
      expect(bus.requestedNames, <String>[
        'org.mpris.MediaPlayer2.linthra',
        'org.mpris.MediaPlayer2.linthra.instance4242',
      ]);
      await session.detach();
    });

    test('no session bus means no session, not a failed startup', () async {
      expect(
        await MprisMediaSession.connect(controller, clientFactory: _noBus),
        isNull,
      );
    });

    test('a bus that refuses every name leaves nothing open', () async {
      final _FakeBus bus = _FakeBus(
        takenNames: <String>{
          'org.mpris.MediaPlayer2.linthra',
          'org.mpris.MediaPlayer2.linthra.instance7',
        },
      );

      final MprisMediaSession? session = await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
        processId: 7,
      );

      expect(session, isNull);
      expect(bus.registered, isEmpty);
      expect(bus.closeCalls, 1,
          reason: 'a client that claimed nothing must not stay open');
    });
  });

  group('mirroring playback', () {
    late _FakeBus bus;
    late MprisMediaSession session;

    setUp(() async {
      bus = _FakeBus();
      session = (await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
      ))!;
    });

    tearDown(() async {
      await session.detach();
    });

    List<_Signal> propertiesChanged() => bus.signals
        .where((_Signal s) => s.name == 'PropertiesChanged')
        .toList();

    test('a track change tells the bus what changed', () async {
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
        duration: const Duration(minutes: 3),
      ));
      await pumpEventQueue();

      final _Signal signal = propertiesChanged().single;
      expect(signal.values.first,
          const DBusString(MprisPlayerObject.playerInterface));
      final Map<DBusValue, DBusValue> changed =
          (signal.values[1] as DBusDict).children;
      expect(changed.containsKey(const DBusString('Metadata')), isTrue);
      expect(changed.containsKey(const DBusString('PlaybackStatus')), isTrue);
    });

    test('a position tick alone says nothing', () async {
      // The state stream fires several times a second while playing. One signal
      // per tick, per listening shell, is what makes a player unpleasant to
      // have on a desktop — and the spec has shells extrapolate Position
      // themselves precisely so it is not needed.
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
        duration: const Duration(minutes: 3),
      ));
      await pumpEventQueue();
      final int afterTrackChange = propertiesChanged().length;

      for (int second = 1; second <= 5; second++) {
        controller.emit(PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track('a'),
          duration: const Duration(minutes: 3),
          position: Duration(seconds: second),
        ));
      }
      await pumpEventQueue();

      expect(propertiesChanged().length, afterTrackChange);
    });

    test('pausing is a change worth publishing', () async {
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
      ));
      await pumpEventQueue();
      final int afterPlay = propertiesChanged().length;

      controller.emit(PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: _track('a'),
      ));
      await pumpEventQueue();

      expect(propertiesChanged().length, afterPlay + 1);
    });
  });

  group('cleanup', () {
    test('detach gives the name back and closes the connection', () async {
      final _FakeBus bus = _FakeBus();
      final MprisMediaSession session = (await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
      ))!;

      await session.detach();

      expect(bus.unregistered, hasLength(1));
      expect(bus.releasedNames, <String>['org.mpris.MediaPlayer2.linthra']);
      expect(bus.closeCalls, 1);
    });

    test('detaching twice is not a second teardown', () async {
      final _FakeBus bus = _FakeBus();
      final MprisMediaSession session = (await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
      ))!;

      await session.detach();
      await session.detach();

      expect(bus.closeCalls, 1);
      expect(bus.releasedNames, hasLength(1));
    });

    test('a detached session stops talking to the bus', () async {
      // The point of cancelling the subscription: playback outlives the session
      // during shutdown, and a signal emitted on a closed connection is at best
      // noise and at worst an unhandled error on the way out.
      final _FakeBus bus = _FakeBus();
      final MprisMediaSession session = (await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
      ))!;

      await session.detach();
      final int signalsAtDetach = bus.signals.length;

      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('after-shutdown'),
      ));
      await pumpEventQueue();

      expect(bus.signals, hasLength(signalsAtDetach));
    });
  });
}
