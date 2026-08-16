import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists remote artwork bytes to a small, Linthra-managed disk cache keyed
/// by the credential-free artwork identity ([artworkImageProvider]'s `Uri`
/// argument), so a cover fetched once survives an app restart.
///
/// Why this exists: Flutter's built-in `ImageCache` is in-memory only and is
/// dropped the moment the process ends, so every remote cover — Jellyfin's
/// token-free image URL, or a resolved Subsonic/Plex reference — was otherwise
/// re-fetched on *every* app launch (issue #356: "every time I open the app it
/// has to re-download all images for everything"). This cache sits in front of
/// the network fetch inside `artworkImageProvider`: a hit is read straight from
/// disk (no network at all); a miss still loads exactly as it did before this
/// cache existed and, in the background, fetches + writes the bytes so the
/// *next* launch is a hit.
///
/// Distinct from `MediaArtworkCache` (which caches a small platform-loadable
/// `content://` copy for the lock screen / Android Auto, in the OS-reclaimable
/// temp directory): this cache backs the in-app UI — `artworkImageProvider`,
/// the one seam every track row, album/artist tile, header, and mini-player
/// loads art through — lives in the app-support directory (durable, not
/// reclaimed under memory pressure), and is a plain, safe-to-delete folder of
/// image files with no manifest to go stale.
///
/// Security / privacy:
///  - The cache **key** — and therefore the on-disk file name — is a SHA-256
///    hash of the *credential-free* artwork identity: a Jellyfin cover URL is
///    already token-free by construction, and Subsonic/Plex covers are keyed by
///    their opaque reference (`subsonic-cover:<id>`, `plex-thumb:<path>`)
///    rather than any resolved, authenticated URL. Nothing that could carry a
///    token or server address is ever part of a file name, and there is no
///    index/manifest that could record one either.
///  - The *authenticated* fetch URL a provider's `ArtworkReferenceResolver`
///    produces exists only as a local inside [_warmNow], used once to fetch the
///    bytes, and is never written to disk or logged.
///  - A missing or corrupt (0-byte / unreadable) cache entry is always treated
///    as a miss, never surfaced as an error — the caller falls back to a fresh
///    fetch and, ultimately, its placeholder.
class ArtworkDiskCache {
  ArtworkDiskCache({
    required Directory directory,
    Uri Function(Uri key)? resolveFetchUrl,
    Future<List<int>?> Function(Uri url)? fetch,
    http.Client? httpClient,
  })  : _directory = directory,
        _resolveFetchUrl = resolveFetchUrl ?? _identity,
        _httpClient = httpClient ?? http.Client() {
    _fetch = fetch ?? _defaultFetch;
  }

