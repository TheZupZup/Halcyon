/// Why [ServerUrlNormalizer.parse] rejected an address, without owning the
/// user-facing message -- each provider phrases these slightly differently,
/// and only the provider knows which of its own exception types to throw.
enum ServerUrlErrorKind {
  /// The input was empty (after trimming).
  empty,

  /// The input, with a default scheme applied if none was typed, still
  /// isn't parseable as a URL at all.
  unparseable,

  /// The URL parsed, but its scheme isn't http or https.
  unsupportedScheme,

  /// The URL parsed with an http(s) scheme but no host.
  emptyHost,
}

/// Thrown internally by [ServerUrlNormalizer.parse] so each provider can
/// catch it and translate [kind] into its own typed exception and message.
/// Never meant to escape a provider's own `normalize()`.
class ServerUrlParseFailure implements Exception {
  const ServerUrlParseFailure(this.kind);

  final ServerUrlErrorKind kind;
}

/// The validated pieces of a normalized server URL, before any
/// provider-specific path post-processing (e.g. Subsonic's `/rest`
/// stripping).
class ParsedServerUrl {
  const ParsedServerUrl({
    required this.scheme,
    required this.host,
    required this.port,
    required this.path,
  });

  final String scheme;
  final String host;
  final int? port;

  /// Trailing slashes already trimmed; query and fragment already dropped
  /// ([Uri] parsing drops those from `.path` itself).
  final String path;

  /// Rebuilds the clean base URL: `scheme://host[:port][path]`, no
  /// trailing slash. [pathOverride] lets a provider substitute a
  /// further-processed path (Subsonic's `/rest` stripping) without
  /// re-deriving scheme/host/port.
  String toBase({String? pathOverride}) {
    final StringBuffer buffer = StringBuffer()
      ..write(scheme)
      ..write('://')
      ..write(host);
    if (port != null) {
      buffer
        ..write(':')
        ..write(port);
    }
    buffer.write(pathOverride ?? path);
    return buffer.toString();
  }
}

/// Shared trim/scheme/host/port/path normalization used by every
/// self-hosted server address field (Jellyfin, Plex, Subsonic/Navidrome).
/// Extracted so a networking fix only needs to land once instead of being
/// repeated -- and possibly forgotten -- in each provider's own copy of
/// this logic. Provider-specific behaviour (custom error messages,
/// Subsonic's `/rest` suffix stripping) stays in each provider's own
/// `*ServerUrl.normalize()`, which uses this as a thin shared core.
abstract final class ServerUrlNormalizer {
  /// Parses and validates [input], defaulting to https when no scheme is
  /// typed. Throws [ServerUrlParseFailure] (never a provider exception)
  /// when [input] can't be used -- callers translate
  /// [ServerUrlParseFailure.kind] into their own typed, user-facing
  /// exception.
  static ParsedServerUrl parse(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const ServerUrlParseFailure(ServerUrlErrorKind.empty);
    }

    // No scheme typed -> assume https (the common self-hosted/remote default).
    final String withScheme =
        trimmed.contains('://') ? trimmed : 'https://$trimmed';

    final Uri? uri = Uri.tryParse(withScheme);
    if (uri == null) {
      throw const ServerUrlParseFailure(ServerUrlErrorKind.unparseable);
    }

    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const ServerUrlParseFailure(ServerUrlErrorKind.unsupportedScheme);
    }

    if (uri.host.isEmpty) {
      throw const ServerUrlParseFailure(ServerUrlErrorKind.emptyHost);
    }

    return ParsedServerUrl(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: _trimTrailingSlashes(uri.path),
    );
  }

  static String _trimTrailingSlashes(String path) {
    int end = path.length;
    while (end > 0 && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }
}
