import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/core/sources/audiobookshelf/http_audiobookshelf_client.dart';

const String _base = 'https://audiobooks.example.com';

const _session = AudiobookshelfSession(
  baseUrl: _base,
  userId: 'user-1',
  accessToken: 'tok-abc',
);

HttpAudiobookshelfClient _client(MockClient mock) =>
    HttpAudiobookshelfClient(httpClient: mock);

http.Response _json(Map<String, dynamic> body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('fetchServerStatus', () {
    test('parses status and calls the right endpoint', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _json(<String, dynamic>{
          'app': 'audiobookshelf',
          'serverVersion': '2.19.0',
          'isInit': true,
        });
      }));

      final status = await client.fetchServerStatus(_base);

      expect(status.serverVersion, '2.19.0');
      expect(status.isInitialized, isTrue);
      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/status');
    });

    test('decodes a UTF-8 body without a charset header', () async {
      // A server sending raw UTF-8 bytes and no charset: `response.body`
      // would mis-decode this as latin1; the client decodes bodyBytes as
      // UTF-8. Nothing in /status is actually non-ASCII, but this exercises
      // the same decode path every response goes through.
      final client = _client(MockClient((_) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'app': 'audiobookshelf',
            'serverVersion': '2.19.0',
          })),
          200,
        );
      }));

      final status = await client.fetchServerStatus(_base);
      expect(status.serverVersion, '2.19.0');
    });

    test('throws notAudiobookshelf when app is not "audiobookshelf"', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'app': 'something-else',
          'serverVersion': '1.0.0',
        });
      }));

      expect(
        () => client.fetchServerStatus(_base),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.notAudiobookshelf,
          ),
        ),
      );
    });

    test(
        'throws notAudiobookshelf on a non-JSON body (e.g. an HTML error '
        'page)', () async {
      final client = _client(MockClient((_) async {
        return http.Response('<html>not found</html>', 200);
      }));

      expect(
        () => client.fetchServerStatus(_base),
        throwsA(isA<AudiobookshelfException>()),
      );
    });

    test('maps a 5xx to serverError', () async {
      final client = _client(MockClient((_) async {
        return http.Response('', 503);
      }));

      expect(
        () => client.fetchServerStatus(_base),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.serverError,
          ),
        ),
      );
    });
  });

  group('authenticateByName', () {
    test('sends the right body/headers and parses the result', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _json(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'jon',
            'accessToken': 'tok-abc',
            'refreshToken': 'refresh-xyz',
          },
          'userDefaultLibraryId': 'lib-1',
        });
      }));

      final result = await client.authenticateByName(
        baseUrl: _base,
        username: 'jon',
        password: 'hunter2',
      );

      expect(result.userId, 'user-1');
      expect(result.accessToken, 'tok-abc');
      expect(result.refreshToken, 'refresh-xyz');
      expect(result.userName, 'jon');
      expect(result.defaultLibraryId, 'lib-1');

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/login');
      expect(captured!.headers['x-return-tokens'], 'true');
      final Map<String, dynamic> sentBody =
          jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(sentBody['username'], 'jon');
      expect(sentBody['password'], 'hunter2');
    });

    test('a missing refreshToken is null, not an error (cookie-only flow)',
        () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'jon',
            'accessToken': 'tok-abc',
          },
        });
      }));

      final result = await client.authenticateByName(
        baseUrl: _base,
        username: 'jon',
        password: 'hunter2',
      );
      expect(result.refreshToken, isNull);
    });

    test('rejected credentials map to unauthorized', () async {
      final client = _client(MockClient((_) async {
        return http.Response('', 401);
      }));

      expect(
        () => client.authenticateByName(
          baseUrl: _base,
          username: 'jon',
          password: 'wrong',
        ),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.unauthorized,
          ),
        ),
      );
    });
  });

  group('fetchLibraries', () {
    test('parses the libraries array and sends the bearer token', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _json(<String, dynamic>{
          'libraries': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'lib-1',
              'name': 'Audiobooks',
              'mediaType': 'book',
            },
            <String, dynamic>{
              'id': 'lib-2',
              'name': 'Podcasts',
              'mediaType': 'podcast',
            },
          ],
        });
      }));

      final libraries = await client.fetchLibraries(_session);

      expect(libraries, hasLength(2));
      expect(libraries[0].id, 'lib-1');
      expect(libraries[0].name, 'Audiobooks');
      expect(libraries[0].mediaType, 'book');
      expect(captured!.headers['Authorization'], 'Bearer tok-abc');
      expect(captured!.url.path, '/api/libraries');
    });

    test('skips a malformed entry instead of failing the whole listing',
        () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'libraries': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'lib-1', 'name': 'Audiobooks'},
            <String, dynamic>{'name': 'missing id'},
          ],
        });
      }));

      final libraries = await client.fetchLibraries(_session);
      expect(libraries, hasLength(1));
      expect(libraries.single.id, 'lib-1');
    });

    test('an unrecognized shape returns an empty list, not an error', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{'somethingElse': true});
      }));

      final libraries = await client.fetchLibraries(_session);
      expect(libraries, isEmpty);
    });
  });
}
