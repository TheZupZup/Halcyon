// `Value` only: drift also exports an `isNull` that would collide with
// matcher's.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/database/linthra_database.dart';

/// The v2 → v3 migration (issue #281) adds the nullable `album_id` /
/// `album_artist_name` columns album grouping keys off. It must be purely
/// additive: a user upgrading the app keeps every track already in their
/// offline catalog, with the new columns simply reading back null until the
/// next source re-scan populates them.
///
/// These tests build a *real* v2-shaped `tracks` table by hand, run the
/// database's own [MigrationStrategy] over it, and assert on the result —
/// rather than trusting the schema definition, which is what changed.

/// The exact `tracks` DDL and column list as of schema v2, so the fixture is a
/// genuine pre-migration database rather than today's shape minus two columns.
const String _v2CreateTracks = '''
CREATE TABLE tracks (
  id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  title TEXT NOT NULL,
  uri TEXT NOT NULL,
  artist_name TEXT NULL,
  album_name TEXT NULL,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  track_number INTEGER NULL,
  artwork_uri TEXT NULL,
  PRIMARY KEY (uri)
);
''';

/// Opens a database whose underlying file is already at schema [version] with
/// [seed] rows inserted, then lets the real migration run on first use.
Future<LinthraDatabase> _openMigratedFromV2(
  List<String> seedStatements,
) async {
  final NativeDatabase executor = NativeDatabase.memory(
    setup: (db) {
      db.execute(_v2CreateTracks);
      for (final String statement in seedStatements) {
        db.execute(statement);
      }
      // Mark the file as schema v2 so drift runs onUpgrade(2 -> 3), not
      // onCreate.
      db.execute('PRAGMA user_version = 2;');
    },
  );
  return LinthraDatabase.forTesting(executor);
}

void main() {
  group('v2 → v3 migration', () {
    late LinthraDatabase db;

    tearDown(() async => db.close());

    test('preserves every existing row and all of its values', () async {
      db = await _openMigratedFromV2(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, artist_name, "
            "album_name, duration_ms, track_number, artwork_uri) VALUES "
            "('t1', 'jellyfin', 'One', 'jellyfin:t1', 'Adele', '25', "
            "180000, 1, 'https://media.example/a.jpg');",
        "INSERT INTO tracks (id, source_id, title, uri, artist_name, "
            "album_name, duration_ms, track_number, artwork_uri) VALUES "
            "('t2', 'subsonic', 'Two', 'subsonic:t2', 'Queen', "
            "'Greatest Hits', 240000, 2, NULL);",
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) VALUES "
            "('/music/a.mp3', 'local', 'A', '/music/a.mp3', 0);",
      ]);

      final List<TrackRow> rows = await db.select(db.tracks).get();
      expect(rows, hasLength(3));

      final TrackRow jellyfin =
          rows.firstWhere((TrackRow r) => r.uri == 'jellyfin:t1');
      expect(jellyfin.id, 't1');
      expect(jellyfin.sourceId, 'jellyfin');
      expect(jellyfin.title, 'One');
      expect(jellyfin.artistName, 'Adele');
      expect(jellyfin.albumName, '25');
      expect(jellyfin.durationMs, 180000);
      expect(jellyfin.trackNumber, 1);
      expect(jellyfin.artworkUri, 'https://media.example/a.jpg');

      final TrackRow subsonic =
          rows.firstWhere((TrackRow r) => r.uri == 'subsonic:t2');
      expect(subsonic.albumName, 'Greatest Hits');
      expect(subsonic.artworkUri, isNull);

      final TrackRow local =
          rows.firstWhere((TrackRow r) => r.uri == '/music/a.mp3');
      expect(local.title, 'A');
      expect(local.artistName, isNull);
    });

    test('reads migrated rows back with null album grouping fields', () async {
      db = await _openMigratedFromV2(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, album_name, "
            "duration_ms) VALUES "
            "('t1', 'jellyfin', 'One', 'jellyfin:t1', '25', 0);",
      ]);

      final TrackRow row = await db.select(db.tracks).getSingle();
      // Nothing to backfill from — the source re-scan populates these.
      expect(row.albumId, isNull);
      expect(row.albumArtistName, isNull);
    });

    test('the migrated table accepts writes to the new columns', () async {
      db = await _openMigratedFromV2(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) VALUES "
            "('t1', 'jellyfin', 'One', 'jellyfin:t1', 0);",
      ]);

      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: 't2',
              sourceId: 'jellyfin',
              title: 'Two',
              uri: 'jellyfin:t2',
              albumId: const Value('jellyfin:al-1'),
              albumArtistName: const Value('Main Artist'),
            ),
          );

      final TrackRow written = await (db.select(db.tracks)
            ..where((t) => t.uri.equals('jellyfin:t2')))
          .getSingle();
      expect(written.albumId, 'jellyfin:al-1');
      expect(written.albumArtistName, 'Main Artist');
      // The pre-existing row is untouched.
      expect(await db.select(db.tracks).get(), hasLength(2));
    });

    test('leaves the schema at v3', () async {
      db = await _openMigratedFromV2(<String>[]);
      // Force the migration to run, then read the file's recorded version.
      await db.select(db.tracks).get();
      final result = await db.customSelect('PRAGMA user_version;').getSingle();
      expect(result.data.values.first, 3);
    });
  });

  group('fresh install', () {
    test('creates the v3 shape directly, with the new columns usable',
        () async {
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: 't1',
              sourceId: 'plex',
              title: 'One',
              uri: 'plex:t1',
              albumId: const Value('plex:201'),
              albumArtistName: const Value('Kavinsky'),
            ),
          );

      final TrackRow row = await db.select(db.tracks).getSingle();
      expect(row.albumId, 'plex:201');
      expect(row.albumArtistName, 'Kavinsky');
    });
  });
}
