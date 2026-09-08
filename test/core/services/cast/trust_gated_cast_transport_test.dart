import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/cast_volume.dart';
import 'package:linthra/core/services/cast/cast_containment.dart';
import 'package:linthra/core/services/cast/cast_receiver_trust.dart';
import 'package:linthra/core/services/cast/cast_transport.dart';
import 'package:linthra/core/services/cast/trust_gated_cast_transport.dart';

/// The receiver-trust boundary: no verified identity, no session, no media
/// ([#575](https://github.com/TheZupZup/Linthra/issues/575)).
///
/// Casting is still withheld from production — nothing here restores it, and the
/// shipped authenticator refuses every receiver. What these tests are for is the
/// half of the restoration that can be proved without a device: that the failure
/// cases a real handshake will hit (a refusal, a device answering for another
/// device, a check that never finishes, a session that dies mid-handshake) all
/// end the same way, with the session closed and nothing handed over.
///
/// Interoperability with real receivers is the other half, and it cannot be
/// faked here: it needs supported hardware and the reviewed implementation. The
/// scenarios for it are in docs/cast-receiver-trust.md and, in detail, the
/// private advisory.
void main() {
  const CastDevice speaker = CastDevice(id: 'speaker-1', name: 'Kitchen');
  const CastDevice other = CastDevice(id: 'speaker-2', name: 'Bedroom');

  const CastReceiverIdentity speakerIdentity = CastReceiverIdentity(
    deviceId: 'speaker-1',
    fingerprint: 'sha256:aa:bb',
    model: 'Test Receiver',
  );

  final CastMedia media = CastMedia(
    url: Uri.parse('https://example.test/stream?api_key=secret-token'),
    contentType: 'audio/mpeg',
    title: 'Track',
  );

  TrustGatedCastTransport gate(
    _FakeTransport transport, {
    CastReceiverAuthenticator? authenticator,
    Duration timeout = const Duration(milliseconds: 50),
  }) {
    return TrustGatedCastTransport(
      delegate: transport,
      authenticator: authenticator ?? _AcceptingAuthenticator(),
      authenticationTimeout: timeout,
    );
  }

  group('a receiver that proves itself', () {
    test('gets a session, and media reaches it', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      await session.loadMedia(media);

      expect(transport.session.loaded, <CastMedia>[media]);
      expect(transport.session.closed, isFalse);
      expect(await session.readyStream.first, isTrue);
    });

    test('every other command still reaches the receiver', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      await session.play();
      await session.pause();
      await session.seek(const Duration(seconds: 12));
      await session.setVolume(0.4);
      await session.setMuted(true);
      await session.requestStatus();

      expect(transport.session.playCount, 1);
      expect(transport.session.pauseCount, 1);
      expect(transport.session.seeks, <Duration>[const Duration(seconds: 12)]);
      expect(transport.session.volumes, <double>[0.4]);
      expect(transport.session.mutes, <bool>[true]);
      expect(transport.session.statusRequests, 1);
    });
  });

  group('a receiver that does not prove itself', () {
    Future<CastReceiverTrustException> refusal(
      _FakeTransport transport, {
      required CastReceiverAuthenticator authenticator,
    }) async {
      try {
        await gate(transport, authenticator: authenticator).connect(speaker);
      } on CastReceiverTrustException catch (error) {
        return error;
      }
      fail('connect() returned a session for an unverified receiver.');
    }

    test('the shipped authenticator refuses every device', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const UnverifiedCastReceiverAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.unsupported);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a rejected handshake closes the session and loads nothing', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _RefusingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a device that authenticates as another device is refused', () async {
      final _FakeTransport transport = _FakeTransport();

      // The receiver proves an identity — just not the one the user picked.
      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: _AcceptingAuthenticator(as: other),
      );

      expect(error.kind, CastTrustFailureKind.identityMismatch);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('an authentication that never finishes expires', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: _HangingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.incomplete);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a session that dies mid-handshake is an unfinished check', () async {
      final _FakeTransport transport = _FakeTransport();
      final _HangingAuthenticator hanging = _HangingAuthenticator();

      // Long timeout: the refusal must come from the session ending, not from
      // the clock running out.
      final Future<CastSessionHandle> connecting = gate(
        transport,
        authenticator: hanging,
        timeout: const Duration(seconds: 30),
      ).connect(speaker);
      await pumpEventQueue();
      transport.session.end();

      await expectLater(
        connecting,
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );
      expect(transport.session.loaded, isEmpty);
    });

    test('an authenticator that throws something else is still a refusal',
        () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _ExplodingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      // The thrown detail does not become user-facing copy: a handshake error
      // can carry anything, including material from the receiver.
      expect(error.message, isNot(contains('challenge')));
      expect(error.message, isNot(contains('nonce-')));
    });

    test('a receiver that will not close cleanly still gets refused', () async {
      final _FakeTransport transport = _FakeTransport()
        ..session.closeError = StateError('socket already gone');

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _RefusingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.loaded, isEmpty);
    });
  });

  group('the boundary itself', () {
    test('containment refuses before trust is even asked about', () async {
      // The gate is not a second route to a receiver: a contained transport
      // fails first, and no handshake is attempted.
      final _FakeTransport transport = _FakeTransport()
        ..connectError = CastContainmentError('connecting');
      final _AcceptingAuthenticator authenticator = _AcceptingAuthenticator();

      await expectLater(
        gate(transport, authenticator: authenticator).connect(speaker),
        throwsA(isA<CastContainmentError>()),
      );
      expect(authenticator.calls, isEmpty);
    });

    test('discovery passes through, refusals and all', () async {
      final _FakeTransport transport = _FakeTransport();

      expect(
        await gate(transport).discover(const Duration(seconds: 1)),
        <CastDevice>[speaker],
      );

      transport.discoverError = CastContainmentError('discovery');
      await expectLater(
        gate(transport).discover(const Duration(seconds: 1)),
        throwsA(isA<CastContainmentError>()),
      );
    });

    test('trust does not survive the session being closed', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      await session.close();

      await expectLater(
        session.loadMedia(media),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );
      expect(transport.session.loaded, isEmpty);
      expect(await session.readyStream.first, isFalse);
    });

    test('no refusal carries anything from the handshake', () async {
      for (final CastReceiverAuthenticator authenticator
          in <CastReceiverAuthenticator>[
        const UnverifiedCastReceiverAuthenticator(),
        const _RefusingAuthenticator(),
        const _ExplodingAuthenticator(),
        _AcceptingAuthenticator(as: other),
        _HangingAuthenticator(),
      ]) {
        final _FakeTransport transport = _FakeTransport();
        String message = '';
        try {
          await gate(transport, authenticator: authenticator).connect(speaker);
        } on CastReceiverTrustException catch (error) {
          message = error.message.toLowerCase();
        }

        expect(message, isNotEmpty);
        for (final String leak in <String>[
          'certificate',
          'challenge',
          'signature',
          'nonce',
          'token',
          'key',
          'fingerprint',
          'sha256',
        ]) {
          expect(message, isNot(contains(leak)),
              reason: '${authenticator.runtimeType} leaks "$leak"');
        }
      }
    });
  });

  group('CastReceiverIdentity', () {
    test('is bound to the device it was proved for', () {
      expect(speakerIdentity.matches(speaker), isTrue);
      expect(speakerIdentity.matches(other), isFalse);
    });

    test('two proofs of the same device are only equal if they agree', () {
      expect(
        speakerIdentity,
        const CastReceiverIdentity(
          deviceId: 'speaker-1',
          fingerprint: 'sha256:aa:bb',
          model: 'Test Receiver',
        ),
      );
      expect(
        speakerIdentity,
        isNot(const CastReceiverIdentity(
          deviceId: 'speaker-1',
          fingerprint: 'sha256:cc:dd',
        )),
      );
    });
  });
}

