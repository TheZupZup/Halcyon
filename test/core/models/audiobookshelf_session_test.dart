import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';

const _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-abc',
  refreshToken: 'refresh-xyz',
  userName: 'jon',
  defaultLibraryId: 'lib-1',
  serverVersion: '2.19.0',
);

void main() {
  group('toJson / fromJson', () {
    test('round-trips every field', () {
      final Map<String, dynamic> json = _session.toJson();
      final AudiobookshelfSession? rebuilt =
          AudiobookshelfSession.fromJson(json);
      expect(rebuilt, _session);
    });

    test('round-trips with the optional fields absent', () {
      const minimal = AudiobookshelfSession(
        baseUrl: 'https://audiobooks.example.com',
        userId: 'user-1',
        accessToken: 'tok-abc',
      );
      final AudiobookshelfSession? rebuilt =
          AudiobookshelfSession.fromJson(minimal.toJson());
      expect(rebuilt, minimal);
      expect(rebuilt!.refreshToken, isNull);
      expect(rebuilt.userName, isNull);
      expect(rebuilt.defaultLibraryId, isNull);
      expect(rebuilt.serverVersion, isNull);
    });

    test('a missing required field returns null instead of throwing', () {
      expect(
        AudiobookshelfSession.fromJson(<String, dynamic>{
          'userId': 'user-1',
          'accessToken': 'tok-abc',
        }),
        isNull,
      );
      expect(
        AudiobookshelfSession.fromJson(<String, dynamic>{
          'baseUrl': 'https://audiobooks.example.com',
          'accessToken': 'tok-abc',
        }),
        isNull,
      );
      expect(
        AudiobookshelfSession.fromJson(<String, dynamic>{
          'baseUrl': 'https://audiobooks.example.com',
          'userId': 'user-1',
        }),
        isNull,
      );
    });

    test('an empty required field is treated as missing', () {
      expect(
        AudiobookshelfSession.fromJson(<String, dynamic>{
          'baseUrl': '',
          'userId': 'user-1',
          'accessToken': 'tok-abc',
        }),
        isNull,
      );
    });
  });

  test('toString redacts both tokens', () {
    final String rendered = _session.toString();
    expect(rendered, isNot(contains('tok-abc')));
    expect(rendered, isNot(contains('refresh-xyz')));
    expect(rendered, contains('<redacted>'));
    // Non-secret fields still show, so the redaction is real (not just an
    // empty toString).
    expect(rendered, contains('user-1'));
    expect(rendered, contains('jon'));
  });

  test('copyWith overrides only the given fields', () {
    final AudiobookshelfSession updated = _session.copyWith(
      accessToken: 'tok-new',
    );
    expect(updated.accessToken, 'tok-new');
    expect(updated.userId, _session.userId);
    expect(updated.refreshToken, _session.refreshToken);
  });

  test('equality and hashCode are value-based', () {
    const other = AudiobookshelfSession(
      baseUrl: 'https://audiobooks.example.com',
      userId: 'user-1',
      accessToken: 'tok-abc',
      refreshToken: 'refresh-xyz',
      userName: 'jon',
      defaultLibraryId: 'lib-1',
      serverVersion: '2.19.0',
    );
    expect(_session, other);
    expect(_session.hashCode, other.hashCode);
  });
}
