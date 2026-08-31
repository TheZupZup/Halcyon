import 'package:flutter/foundation.dart';

import '../services/reachability.dart';

/// Whether a music source is actually usable *right now*, as opposed to merely
/// being configured.
///
/// Linthra used to conflate the two: a saved Jellyfin session meant "connected",
/// forever, even when the server lived on a LAN address the device had long
/// since left. That made diagnostics lie ("Jellyfin: connected" next to a
/// playback error), and left the user with no way to get a usable library short
/// of signing out — which throws away the catalog, playlists, favourites and
/// downloads they want back the moment they're home again.
///
/// So configuration and availability are two separate facts. The session store
/// answers "is a server configured?"; this answers "did it answer just now?".
/// Only the *second* question gates what the active library shows, and nothing
/// about it is destructive: an unavailable source is hidden, never forgotten.
enum SourceAvailability {
  /// No server is configured for this source, so there is nothing to reach.
  /// Distinct from [unreachable]: nothing is hidden, because nothing was synced
  /// under a connection the user still has.
  notConfigured,

  /// A server is configured and a probe is in flight; we do not know yet.
  ///
  /// Deliberately *optimistic* — see [hidesTracks]. A momentary "we haven't
  /// checked yet" must never blank a library, so tracks stay visible until a
  /// probe actually comes back negative.
  checking,

  /// The configured server answered and accepted the session.
  available,

  /// A server is configured, but it could not be reached (no network, a LAN-only
  /// address from off the LAN, a down tunnel, a sleeping box, a 5xx, a timeout).
  /// Its tracks are *temporarily* excluded from the active library; every record
  /// — catalog rows, playlists, favourites, downloads, and the saved session —
  /// is kept exactly as it was.
  unreachable,

  /// The server was reached but rejected the saved session. Its tracks are
  /// excluded the same way, but the fix is signing in again, not moving closer
  /// to the server — kept distinct so diagnostics and the UI can say so.
  authenticationError,
}

/// Convenience predicates. Kept on the enum so every call site branches on the
/// same rules rather than re-deriving them.
extension SourceAvailabilityStatus on SourceAvailability {
  /// A server is configured for this source, whatever its current reachability.
  bool get isConfigured => this != SourceAvailability.notConfigured;

  /// The server answered and accepted the session on the last probe.
  bool get isAvailable => this == SourceAvailability.available;

  /// A probe is in flight and nothing is known yet.
  bool get isChecking => this == SourceAvailability.checking;

  /// The server is configured but not usable right now.
  bool get isUnavailable =>
      this == SourceAvailability.unreachable ||
      this == SourceAvailability.authenticationError;

  /// Whether this source's streamed tracks should be held out of the active
  /// library.
  ///
  /// Only a *proven* failure hides anything. [checking] and [notConfigured] both
  /// return false, so the library is never blanked by a state that merely means
  /// "we don't know" — under-hiding (a track that turns out not to play) is a far
  /// smaller harm than a library that empties itself on a slow probe.
  bool get hidesTracks => isUnavailable;
}

/// The current availability of one source, plus when it was last established.
///
/// A value type so it can be compared in tests and so a Riverpod rebuild only
/// fires on a real change. It carries no session, token, address, or error text —
/// only the state and a timestamp — so it is safe to surface in diagnostics.
@immutable
class SourceAvailabilityState {
  const SourceAvailabilityState({
    required this.status,
    this.lastCheckedAt,
  });

  /// No server configured — the starting point for an untouched source.
  const SourceAvailabilityState.notConfigured()
      : status = SourceAvailability.notConfigured,
        lastCheckedAt = null;

  /// A server is configured and the first probe hasn't answered yet.
  const SourceAvailabilityState.checking()
      : status = SourceAvailability.checking,
        lastCheckedAt = null;

  final SourceAvailability status;

  /// When the last probe completed, or `null` when none has. Used by the UI to
  /// say how fresh the answer is; never a source of truth on its own.
  final DateTime? lastCheckedAt;

  bool get isAvailable => status.isAvailable;
  bool get isUnavailable => status.isUnavailable;
  bool get hidesTracks => status.hidesTracks;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceAvailabilityState &&
          other.status == status &&
          other.lastCheckedAt == lastCheckedAt);

  @override
  int get hashCode => Object.hash(status, lastCheckedAt);

  @override
  String toString() => 'SourceAvailabilityState(${status.name})';
}

/// The secret-free label a diagnostics report uses for a source whose server is
/// **configured**, so a bug report says what the last probe actually found.
///
/// Every non-available answer still says "configured", so nobody reads the line
/// as "signed out" — the session, catalog, playlists and downloads are all still
/// there. This is shared by the app-wide report and the per-source Jellyfin one
/// so the two can never drift into telling a user different stories.
String configuredSourceAvailabilityLabel(SourceAvailability availability) {
  switch (availability) {
    case SourceAvailability.available:
      return 'connected';
    case SourceAvailability.unreachable:
      return 'configured (server unreachable)';
    case SourceAvailability.authenticationError:
      return 'configured (authentication error)';
    case SourceAvailability.checking:
      return 'configured (checking)';
    case SourceAvailability.notConfigured:
      // A saved session with no availability answer yet (nothing has probed in
      // this container). Report it as configured-but-unverified rather than
      // claiming a connection nothing has confirmed.
      return 'configured (not checked)';
  }
}

/// Translates a playback-path [ReachabilityStatus] into the availability it
/// implies for the whole source.
///
/// This is the *non-destructive* bridge between "a track failed to resolve" and
/// "this server is down": the only thing it can ever do is change a visibility
/// flag. It never removes a catalog row, a download, or a session — which is
/// exactly the coupling that made the old behaviour dangerous.
///
/// Returns `null` for a status that says nothing source-wide, so the caller
/// leaves the current availability alone rather than guessing.
SourceAvailability? availabilityFromReachability(ReachabilityStatus status) {
  switch (status) {
    case ReachabilityStatus.reachable:
      return SourceAvailability.available;
    case ReachabilityStatus.authFailure:
      return SourceAvailability.authenticationError;
    case ReachabilityStatus.serverUnreachable:
    case ReachabilityStatus.timeout:
    case ReachabilityStatus.networkUnavailable:
      // No network at all is still "this server can't be reached"; the next
      // probe (on reconnect, resume, or the poll) flips it straight back.
      return SourceAvailability.unreachable;
  }
}
