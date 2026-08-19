import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_authenticator.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';

import 'fake_audiobookshelf_client.dart';

const _status = AudiobookshelfServerStatus(
  serverVersion: '2.19.0',
  isInitialized: true,
);

const _authResult = AudiobookshelfAuthResult(
  userId: 'user-1',
  accessToken: 'tok-abc',
  refreshToken: 'refresh-xyz',
  userName: 'jon',
  defaultLibraryId: 'lib-1',
);

void main() {
  group('testConnection', () {
    test('normalizes the URL and returns the server status', () async {
      final fake = FakeAudiobookshelfClient(serverStatus: _status);
      final authenticator = AudiobookshelfAuthenticator(fake);

      final status = await authenticator.testConnection(
        'audiobooks.example.com',
      );

      expect(status.serverVersion, '2.19.0');
      expect(fake.lastBaseUrl, 'https://audiobooks.example.com');
    });

    test('a bad address throws before any request is made', () async {
      final fake = FakeAudiobookshelfClient();
      final authenticator = AudiobookshelfAuthenticator(fake);

      expect(
        () => authenticator.testConnection('   '),
        throwsA(isA<AudiobookshelfException>()),
      );
      expect(fake.lastBaseUrl, isNull);
    });
  });

  group('signIn', () {
    test('signs in and builds a session from the result', () async {
      final fake = FakeAudiobookshelfClient(
        serverStatus: _status,
        authResult: _authResult,
      );
      final authenticator = AudiobookshelfAuthenticator(fake);

      final AudiobookshelfSession session = await authenticator.signIn(
        rawUrl: 'audiobooks.example.com',
        username: 'jon',
        password: 'hunter2',
      );

      expect(session.baseUrl, 'https://audiobooks.example.com');
      expect(session.userId, 'user-1');
      expect(session.accessToken, 'tok-abc');
      expect(session.refreshToken, 'refresh-xyz');
      expect(session.userName, 'jon');
      expect(session.defaultLibraryId, 'lib-1');
      expect(fake.lastUsername, 'jon');
      expect(fake.lastPassword, 'hunter2');
    });

    test('reuses a supplied serverStatus instead of fetching it again',
        () async {
      final fake = FakeAudiobookshelfClient(authResult: _authResult);
      final authenticator = AudiobookshelfAuthenticator(fake);

      final session = await authenticator.signIn(
        rawUrl: 'audiobooks.example.com',
        username: 'jon',
        password: 'hunter2',
        serverStatus: _status,
      );

      expect(session.serverVersion, '2.19.0');
      // Never called: the supplied status was reused, not re-fetched.
      expect(fake.serverStatusCallCount, 0);
    });

    test('reads server status itself when none is supplied', () async {
      final fake = FakeAudiobookshelfClient(
        serverStatus: _status,
        authResult: _authResult,
      );
      final authenticator = AudiobookshelfAuthenticator(fake);

      final session = await authenticator.signIn(
        rawUrl: 'audiobooks.example.com',
        username: 'jon',
        password: 'hunter2',
      );

      expect(session.serverVersion, '2.19.0');
      expect(fake.serverStatusCallCount, 1);
    });

    test(
        'a status-fetch failure blocks sign-in, credentials are never sent '
        'to an unconfirmed address', () async {
      final fake = FakeAudiobookshelfClient(
        authResult: _authResult,
        serverStatusError: AudiobookshelfException.notReachable(),
      );
      final authenticator = AudiobookshelfAuthenticator(fake);

      expect(
        () => authenticator.signIn(
          rawUrl: 'audiobooks.example.com',
          username: 'jon',
          password: 'hunter2',
        ),
        throwsA(isA<AudiobookshelfException>()),
      );
      expect(fake.lastUsername, isNull);
      expect(fake.lastPassword, isNull);
    });

    test('an empty username is rejected before any request is made', () async {
      final fake = FakeAudiobookshelfClient(authResult: _authResult);
      final authenticator = AudiobookshelfAuthenticator(fake);

      expect(
        () => authenticator.signIn(
          rawUrl: 'audiobooks.example.com',
          username: '   ',
          password: 'hunter2',
        ),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.unauthorized,
          ),
        ),
      );
      expect(fake.lastUsername, isNull);
    });

    test('rejected credentials surface as the client\'s own exception',
        () async {
      final fake = FakeAudiobookshelfClient(
        serverStatus: _status,
        authError: AudiobookshelfException.unauthorized(),
      );
      final authenticator = AudiobookshelfAuthenticator(fake);

      expect(
        () => authenticator.signIn(
          rawUrl: 'audiobooks.example.com',
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
}
