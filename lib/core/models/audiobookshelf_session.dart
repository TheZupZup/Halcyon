/// An authenticated Audiobookshelf session: everything needed to make further
/// authorized requests, kept in one immutable value so it can be persisted as a
/// unit and passed to the source.
///
/// Security: [accessToken] and [refreshToken] are secrets. They are persisted
/// only through the (encrypted, once it exists) session store and must never be
/// logged or shown in the UI. [toString] deliberately redacts both so an
/// accidental interpolation can't leak them into logs or error text.
///
/// The user's password is *not* part of a session and is never stored — it is
/// used once at sign-in to obtain the tokens and then discarded.
class AudiobookshelfSession {
  const AudiobookshelfSession({
    required this.baseUrl,
    required this.userId,
    required this.accessToken,
    this.refreshToken,
    this.userName,
    this.defaultLibraryId,
    this.serverVersion,
  });

  /// Clean base URL of the server (no trailing slash), e.g.
  /// `https://audiobooks.example.com`. API paths are appended to this.
  final String baseUrl;

  /// The authenticated user's Audiobookshelf id.
  final String userId;

  /// Secret bearer token for the `Authorization` header. Never log this.
  final String accessToken;

  /// Secret refresh token, present only when the server returned one (it does
  /// so only when the sign-in request sends the `x-return-tokens: true`
  /// header a mobile client needs, since otherwise Audiobookshelf sets it as
  /// an httpOnly cookie instead — not usable outside a browser). Never log
  /// this. `null` means the session can't be silently refreshed and a future
  /// 401 requires a fresh sign-in.
  final String? refreshToken;

  /// Display name of the signed-in user, when the server returned one.
  final String? userName;

  /// The user's default library id, when the server returned one. Useful as
  /// the starting point for library browsing.
  final String? defaultLibraryId;

  /// The server's reported version, when known. Not secret, display/
  /// diagnostics only.
  final String? serverVersion;

  AudiobookshelfSession copyWith({
    String? baseUrl,
    String? userId,
    String? accessToken,
    String? refreshToken,
    String? userName,
    String? defaultLibraryId,
    String? serverVersion,
  }) {
    return AudiobookshelfSession(
      baseUrl: baseUrl ?? this.baseUrl,
      userId: userId ?? this.userId,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      userName: userName ?? this.userName,
      defaultLibraryId: defaultLibraryId ?? this.defaultLibraryId,
      serverVersion: serverVersion ?? this.serverVersion,
    );
  }

  /// Serializes for the session store. The tokens are included because the
  /// only intended caller is an encrypted store; do not route this through
  /// any plaintext sink.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'userId': userId,
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (userName != null) 'userName': userName,
        if (defaultLibraryId != null) 'defaultLibraryId': defaultLibraryId,
        if (serverVersion != null) 'serverVersion': serverVersion,
      };

  /// Rebuilds a session from [toJson] output, or returns `null` if any
  /// required field is missing/blank (e.g. a partially written or corrupted
  /// record), so the app treats it as "not signed in" rather than crashing.
  static AudiobookshelfSession? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = json['baseUrl'] as String?;
    final String? userId = json['userId'] as String?;
    final String? accessToken = json['accessToken'] as String?;
    if (baseUrl == null || baseUrl.isEmpty) return null;
    if (userId == null || userId.isEmpty) return null;
    if (accessToken == null || accessToken.isEmpty) return null;
    return AudiobookshelfSession(
      baseUrl: baseUrl,
      userId: userId,
      accessToken: accessToken,
      refreshToken: json['refreshToken'] as String?,
      userName: json['userName'] as String?,
      defaultLibraryId: json['defaultLibraryId'] as String?,
      serverVersion: json['serverVersion'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudiobookshelfSession &&
          other.baseUrl == baseUrl &&
          other.userId == userId &&
          other.accessToken == accessToken &&
          other.refreshToken == refreshToken &&
          other.userName == userName &&
          other.defaultLibraryId == defaultLibraryId &&
          other.serverVersion == serverVersion);

  @override
  int get hashCode => Object.hash(
        baseUrl,
        userId,
        accessToken,
        refreshToken,
        userName,
        defaultLibraryId,
        serverVersion,
      );

  /// Redacts both tokens so the session can be safely interpolated into logs
  /// or error messages without leaking a secret.
  @override
  String toString() =>
      'AudiobookshelfSession(baseUrl: $baseUrl, userId: $userId, '
      'userName: $userName, defaultLibraryId: $defaultLibraryId, '
      'serverVersion: $serverVersion, accessToken: <redacted>, '
      'refreshToken: <redacted>)';
}
