import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/shared_preferences_playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const Track track = Track(
    id: '101',
    title: 'Song',
    uri: 'jellyfin:101',
    duration: Duration(minutes: 4),
  );

  group('SharedPreferencesPlaybackSessionStore', () {
    test('round-trips a logical session', () async {
      const SharedPreferencesPlaybackSessionStore store =
          SharedPreferencesPlaybackSessionStore();
      const PersistedPlaybackSession session = PersistedPlaybackSession(
        tracks: <Track>[track],
        currentIndex: 0,
        position: Duration(seconds: 12),
        shuffleEnabled: false,
        repeatMode: RepeatMode.off,
      );

      await store.save(session);
      final PersistedPlaybackSession? loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.current!.uri, 'jellyfin:101');
      expect(loaded.position, const Duration(seconds: 12));
    });

    test('returns null for no stored value', () async {
      const SharedPreferencesPlaybackSessionStore store =
          SharedPreferencesPlaybackSessionStore();
      expect(await store.load(), isNull);
    });

    test('a corrupt record reads as no session', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPreferencesPlaybackSessionStore.key: 'not json {',
      });
      const SharedPreferencesPlaybackSessionStore store =
          SharedPreferencesPlaybackSessionStore();
      expect(await store.load(), isNull);
    });

    test('a wrong-version record reads as no session', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPreferencesPlaybackSessionStore.key: jsonEncode(<String, dynamic>{
          'v': 99,
          'i': 0,
          'p': 0,
          's': false,
          'r': 'off',
          't': <Map<String, dynamic>>[logicalTrackToJson(track)],
        }),
      });
      const SharedPreferencesPlaybackSessionStore store =
          SharedPreferencesPlaybackSessionStore();
      expect(await store.load(), isNull);
    });

    test('persisted document never contains stream URLs or tokens', () async {
      const String token = 'super-secret-token-1234567890';
      const SharedPreferencesPlaybackSessionStore store =
          SharedPreferencesPlaybackSessionStore();
      await store.save(const PersistedPlaybackSession(
        tracks: <Track>[track],
        currentIndex: 0,
      ));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw =
          prefs.getString(SharedPreferencesPlaybackSessionStore.key) ?? '';
      expect(raw, contains('jellyfin:101'));
      expect(raw, isNot(contains(token)));
      expect(raw, isNot(contains('http')));
      expect(raw, isNot(contains('api_key')));
      expect(raw, isNot(contains('AccessToken')));
    });

    test('clear removes the document', () async {
      const SharedPreferencesPlaybackSessionStore store =
          SharedPreferencesPlaybackSessionStore();
      await store.save(const PersistedPlaybackSession(
        tracks: <Track>[track],
        currentIndex: 0,
      ));
      await store.clear();
      expect(await store.load(), isNull);
    });
  });
}
