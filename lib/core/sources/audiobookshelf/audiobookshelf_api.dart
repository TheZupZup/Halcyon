/// The response shape of `GET /status` — confirms an address is a reachable
/// Audiobookshelf server before any credentials are sent.
class AudiobookshelfServerStatus {
  const AudiobookshelfServerStatus({
    required this.serverVersion,
    this.isInitialized,
  });

  final String serverVersion;

  /// Whether the server has completed initial setup (a root user exists).
  /// `null` when the field was absent from an unexpected response shape.
  final bool? isInitialized;

  /// Parses `GET /status`'s response, or returns `null` when it doesn't
  /// carry `app: "audiobookshelf"` (a different server, or a
  /// Cloudflare/reverse-proxy error page that happens to be valid JSON) or is
  /// missing a version — the two things that confirm this is genuinely an
  /// Audiobookshelf server, not just something that answered on this address.
  static AudiobookshelfServerStatus? fromJson(Map<String, dynamic> json) {
    final Object? app = json['app'];
    if (app != 'audiobookshelf') return null;
    final String? version = _coerceString(json['serverVersion']);
    if (version == null) return null;
    return AudiobookshelfServerStatus(
      serverVersion: version,
      isInitialized: json['isInit'] as bool?,
    );
  }
}

/// The response shape of `POST /login` — the subset Linthra needs to build an
/// [AudiobookshelfSession]. The server returns considerably more (media
/// progress, bookmarks, server settings, …); later PRs read those as that
/// data becomes relevant, this one only needs enough to authenticate.
class AudiobookshelfAuthResult {
  const AudiobookshelfAuthResult({
    required this.userId,
    required this.accessToken,
    this.refreshToken,
    this.userName,
    this.defaultLibraryId,
  });

  final String userId;
  final String accessToken;

  /// Present only when the request sent `x-return-tokens: true` — otherwise
  /// the server sets it as an httpOnly cookie instead, which this client
  /// intentionally never relies on (a cookie jar is a browser assumption,
  /// not something to build into a mobile HTTP client's request flow).
  final String? refreshToken;
  final String? userName;
  final String? defaultLibraryId;

  /// Parses the login response, or returns `null` if the user id or access
  /// token are absent or the wrong type (an unexpected body), so the client
  /// can fail clearly with a sign-in error rather than throw a `TypeError`.
  static AudiobookshelfAuthResult? fromJson(Map<String, dynamic> json) {
    final Object? user = json['user'];
    if (user is! Map<String, dynamic>) return null;
    final String? userId = _coerceString(user['id']);
    final String? accessToken = _coerceString(user['accessToken']);
    if (userId == null || accessToken == null) return null;
    return AudiobookshelfAuthResult(
      userId: userId,
      accessToken: accessToken,
      refreshToken: _coerceString(user['refreshToken']),
      userName: _coerceString(user['username']),
      defaultLibraryId: _coerceString(json['userDefaultLibraryId']),
    );
  }
}

/// One entry from `GET /api/libraries` — enough to let a user pick which
/// library to browse. Item-level fetching (and the domain-model mapping that
/// goes with it) is out of scope for this PR; see the tracking issue.
class AudiobookshelfLibraryDto {
  const AudiobookshelfLibraryDto({
    required this.id,
    required this.name,
    this.mediaType,
  });

  final String id;
  final String name;

  /// The library's configured media type (e.g. `book`, `podcast`), when
  /// reported. Not yet used to filter — this PR only lists what's there.
  final String? mediaType;

  /// Parses one library entry, or returns `null` when the id or name are
  /// absent/wrong-typed, so a single malformed entry can be skipped rather
  /// than failing the whole listing.
  static AudiobookshelfLibraryDto? fromJson(Map<String, dynamic> json) {
    final String? id = _coerceString(json['id']);
    final String? name = _coerceString(json['name']);
    if (id == null || name == null) return null;
    return AudiobookshelfLibraryDto(
      id: id,
      name: name,
      mediaType: _coerceString(json['mediaType']),
    );
  }
}

/// Reads [value] as a non-blank [String], or `null` for anything else
/// (absent, wrong type, or empty/whitespace-only) — the shared rule every DTO
/// in this file applies to every field it reads, so a blank or malformed
/// value is treated the same as an absent one.
String? _coerceString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
