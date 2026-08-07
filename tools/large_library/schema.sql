PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA case_sensitive_like = ON;

CREATE TABLE IF NOT EXISTS tracks (
    id INTEGER PRIMARY KEY,
    provider TEXT NOT NULL,
    provider_track_id TEXT NOT NULL,
    title TEXT NOT NULL,
    normalized_title TEXT NOT NULL,
    artist_name TEXT NOT NULL,
    normalized_artist TEXT NOT NULL,
    album_name TEXT NOT NULL,
    normalized_album TEXT NOT NULL,
    album_artist_name TEXT,
    normalized_album_artist TEXT,
    album_id TEXT,
    date_added INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_provider_identity
    ON tracks(provider, provider_track_id);

CREATE INDEX IF NOT EXISTS idx_tracks_title
    ON tracks(normalized_title);

CREATE INDEX IF NOT EXISTS idx_tracks_artist
    ON tracks(normalized_artist);

CREATE INDEX IF NOT EXISTS idx_tracks_album
    ON tracks(normalized_album);

CREATE INDEX IF NOT EXISTS idx_tracks_album_artist
    ON tracks(normalized_album_artist);

CREATE INDEX IF NOT EXISTS idx_tracks_provider_album
    ON tracks(provider, album_id);

CREATE INDEX IF NOT EXISTS idx_tracks_recent
    ON tracks(date_added DESC);
