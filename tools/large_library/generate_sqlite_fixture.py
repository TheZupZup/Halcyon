#!/usr/bin/env python3
"""Generate a deterministic Linthra-shaped SQLite catalog for performance work."""

from __future__ import annotations

import argparse
import sqlite3
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCHEMA = ROOT / "schema.sql"


def normalized(value: str) -> str:
    return " ".join(value.casefold().split())


def row(index: int) -> tuple[object, ...]:
    providers = ("local", "jellyfin", "navidrome", "plex")
    provider = providers[index % len(providers)]
    artist_number = index % 1_500
    album_number = index % 2_500
    artist = f"Artist {artist_number}"
    album = f"Album {album_number}"
    title = f"Track {index} Midnight Signal"
    album_artist = "Various Artists" if index % 29 == 0 else artist
    album_id = f"{provider}:album:{album_number}"
    return (
        index + 1,
        provider,
        f"{provider}-track-{index}",
        title,
        normalized(title),
        artist,
        normalized(artist),
        album,
        normalized(album),
        album_artist,
        normalized(album_artist),
        album_id,
        1_700_000_000 + index,
    )


def generate(output: Path, track_count: int, batch_size: int = 5_000) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()

    started = time.perf_counter()
    connection = sqlite3.connect(output)
    try:
        connection.executescript(SCHEMA.read_text(encoding="utf-8"))
        insert = """
            INSERT INTO tracks (
                id, provider, provider_track_id, title, normalized_title,
                artist_name, normalized_artist, album_name, normalized_album,
                album_artist_name, normalized_album_artist, album_id, date_added
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        for start in range(0, track_count, batch_size):
            stop = min(start + batch_size, track_count)
            connection.executemany(insert, (row(index) for index in range(start, stop)))
        connection.commit()
    finally:
        connection.close()

    elapsed = time.perf_counter() - started
    size_mb = output.stat().st_size / (1024 * 1024)
    print(
        f"generated {track_count:,} tracks in {elapsed:.2f}s "
        f"({size_mb:.1f} MiB): {output}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tracks", type=int, default=200_000)
    args = parser.parse_args()
    if args.tracks <= 0:
        parser.error("--tracks must be positive")
    generate(args.output, args.tracks)


if __name__ == "__main__":
    main()
