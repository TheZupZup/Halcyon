import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_server_url.dart';

void main() {
  group('AudiobookshelfServerUrl.normalize', () {
    test('defaults a bare host to https (the common self-hosted default)', () {
      expect(
        AudiobookshelfServerUrl.normalize('audiobooks.example.com'),
        'https://audiobooks.example.com',
      );
    });

    test('keeps an explicit http scheme (local network)', () {
      expect(
        AudiobookshelfServerUrl.normalize('http://192.168.1.20:13378'),
        'http://192.168.1.20:13378',
      );
    });

    test('preserves a reverse-proxy subpath', () {
      expect(
        AudiobookshelfServerUrl.normalize(
          'https://example.com/audiobookshelf',
        ),
        'https://example.com/audiobookshelf',
      );
    });

    test('strips a trailing slash, query, and fragment', () {
      expect(
        AudiobookshelfServerUrl.normalize(
          'https://audiobooks.example.com/?x=1#y',
        ),
        'https://audiobooks.example.com',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        AudiobookshelfServerUrl.normalize('  audiobooks.example.com  '),
        'https://audiobooks.example.com',
      );
    });

    test('lowercases the host', () {
      expect(
        AudiobookshelfServerUrl.normalize('https://Audiobooks.Example.COM'),
        'https://audiobooks.example.com',
      );
    });

    test('brackets an IPv6 literal host', () {
      expect(
        AudiobookshelfServerUrl.normalize('http://[::1]:13378'),
        'http://[::1]:13378',
      );
    });

    test('rejects an empty address', () {
      expect(
        () => AudiobookshelfServerUrl.normalize('   '),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.invalidUrl,
          ),
        ),
      );
    });

    test('rejects a non-http(s) scheme', () {
      expect(
        () => AudiobookshelfServerUrl.normalize('ftp://example.com'),
        throwsA(isA<AudiobookshelfException>()),
      );
    });

    test('rejects a scheme with no host', () {
      expect(
        () => AudiobookshelfServerUrl.normalize('https://'),
        throwsA(isA<AudiobookshelfException>()),
      );
    });
  });

  group('AudiobookshelfServerUrl.tryNormalize', () {
    test('returns the normalized URL when valid', () {
      expect(
        AudiobookshelfServerUrl.tryNormalize('example.com'),
        'https://example.com',
      );
    });

    test('returns null when invalid instead of throwing', () {
      expect(AudiobookshelfServerUrl.tryNormalize('   '), isNull);
      expect(AudiobookshelfServerUrl.tryNormalize('ftp://x'), isNull);
    });
  });
}
