import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';

const _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-1',
  refreshToken: 'refresh-1',
  userName: 'alice',
  defaultLibraryId: 'lib-1',
  serverVersion: '2.17.0',
);

void main() {
  group('InMemoryAudiobookshelfSessionStore', () {
    test('starts empty by default', () async {
      final store = InMemoryAudiobookshelfSessionStore();
      expect(await store.read(), isNull);
    });

    test('exposes an initial session', () async {
      final store =
          InMemoryAudiobookshelfSessionStore(initialSession: _session);
      expect(await store.read(), _session);
    });

    test('write then read returns the session', () async {
      final store = InMemoryAudiobookshelfSessionStore();
      await store.write(_session);
      expect(await store.read(), _session);
    });

    test('a later write replaces the previous session', () async {
      final store =
          InMemoryAudiobookshelfSessionStore(initialSession: _session);
      final other = _session.copyWith(userName: 'bob', accessToken: 'tok-2');
      await store.write(other);
      expect(await store.read(), other);
    });

    test('clear forgets the session (sign out)', () async {
      final store =
          InMemoryAudiobookshelfSessionStore(initialSession: _session);
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
