import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/artwork_disk_cache.dart';

void main() {
  group('ArtworkDiskCache', () {
    late Directory dir;
    late List<Uri> fetchedUrls;
    late List<int>? Function(Uri url) fetch;

    ArtworkDiskCache build({Uri Function(Uri key)? resolveFetchUrl}) {
      return ArtworkDiskCache(
        directory: dir,
        resolveFetchUrl: resolveFetchUrl,
        fetch: (Uri url) async {
          fetchedUrls.add(url);
          return fetch(url);
        },
      );
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('artwork_disk_cache_test');
      fetchedUrls = <Uri>[];
      fetch = (Uri url) => <int>[1, 2, 3, 4];
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a miss returns null and fetches nothing on its own', () async {
      final cache = build();
      expect(cache.cachedFile(Uri.parse('https://server.example/cover.jpg')),
          isNull);
      expect(fetchedUrls, isEmpty);
    });

    test('cache miss fetches and stores the image', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      await cache.warm(key);

      expect(fetchedUrls, [key]);
      final File? cached = cache.cachedFile(key);
      expect(cached, isNotNull);
      expect(await cached!.readAsBytes(), <int>[1, 2, 3, 4]);
    });

    test('a cache hit avoids a second network fetch', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');
      await cache.warm(key);
      expect(fetchedUrls, hasLength(1));

      // A fresh instance over the same directory, so this is a genuine restart
      // scenario, not just in-memory memoization.
      final reopened = build();
      final File? cached = reopened.cachedFile(key);
      expect(cached, isNotNull);

      // Warming again must not re-fetch: the file is already there.
      await reopened.warm(key);
      expect(fetchedUrls, hasLength(1));
    });

    test('concurrent warms of the same key share one fetch', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      await Future.wait(<Future<void>>[
        cache.warm(key),
        cache.warm(key),
        cache.warm(key),
      ]);

      expect(fetchedUrls, hasLength(1));
    });

    test('a missing cache entry refetches safely', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');
      expect(cache.cachedFile(key), isNull);

      await cache.warm(key);
      expect(cache.cachedFile(key), isNotNull);
    });

    test('a corrupt (0-byte) cache entry is treated as a miss and refetched',
        () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      // Simulate a truncated/corrupt prior write.
      if (!await dir.exists()) await dir.create(recursive: true);
      final File corrupt = File(
        '${dir.path}/${_sha256Hex('https://server.example/cover.jpg')}.img',
      );
      await corrupt.writeAsBytes(<int>[]);

      expect(cache.cachedFile(key), isNull);

      await cache.warm(key);
      final File? healed = cache.cachedFile(key);
      expect(healed, isNotNull);
      expect(await healed!.readAsBytes(), <int>[1, 2, 3, 4]);
    });

    test('a failed fetch caches nothing and never throws', () async {
      fetch = (Uri url) => null;
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      await cache.warm(key);

      expect(cache.cachedFile(key), isNull);
    });

    test('an unresolved reference (e.g. signed out) is never fetched',
        () async {
      // resolveFetchUrl returns the reference itself (unresolved), which is
      // not http(s) — the cache must skip fetching rather than attempt (and
      // fail) an unsupported request.
      final cache = build(resolveFetchUrl: (Uri key) => key);
      final key = Uri.parse('subsonic-cover:al-123');

      await cache.warm(key);

      expect(fetchedUrls, isEmpty);
      expect(cache.cachedFile(key), isNull);
    });

    test(
        'no token or authenticated URL is persisted: the cache key and file '
        'name are derived only from the credential-free reference', () async {
      final key = Uri.parse('subsonic-cover:al-123');
      final cache = build(
        resolveFetchUrl: (Uri k) => Uri.parse(
          'https://music.example.com/rest/getCoverArt.view'
          '?id=al-123&u=alice&t=super-secret-token&s=salt',
        ),
      );

      await cache.warm(key);

      final File? cached = cache.cachedFile(key);
      expect(cached, isNotNull);
      // The file name is a hash of the credential-free key, never the URL.
      expect(cached!.path, isNot(contains('super-secret-token')));
      expect(cached.path, isNot(contains('getCoverArt')));
      expect(cached.path, contains(_sha256Hex('subsonic-cover:al-123')));
      // The bytes on disk are exactly the image, no URL text embedded.
      expect(await cached.readAsBytes(), <int>[1, 2, 3, 4]);
      // Nothing else was written to the directory (no manifest/index file).
      final List<FileSystemEntity> entries = await dir.list().toList();
      expect(entries, hasLength(1));
    });

    test(
        'provider-specific references stay credential-free: the same '
        'reference caches to the same file regardless of a rotated token',
        () async {
      String token = 'token-one';
      final key = Uri.parse('plex-thumb:/library/metadata/1/thumb/1');
      final cache = build(
        resolveFetchUrl: (Uri k) => Uri.parse(
          'https://plex.example.com${k.path}?X-Plex-Token=$token',
        ),
      );

      await cache.warm(key);
      final File? first = cache.cachedFile(key);
      expect(first, isNotNull);
      final String firstPath = first!.path;

      // Force a re-fetch under a rotated token by deleting the cached file —
      // the resulting file must land at the exact same, token-independent path.
      await first.delete();
      token = 'token-two';
      await cache.warm(key);
      final File? second = cache.cachedFile(key);
      expect(second, isNotNull);
      expect(second!.path, firstPath);
    });
  });
}

String _sha256Hex(String input) {
  // Mirrors ArtworkDiskCache's private hashing without depending on it, so a
  // change to the private implementation that keeps the *contract* (a stable,
  // credential-free, content-addressed file name) doesn't need this test to
  // reach into private state.
  const String alphabet = '0123456789abcdef';
  final List<int> bytes = _sha256(input);
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.write(alphabet[(byte >> 4) & 0xf]);
    buffer.write(alphabet[byte & 0xf]);
  }
  return buffer.toString();
}

// Uses the same `crypto` package the production code uses, rather than a
// local shim.
List<int> _sha256(String input) => sha256.convert(utf8.encode(input)).bytes;
