import 'dart:async';

import '../../models/cast_media.dart';
import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
import '../../models/cast_volume.dart';
import 'cast_receiver_trust.dart';
import 'cast_transport.dart';

/// The readiness boundary casting has to cross before a receiver gets anything:
/// a [CastTransport] that hands out a session only once the receiver on the
/// other end has proved it is the device the user picked.
///
/// It is a decorator, not a transport: it opens no socket and speaks no
/// protocol. That is deliberate. The rule — *no verified identity, no session,
/// no media* — is policy, and policy that lives inside an I/O adapter can only
/// be tested on a device. Here it is a few dozen lines of orchestration over a
/// [CastTransport] and a [CastReceiverAuthenticator], so every failure the
/// boundary must survive (a refusal, a device answering for another device, an
/// authentication that never finishes, a session that dies mid-handshake) is a
/// unit test rather than a code review.
///
/// **This does not restore casting.** Nothing in production builds a live
/// transport while the security containment holds, and the shipped
/// [UnverifiedCastReceiverAuthenticator] refuses every receiver anyway. This is
/// the boundary the reviewed restoration
/// ([#575](https://github.com/TheZupZup/Linthra/issues/575)) has to plug a real
/// authenticator into, built and tested ahead of it rather than alongside it.
///
/// **Containment still comes first.** Trust is checked *after* the delegate
/// opens the session, because a receiver can only prove itself over a
/// connection. So a contained transport refuses before this class ever asks
/// about identity, and this class never becomes a second way to reach a device
/// that the transport itself would not reach.
class TrustGatedCastTransport implements CastTransport {
  TrustGatedCastTransport({
    required CastTransport delegate,
    CastReceiverAuthenticator authenticator =
        const UnverifiedCastReceiverAuthenticator(),
    Duration authenticationTimeout = const Duration(seconds: 10),
  })  : _delegate = delegate,
        _authenticator = authenticator,
        _authenticationTimeout = authenticationTimeout;

  final CastTransport _delegate;
  final CastReceiverAuthenticator _authenticator;

  /// How long a receiver has to prove itself. A handshake that hangs is not a
  /// slow success: it expires as [CastTrustFailureKind.incomplete], the session
  /// is closed, and nothing is handed over.
  final Duration _authenticationTimeout;

  /// Discovery is not a trust boundary — finding a name on the LAN says nothing
  /// about who owns it — so it passes straight through, containment guards and
  /// all. Trust is established per connection, on the connection.
  @override
  Future<List<CastDevice>> discover(Duration timeout) =>
      _delegate.discover(timeout);

  @override
  Future<CastSessionHandle> connect(CastDevice device) async {
    final CastSessionHandle session = await _delegate.connect(device);

    final CastReceiverIdentity identity;
    try {
      identity = await _authenticate(device, session);
    } catch (_) {
      // Every failure path closes the session it was handed. A connected but
      // unauthenticated receiver is exactly what must not survive this method,
      // including when the failure is a timeout or a dropped connection.
      await _close(session);
      rethrow;
    }

    if (!identity.matches(device)) {
      await _close(session);
      throw const CastReceiverTrustException(
        "That device didn't turn out to be the one you picked, so Linthra "
        'stopped.',
        kind: CastTrustFailureKind.identityMismatch,
      );
    }

    return _TrustedCastSession(session, identity);
  }

  /// Races the receiver's proof against the session ending and the clock, so an
  /// authentication that cannot conclude fails instead of waiting forever.
  Future<CastReceiverIdentity> _authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) async {
    final Completer<CastReceiverIdentity> race =
        Completer<CastReceiverIdentity>();

    void fail(CastTrustFailureKind kind, String message) {
      if (!race.isCompleted) {
        race.completeError(CastReceiverTrustException(message, kind: kind));
      }
    }

    // The session dying underneath the handshake is an unfinished check, not a
    // pass: whatever the receiver had said so far, it never finished saying it.
    final StreamSubscription<bool> ended = session.readyStream.listen(
      (_) {},
      onError: (_) => fail(
        CastTrustFailureKind.incomplete,
        _incompleteMessage,
      ),
      onDone: () => fail(
        CastTrustFailureKind.incomplete,
        _incompleteMessage,
      ),
      cancelOnError: false,
    );

    final Timer expiry = Timer(
      _authenticationTimeout,
      () => fail(CastTrustFailureKind.incomplete, _incompleteMessage),
    );

    unawaited(
      _authenticator.authenticate(device).then(
        (CastReceiverIdentity identity) {
          if (!race.isCompleted) race.complete(identity);
        },
        onError: (Object error, StackTrace stack) {
          if (race.isCompleted) return;
          // A trust failure is passed through as itself; anything else — a
          // socket error, a bug in an implementation — becomes a refusal too,
          // because "the check threw" is never "the check passed".
          race.completeError(
            error is CastReceiverTrustException
                ? error
                : const CastReceiverTrustException(
                    _rejectedMessage,
                    kind: CastTrustFailureKind.rejected,
                  ),
            stack,
          );
        },
      ),
    );

    try {
      return await race.future;
    } finally {
      expiry.cancel();
      await ended.cancel();
    }
  }

  static const String _incompleteMessage =
      "Linthra couldn't finish checking that device, so it didn't send "
      'anything to it.';

  static const String _rejectedMessage =
      "Linthra couldn't verify that device, so it didn't send anything to it.";

  Future<void> _close(CastSessionHandle session) async {
    // Closing is cleanup on a path that is already failing; a receiver that
    // will not close cleanly must not turn a refusal into an unhandled error.
    try {
      await session.close();
    } catch (_) {
      // Intentionally ignored: the refusal above is what the caller needs.
    }
  }
}

/// A session whose receiver has been authenticated, wrapped so it can be told
/// apart from one that has not — and so the media handoff has its own refusal
/// rather than relying on nobody ever holding on to a closed session.
class _TrustedCastSession implements CastSessionHandle {
  _TrustedCastSession(this._session, this.identity);

  final CastSessionHandle _session;

  /// The verified receiver this session is bound to.
  final CastReceiverIdentity identity;

  /// Trust does not survive the session. Once closed, this handle refuses media
  /// even though it authenticated a moment ago: the connection it was proved
  /// over is gone, and a reconnection is a new receiver to prove.
  bool _trusted = true;

  @override
  Stream<bool> get readyStream =>
      _session.readyStream.map((bool ready) => ready && _trusted);

  @override
  Stream<CastPlaybackStatus> get statusStream => _session.statusStream;

  @override
  Stream<CastVolume> get volumeStream => _session.volumeStream;

  @override
  Future<void> loadMedia(CastMedia media) async {
    // The last refusal before a token-bearing URL leaves the device. It is
    // unreachable by construction — this class only exists after a successful
    // check — which is exactly why it is here: the handoff should not depend on
    // the caller having got the order right.
    if (!_trusted) {
      throw const CastReceiverTrustException(
        "Linthra stopped casting to that device because it couldn't keep "
        'verifying it.',
        kind: CastTrustFailureKind.incomplete,
      );
    }
    await _session.loadMedia(media);
  }

  @override
  Future<void> play() => _session.play();

  @override
  Future<void> pause() => _session.pause();

  @override
  Future<void> seek(Duration position) => _session.seek(position);

  @override
  Future<void> setVolume(double level) => _session.setVolume(level);

  @override
  Future<void> setMuted(bool muted) => _session.setMuted(muted);

  @override
  Future<void> requestStatus() => _session.requestStatus();

  @override
  Future<void> close() async {
    _trusted = false;
    await _session.close();
  }
}
