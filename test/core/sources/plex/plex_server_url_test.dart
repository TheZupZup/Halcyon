import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_server_url.dart';

void main() {
  group('PlexServerUrl.normalize', () {
    test('defaults a bare host to https (the remote-server case)', () {
      expect(
        PlexServerUrl.normalize('plex.example.com'),
        'https://plex.example.com',
      );
    });

    test('keeps an explicit http scheme and port (LAN server)', () {
      expect(
        PlexServerUrl.normalize('http://192.168.1.10:32400'),
        'http://192.168.1.10:32400',
      );
    });

    test('preserves a reverse-proxy subpath', () {
      expect(
        PlexServerUrl.normalize('https://example.com/plex'),
        'https://example.com/plex',
      );
    });

    test('strips a trailing slash, query, and fragment', () {
      expect(
        PlexServerUrl.normalize('https://example.com/plex/?x=1#y'),
        'https://example.com/plex',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        PlexServerUrl.normalize('  plex.example.com  '),
        'https://plex.example.com',
      );
    });

    test('lowercases the host', () {
      expect(
        PlexServerUrl.normalize('https://Plex.Example.COM'),
        'https://plex.example.com',
      );
    });

    test('rejects an empty address', () {
      expect(
        () => PlexServerUrl.normalize('   '),
        throwsA(
          isA<PlexException>().having(
            (PlexException e) => e.kind,
            'kind',
            PlexErrorKind.invalidUrl,
          ),
        ),
      );
    });

    test('rejects a non-http(s) scheme', () {
      expect(
        () => PlexServerUrl.normalize('ftp://example.com'),
        throwsA(isA<PlexException>()),
      );
    });

    test('rejects a scheme with no host', () {
      expect(
        () => PlexServerUrl.normalize('https://'),
        throwsA(isA<PlexException>()),
      );
    });
  });

  group('PlexServerUrl.tryNormalize', () {
    test('returns the normalized URL when valid', () {
      expect(
        PlexServerUrl.tryNormalize('192.168.1.10:32400'),
        'https://192.168.1.10:32400',
      );
    });

    test('returns null when invalid instead of throwing', () {
      expect(PlexServerUrl.tryNormalize('   '), isNull);
      expect(PlexServerUrl.tryNormalize('ftp://x'), isNull);
    });
  });
}
