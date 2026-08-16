import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../core/services/artwork_disk_cache.dart';

/// Turns a credential-free artwork *reference* into a loadable URL at render
/// time, or returns `null` for a [reference] it doesn't own.
///
/// Some sources can't persist a ready-to-load cover URL because it would embed a
/// credential (Subsonic's `getCoverArt` carries the salt+token on every
/// request), and `artworkUri` is persisted in the catalog. Those sources store
/// an opaque reference instead; the resolver, installed once at startup with the
/// live session, weaves the credential in here — on demand, never persisted.
typedef ArtworkReferenceResolver = Uri? Function(Uri reference);

/// The app-level reference resolver, or `null` when none is installed (the
/// default in tests, where references simply fall through and fail to load —
/// degrading to the caller's placeholder, never a broken-image glyph).
ArtworkReferenceResolver? _referenceResolver;

/// Installs the app-level [ArtworkReferenceResolver] (see `main`). Passing
/// `null` clears it. Idempotent and global on purpose: [artworkImageProvider] is
/// the app's single artwork seam, called from plain widgets with no Riverpod
/// scope, so the resolution rule is taught to the seam once rather than threaded
/// through every call site.
void installArtworkReferenceResolver(ArtworkReferenceResolver? resolver) {
  _referenceResolver = resolver;
}

/// The app-level persistent artwork cache (see `main`), or `null` when none is
/// installed — the default in tests, and briefly at app startup before the
/// async install completes, where every render simply behaves exactly as it did
/// before this cache existed (a fresh [NetworkImage] each time).
ArtworkDiskCache? _diskCache;

/// Installs the app-level [ArtworkDiskCache] (see `main`). Passing `null`
/// clears it. Idempotent and global for the same reason as
/// [installArtworkReferenceResolver]: [artworkImageProvider] is a plain
/// function with no Riverpod scope, so the persistent-cache behaviour is taught
/// to the one seam rather than threaded through every call site.
void installArtworkDiskCache(ArtworkDiskCache? cache) {
  _diskCache = cache;
}

/// Resolves an artwork [uri] to the right [ImageProvider] — the app's single
/// artwork-resolver seam.
///
/// Every artwork render goes through here (track rows, album/artist tiles and
/// detail headers, the now-playing background and mini-player), so a local
/// cover, a server cover, and a credential-resolved cover are treated
/// identically by every surface.
///
/// - A `file:` URI is embedded cover art Linthra extracted from a local audio
///   file into its own private cache; it loads straight from disk with a
///   [FileImage].
/// - Anything else — a server's plain http(s) image URL (Jellyfin builds a
///   token-free primary-image URL), or a credential-free *reference* (e.g.
///   Subsonic's `subsonic-cover:<id>`) — is first checked against the installed
///   [ArtworkDiskCache] (issue #356): a hit loads straight from disk with a
///   [FileImage], no network at all. A miss is handed to the installed
///   [ArtworkReferenceResolver] (which weaves in the live session's auth to
///   produce a loadable URL for a reference, or returns `null` for an
///   already-loadable URL) and loaded with a [NetworkImage] exactly as before —
///   and, in the background, fetched once more and written to the disk cache so
///   the *next* render of the same cover is a hit.
///
/// Sources with no cover at all — an untagged local file, or a Subsonic item the
/// server reports no `coverArt` for — carry a null `artworkUri` and never reach
/// here; the caller shows its placeholder. A `file:` cover whose bytes are
/// missing or undecodable (e.g. the OS reclaimed the cache), an unresolved
/// reference (signed out), or a failed network fetch all fail the same way, so
/// the caller's `errorBuilder` falls back to the placeholder — never a
/// broken-image glyph.
ImageProvider artworkImageProvider(Uri uri) {
  if (uri.isScheme('file')) {
    return FileImage(File(uri.toFilePath()));
  }
  final ArtworkDiskCache? cache = _diskCache;
  if (cache != null) {
    final File? cached = cache.cachedFile(uri);
    if (cached != null) return FileImage(cached);
    // A miss: warm the persistent cache in the background so a later render of
    // this same cover (this session or the next launch) is a hit. Fire-and-
    // forget and best-effort — never awaited, never blocks this render, and
    // never throws (see [ArtworkDiskCache.warm]).
    unawaited(cache.warm(uri));
  }
  final Uri? resolved = _referenceResolver?.call(uri);
  return NetworkImage((resolved ?? uri).toString());
}
