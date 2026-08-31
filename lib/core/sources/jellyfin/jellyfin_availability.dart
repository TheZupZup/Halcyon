import '../source_availability.dart';
import 'jellyfin_exception.dart';

/// Classifies a [JellyfinErrorKind] from a session probe into the
/// [SourceAvailability] it implies for the whole Jellyfin source.
///
/// The exhaustive switch is deliberate: adding a [JellyfinErrorKind] becomes a
/// compile error here rather than silently defaulting a new failure mode into
/// "unreachable" (or worse, "available"). Only [JellyfinErrorKind.unauthorized]
/// means the server was actually *reached*; everything else — a bad address, a
/// dead tunnel, a 5xx, a proxy error page, an unparseable answer — is a server
/// we could not usefully talk to, which for the library's purposes is the same
/// thing as unreachable.
SourceAvailability jellyfinAvailabilityFromError(JellyfinErrorKind kind) {
  switch (kind) {
    case JellyfinErrorKind.unauthorized:
      return SourceAvailability.authenticationError;
    case JellyfinErrorKind.invalidUrl:
    case JellyfinErrorKind.notReachable:
    case JellyfinErrorKind.notJellyfin:
    case JellyfinErrorKind.serverError:
    case JellyfinErrorKind.webPage:
    case JellyfinErrorKind.notAudioStream:
    case JellyfinErrorKind.streamUnavailable:
    case JellyfinErrorKind.unsupportedResponse:
    case JellyfinErrorKind.unexpected:
      return SourceAvailability.unreachable;
  }
}
