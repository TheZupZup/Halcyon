import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/media_artwork_source.dart';
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

  /// What happened, in order. The object has to reach the bus before the name
  /// does, and only a sequence can assert that.
  final List<String> order = <String>[];
  int closeCalls = 0;

  /// Refuses every name, however many candidates are tried. Needed now that
  /// the fallback keeps going with random suffixes, so a fixed set of taken
  /// names can no longer exhaust it.
  bool refuseAll = false;

  @override
  Future<DBusRequestNameReply> requestName(
    String name, {
    Set<DBusRequestNameFlag> flags = const <DBusRequestNameFlag>{},
  }) async {
    requestedNames.add(name);
    order.add('name');
    return refuseAll || takenNames.contains(name)
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
    order.add('register');
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

Track _track(String id, {Uri? artworkUri}) =>
    Track(id: id, title: id, uri: '/music/$id.flac', artworkUri: artworkUri);

/// An artwork cache whose covers can be warmed mid-test, so the session's
/// reaction to a late-arriving cover is observable without a real prewarm.
class _Artwork implements MediaArtworkSource {
  final Map<Uri, Uri> _cache = <Uri, Uri>{};
  final StreamController<Uri> _ready = StreamController<Uri>.broadcast();

  void warm(Uri reference, Uri local) {
    _cache[reference] = local;
    _ready.add(reference);
  }

  @override
  Uri? cached(Uri reference) => _cache[reference];

  @override
  Uri? cachedFileUri(Uri reference) => _cache[reference];

  @override
  Stream<Uri> get coverReady => _ready.stream;
}

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
      final _FakeBus bus = _FakeBus()..refuseAll = true;

      final MprisMediaSession? session = await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
        processId: 7,
      );

      expect(session, isNull);
      // The object is exported before the name is claimed, so that a shell
      // reacting to NameOwnerChanged never introspects an object that does not
      // exist yet. When no name can be had, that export has to be taken back.
      expect(bus.registered, hasLength(1));
      expect(bus.unregistered, hasLength(1),
          reason: 'an export must not outlive the attach that failed');
      expect(bus.closeCalls, 1,
          reason: 'a client that claimed nothing must not stay open');
    });

    test('a taken pid name still yields a usable one', () async {
      // Each Flatpak instance has its own pid namespace, so two sandboxed
      // windows can genuinely both be pid 2, and the runner allows several
      // instances. If the pid name is taken too, falling back to nothing would
      // leave that window with no media controls at all.
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
      addTearDown(() async => session?.detach());

      expect(session, isNotNull);
      expect(session!.name, startsWith('org.mpris.MediaPlayer2.linthra.'),
          reason: 'the Flatpak grant only covers Linthra\'s own names');
      expect(bus.takenNames, isNot(contains(session.name)));
    });

    test('the object is exported before the name is claimed', () async {
      // Claiming first leaves a window where the name is on the bus and
      // /org/mpris/MediaPlayer2 is not, so an introspect from a watching shell
      // answers UnknownObject and Linthra silently never appears in it.
      final _FakeBus bus = _FakeBus();

      final MprisMediaSession? session = await MprisMediaSession.connect(
        controller,
        clientFactory: () => bus,
        processId: 7,
      );
      addTearDown(() async => session?.detach());

      expect(session, isNotNull);
      expect(bus.order.indexOf('register'), lessThan(bus.order.indexOf('name')),
          reason: 'registerObject must precede requestName, order was '
              '\${bus.order}');
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

    test('a cover that finishes warming republishes Metadata', () async {
      // The prewarm is asynchronous, so a track is often published before its
      // cover is cached. The diff loop only runs on a playback state, so a
      // cover landing while paused would otherwise stay missing from the
      // shell's card for the whole pause.
      final _Artwork artwork = _Artwork();
      final _FakeBus warmBus = _FakeBus();
      final MprisMediaSession warmed = (await MprisMediaSession.connect(
        controller,
        artwork: artwork,
        clientFactory: () => warmBus,
      ))!;
      addTearDown(warmed.detach);

      final Uri reference = Uri.parse('subsonic-cover:42');
      controller.emit(PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: _track('a', artworkUri: reference),
      ));
      await pumpEventQueue();
      final int before = warmBus.signals
          .where((_Signal s) => s.name == 'PropertiesChanged')
          .length;

      artwork.warm(reference, Uri.file('/cache/42.img'));
      await pumpEventQueue();

      final List<_Signal> changed = warmBus.signals
          .where((_Signal s) => s.name == 'PropertiesChanged')
          .toList();
      expect(changed, hasLength(before + 1),
          reason:
              'the cached cover must reach the bus without a playback tick');
      final Map<DBusValue, DBusValue> props =
          (changed.last.values[1] as DBusDict).children;
      expect(props.containsKey(const DBusString('Metadata')), isTrue);
    });

    test('a cover landing just before a state change does not swallow it',
        () async {
      // The cover callback emits only Metadata, so it must move only that
      // baseline. Marking every property as published would make the state
      // callback right behind it see no differences, and a shell would keep
      // stale controls (CanGoNext, PlaybackStatus) for as long as they stayed
      // unchanged after that.
      final _Artwork artwork = _Artwork();
      final _FakeBus raceBus = _FakeBus();
      final MprisMediaSession raced = (await MprisMediaSession.connect(
        controller,
        artwork: artwork,
        clientFactory: () => raceBus,
      ))!;
      addTearDown(raced.detach);

      final Uri reference = Uri.parse('subsonic-cover:42');
      controller.emit(PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: _track('a', artworkUri: reference),
      ));
      await pumpEventQueue();

      // The cover lands, and the playback state changes right after it.
      artwork.warm(reference, Uri.file('/cache/42.img'));
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a', artworkUri: reference),
        upNext: <Track>[_track('b')],
      ));
      await pumpEventQueue();

      final Set<String> published = <String>{
        for (final _Signal s in raceBus.signals
            .where((_Signal s) => s.name == 'PropertiesChanged'))
          ...(s.values[1] as DBusDict)
              .children
              .keys
              .map((DBusValue k) => (k as DBusString).value),
      };
      expect(published, contains('PlaybackStatus'),
          reason: 'the state change behind the cover must still be published');
      expect(published, contains('CanGoNext'));
    });

    test('an in-app seek is announced with Seeked', () async {
      // A seek from Linthra's own progress bar calls the controller directly
      // and reaches MPRIS only as a moved position. Without this the shell
      // keeps extrapolating from the old one and its progress bar silently
      // disagrees with the app until the track changes.
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
        duration: const Duration(minutes: 5),
        position: const Duration(seconds: 10),
      ));
      await pumpEventQueue();
      final int before =
          bus.signals.where((_Signal s) => s.name == 'Seeked').length;

      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
        duration: const Duration(minutes: 5),
        position: const Duration(minutes: 2),
      ));
      await pumpEventQueue();

      final List<_Signal> seeked =
          bus.signals.where((_Signal s) => s.name == 'Seeked').toList();
      expect(seeked, hasLength(before + 1));
      expect(seeked.last.values.single,
          DBusInt64(const Duration(minutes: 2).inMicroseconds));
    });

    test('leaving a stall resyncs the shell with a Seeked', () async {
      // PlaybackStatus stays Playing through a stall so the card does not
      // flicker, which means shells extrapolated Position the whole time the
      // engine was frozen. The ticks resuming afterwards are ordinary steps the
      // tolerance would never notice, so without this the bar stays ahead by
      // the length of the stall until the next track.
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
        duration: const Duration(minutes: 5),
        position: const Duration(seconds: 30),
      ));
      await pumpEventQueue();
      controller.emit(PlaybackState(
        status: PlaybackStatus.buffering,
        currentTrack: _track('a'),
        duration: const Duration(minutes: 5),
        position: const Duration(seconds: 30),
      ));
      await pumpEventQueue();
      final int before =
          bus.signals.where((_Signal s) => s.name == 'Seeked').length;

      // Recovery: the engine resumes from where it froze, one ordinary tick on.
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
        duration: const Duration(minutes: 5),
        position: const Duration(seconds: 30, milliseconds: 250),
      ));
      await pumpEventQueue();

      final List<_Signal> seeked =
          bus.signals.where((_Signal s) => s.name == 'Seeked').toList();
      expect(seeked, hasLength(before + 1),
          reason: 'the shell has to be pulled back to the real position');
      expect(
          seeked.last.values.single,
          DBusInt64(
              const Duration(seconds: 30, milliseconds: 250).inMicroseconds));
    });

    test('ordinary progress is not mistaken for a seek', () async {
      // Position ticks while playing. Announcing every one of those as a seek
      // would be exactly the chatter Seeked exists to avoid.
      for (int second = 10; second < 15; second++) {
        controller.emit(PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track('a'),
          duration: const Duration(minutes: 5),
          position: Duration(seconds: second),
        ));
        await pumpEventQueue();
      }

      expect(bus.signals.where((_Signal s) => s.name == 'Seeked'), isEmpty);
    });

    test('a track change is not a seek', () async {
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('a'),
        position: const Duration(minutes: 3),
      ));
      await pumpEventQueue();
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track('b'),
        position: Duration.zero,
      ));
      await pumpEventQueue();

      expect(bus.signals.where((_Signal s) => s.name == 'Seeked'), isEmpty);
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