/// A transport whose session, and whose failures, the test drives.
class _FakeTransport implements CastTransport {
  final _FakeHandle session = _FakeHandle();

  /// When set, [connect] throws it — how a contained transport behaves.
  Object? connectError;

  /// When set, [discover] throws it.
  Object? discoverError;

  @override
  Future<List<CastDevice>> discover(Duration timeout) async {
    if (discoverError != null) throw discoverError!;
    return const <CastDevice>[CastDevice(id: 'speaker-1', name: 'Kitchen')];
  }

  @override
  Future<CastSessionHandle> connect(CastDevice device) async {
    if (connectError != null) throw connectError!;
    return session;
  }
}

/// The same shape as the real handle: readiness replays to a late listener, and
/// every command is recorded so a test can assert nothing reached the receiver.
class _FakeHandle implements CastSessionHandle {
  final StreamController<bool> _ready = StreamController<bool>.broadcast();
  bool? _last = true;

  final List<CastMedia> loaded = <CastMedia>[];
  final List<Duration> seeks = <Duration>[];
  final List<double> volumes = <double>[];
  final List<bool> mutes = <bool>[];
  int playCount = 0;
  int pauseCount = 0;
  int statusRequests = 0;
  bool closed = false;

  /// When set, [close] throws it, so a failing teardown can be exercised.
  Object? closeError;