  /// The app's persistent artwork-cache directory. Nothing is created yet —
  /// [_warmNow] creates it lazily on first write. Call once at startup and pass
  /// the result to the constructor; tests inject their own temp directory.
  static Future<Directory> defaultDirectory() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'artwork_cache'));
  }

  final Directory _directory;

  /// Turns a credential-free key into the URL to fetch. Defaults to the
  /// identity function (an already-loadable Jellyfin URL needs no resolving);
  /// the app wires this to `artwork_image.dart`'s installed
  /// `ArtworkReferenceResolver` so a Subsonic/Plex reference resolves with the
  /// live session's credential at fetch time, never persisted.
  final Uri Function(Uri key) _resolveFetchUrl;

  final http.Client _httpClient;
  late final Future<List<int>?> Function(Uri url) _fetch;

  /// In-flight warms, keyed by the cache key's hash, so a burst of rebuilds for
  /// the same reference (e.g. a scrolling list) share one fetch instead of
  /// racing to write the same file — and so a caller (tests) can await the same
  /// result rather than firing a second one.
  final Map<String, Future<void>> _warming = <String, Future<void>>{};

  static const Duration _timeout = Duration(seconds: 20);

  File _fileFor(String hash) => File(p.join(_directory.path, '$hash.img'));

  /// The cached file for [key] if a non-empty copy already exists on disk, or
  /// `null` on a miss or a corrupt (0-byte / unreadable) entry. A cheap
  /// synchronous stat, so `artworkImageProvider` can consult it while building
  /// an `ImageProvider` with no `await`.
  File? cachedFile(Uri key) {
    final File file = _fileFor(_hash(key));
    try {
      if (file.lengthSync() > 0) return file;
    } on FileSystemException {
      // Missing, or an odd permissions error — either way, not a usable hit.
    }
    return null;
  }

  /// Fetches [key]'s bytes and writes them to the persistent cache, so the
  /// *next* [cachedFile] call is a hit. Safe to call on every render: it
  /// de-duplicates concurrent warms for the same key (returning the same
  /// in-flight future) and re-checks the disk before fetching, so a real cache
  /// hit never spends the network twice. Never throws — every failure (an
  /// unresolvable reference, a network error, a non-image response, a write
  /// failure) just leaves the entry to warm again on a later call.
  Future<void> warm(Uri key) {
    final String hash = _hash(key);
    final Future<void>? inFlight = _warming[hash];
    if (inFlight != null) return inFlight;
    final Future<void> future = _runWarm(key, hash);
    _warming[hash] = future;
    return future;
  }

  // A plain try/finally wrapper rather than `_warmNow(...).whenComplete(...)`:
  // chaining `whenComplete` onto a future whose last hop is a native file
  // completion (as `_warmNow`'s is, via `File.rename`) has been observed to
  // never resolve on some platforms/engines, silently stalling every future
  // caller awaiting [warm]. try/finally reaches the same "always clean up the
  // in-flight entry" guarantee without that combinator.
  Future<void> _runWarm(Uri key, String hash) async {
    try {
      await _warmNow(key, hash);
    } finally {
      // `Map.remove` would return the removed Future itself here (the map's
      // value type), which trips the unawaited-futures lint on a bare
      // expression statement; removeWhere discards it via a bool predicate
      // instead, with the exact same effect.
      _warming.removeWhere((String k, Future<void> _) => k == hash);
    }
  }

  Future<void> _warmNow(Uri key, String hash) async {
    try {
      final File file = _fileFor(hash);
      if (await file.exists() && await file.length() > 0) return;
      final Uri url = _resolveFetchUrl(key);
      if (!url.isScheme('http') && !url.isScheme('https')) {
        // An unresolved reference (e.g. signed out) resolves to itself, which
        // is never fetchable — nothing to warm; a later render (signed back
        // in) retries.
        return;
      }
      final List<int>? bytes = await _fetch(url);
      if (bytes == null || bytes.isEmpty) return;
      if (!await _directory.exists()) {
        await _directory.create(recursive: true);
      }
      // Write to a temp sibling then rename, so a crash mid-write can't leave a
      // truncated image that would fail to decode until evicted.
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Best-effort: leave it to retry on a later render.
    }
  }

  /// A credential-free, filename-safe cache key: the SHA-256 of [key]'s string
  /// form. [key] itself never carries a token (see class docs), so neither does
  /// the hash — and hashing also keeps an odd reference from escaping the cache
  /// directory.
  static String _hash(Uri key) =>
      sha256.convert(utf8.encode(key.toString())).toString();

  static Uri _identity(Uri key) => key;

  /// The default fetcher: a plain GET (over the reused [_httpClient]) that
  /// returns the body bytes only for a 2xx image response. Any transport error,
  /// non-2xx status, or non-image body yields `null`. The URL — which may carry
  /// a credential — is never logged, even on error.
  Future<List<int>?> _defaultFetch(Uri url) async {
    try {
      final http.Response response =
          await _httpClient.get(url).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final String contentType =
          (response.headers['content-type'] ?? '').toLowerCase();
      if (!contentType.startsWith('image/')) return null;
      final List<int> bytes = response.bodyBytes;
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// Releases the shared HTTP client. The on-disk cache is left intact — it is
  /// durable and persists across restarts by design; call when the owning
  /// container is torn down.
  void dispose() => _httpClient.close();
}
