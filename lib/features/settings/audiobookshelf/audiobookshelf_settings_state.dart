import '../../../core/sources/audiobookshelf/audiobookshelf_exception.dart';

/// Where the Audiobookshelf connection is in its lifecycle.
enum AudiobookshelfConnectionPhase {
  /// No session and nothing in progress.
  disconnected,

  /// A connection test is running.
  testing,

  /// A connection test just succeeded (the address is a reachable
  /// Audiobookshelf server); not signed in / persisted yet.
  tested,

  /// Sign-in is running.
  signingIn,

  /// Signed in — a session exists.
  connected,
}

/// One library the signed-in user can see, reduced to what the settings UI
/// shows. Deliberately not the wire DTO: the screen renders a name and a media
/// type, and nothing here invites the rest of the app to depend on the
/// Audiobookshelf response shape.
class AudiobookshelfLibrarySummary {
  const AudiobookshelfLibrarySummary({
    required this.id,
    required this.name,
    this.mediaType,
  });

  final String id;
  final String name;

  /// The library's media type (`book`, `podcast`, …) when the server reports
  /// one. Shown as a hint only; nothing filters on it yet.
  final String? mediaType;
}

/// Immutable snapshot the Audiobookshelf settings UI renders from.
///
/// The screen reads this and never reaches into HTTP, the authenticator, or the
/// session store directly — the controller is the only thing that mutates it.
///
/// Security: this state intentionally holds NO secret. There is no access or
/// refresh token and no password field; only display-safe values (server URL,
/// username, server version, library names) live here, so nothing sensitive can
/// leak through the widget tree or a state dump.
class AudiobookshelfSettingsState {
  const AudiobookshelfSettingsState({
    this.phase = AudiobookshelfConnectionPhase.disconnected,
    this.baseUrl,
    this.username,
    this.serverVersion,
    this.libraries = const <AudiobookshelfLibrarySummary>[],
    this.isLoadingLibraries = false,
    this.statusMessage,
    this.errorMessage,
    this.errorKind,
  });

  final AudiobookshelfConnectionPhase phase;

  /// Last connected/tested base URL, used to prefill the field. Not secret.
  final String? baseUrl;

  /// Connected (or last-entered) username, for prefill/display. Not secret.
  final String? username;

  /// The server's reported version, when known. Older servers (before v2.6.0)
  /// don't report one at all, so this stays `null` there.
  final String? serverVersion;

  /// The libraries this account can see, once listed. Empty until a signed-in
  /// listing succeeds — an account really can have none, which the UI says
  /// rather than showing an ambiguous blank.
  final List<AudiobookshelfLibrarySummary> libraries;

  /// True while the library listing is in flight, so the UI can show progress
  /// without blocking the rest of the connected view.
  final bool isLoadingLibraries;

  /// A friendly, non-error status line (e.g. "Signed in as …").
  final String? statusMessage;

  /// A friendly error line, when the last action failed.
  final String? errorMessage;

  /// The kind of the last failure, kept for the UI to branch on. The friendly
  /// [errorMessage] is already secret-free.
  final AudiobookshelfErrorKind? errorKind;

  bool get isConnected => phase == AudiobookshelfConnectionPhase.connected;

  /// True while a network action is in flight, so the UI can disable inputs and
  /// show a spinner.
  bool get isBusy =>
      phase == AudiobookshelfConnectionPhase.testing ||
      phase == AudiobookshelfConnectionPhase.signingIn;
}