  /// Ends the session the way a dropped receiver does.
  void end() {
    _last = false;
    if (!_ready.isClosed) {
      _ready.add(false);
      _ready.close();
    }
  }

  @override
  Stream<bool> get readyStream async* {
    if (_last != null) yield _last!;
    yield* _ready.stream;
  }

  @override
  Stream<CastPlaybackStatus> get statusStream =>
      const Stream<CastPlaybackStatus>.empty();

  @override
  Stream<CastVolume> get volumeStream => const Stream<CastVolume>.empty();

  @override
  Future<void> loadMedia(CastMedia media) async => loaded.add(media);

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setVolume(double level) async => volumes.add(level);

  @override
  Future<void> setMuted(bool muted) async => mutes.add(muted);

  @override
  Future<void> requestStatus() async => statusRequests++;

  @override
  Future<void> close() async {
    closed = true;
    if (closeError != null) throw closeError!;
    if (!_ready.isClosed) await _ready.close();
  }
}

/// Vouches for a receiver — as itself by default, or as [as] to model a device
/// answering for another one.
class _AcceptingAuthenticator implements CastReceiverAuthenticator {
  _AcceptingAuthenticator({this.as});

  final CastDevice? as;

  /// Every device this was asked about, so a test can show it was never asked.
  final List<String> calls = <String>[];

  @override
  Future<CastReceiverIdentity> authenticate(CastDevice device) async {
    calls.add(device.id);
    return CastReceiverIdentity(
      deviceId: (as ?? device).id,
      fingerprint: 'sha256:aa:bb',
    );
  }
}

/// Answers, and fails the check.
class _RefusingAuthenticator implements CastReceiverAuthenticator {
  const _RefusingAuthenticator();

  @override
  Future<CastReceiverIdentity> authenticate(CastDevice device) async {
    throw const CastReceiverTrustException(
      "Linthra couldn't verify that device.",
      kind: CastTrustFailureKind.rejected,
    );
  }
}

/// Throws something that is not a trust failure, carrying detail that must not
/// reach the user.
class _ExplodingAuthenticator implements CastReceiverAuthenticator {
  const _ExplodingAuthenticator();

  @override
  Future<CastReceiverIdentity> authenticate(CastDevice device) async {
    throw StateError('challenge nonce-4711 rejected by peer certificate');
  }
}

/// Never answers, the way a receiver that accepts a socket and then goes quiet
/// does not.
class _HangingAuthenticator implements CastReceiverAuthenticator {
  @override
  Future<CastReceiverIdentity> authenticate(CastDevice device) =>
      Completer<CastReceiverIdentity>().future;
}
