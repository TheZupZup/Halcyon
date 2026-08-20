import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/persisted_playback_session.dart';
import '../../core/repositories/playback_session_store.dart';

/// A [PlaybackSessionStore] backed by `shared_preferences`.
///
/// A single JSON document is the right weight for one queue snapshot (the same
/// reasoning playlists and play history follow). A corrupt, wrong-version, or
/// secret-bearing record reads as "no session" rather than crashing startup.
///
/// Security: only logical track identity, modes, and position are written —
/// never a token or authenticated stream URL. [PersistedPlaybackSession.fromJson]
/// re-validates on read as a second line of defense.
class SharedPreferencesPlaybackSessionStore implements PlaybackSessionStore {
  const SharedPreferencesPlaybackSessionStore();

  static const String key = 'playback_session_v1';

  @override
  Future<PersistedPlaybackSession?> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    return PersistedPlaybackSession.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  @override
  Future<void> save(PersistedPlaybackSession session) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(session.toJson()));
  }

  @override
  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}
