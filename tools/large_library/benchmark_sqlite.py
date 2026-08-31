#!/usr/bin/env python3
"""Regression benchmark for Linthra-shaped SQLite queries at large scale."""

from __future__ import annotations

import argparse
import sqlite3
import statistics
import time
from pathlib import Path

QUERIES: tuple[tuple[str, str, tuple[object, ...]], ...] = (
    (
        "title prefix",
        "SELECT id, title FROM tracks WHERE normalized_title LIKE ? LIMIT 50",
        ("track 199%",),
    ),
    (
        "artist exact",
        "SELECT id, title FROM tracks WHERE normalized_artist = ? LIMIT 100",
        ("artist 421",),
    ),
    (
        "provider album",
        "SELECT id, title FROM tracks WHERE provider = ? AND album_id = ? LIMIT 100",
        ("navidrome", "navidrome:album:311"),
    ),
    (
        "recently added",
        "SELECT id, title FROM tracks ORDER BY date_added DESC LIMIT 50",
        (),
    ),
)


def query_plan(
    connection: sqlite3.Connection, sql: str, params: tuple[object, ...]
) -> str:
    rows = connection.execute(f"EXPLAIN QUERY PLAN {sql}", params).fetchall()
    return " | ".join(str(row[3]) for row in rows)


def benchmark(
    connection: sqlite3.Connection,
    sql: str,
    params: tuple[object, ...],
    iterations: int,
) -> tuple[float, float, float]:
    samples_ms: list[float] = []
    for _ in range(iterations):
        started = time.perf_counter_ns()
        connection.execute(sql, params).fetchall()
        samples_ms.append((time.perf_counter_ns() - started) / 1_000_000)
    return (
        statistics.mean(samples_ms),
        statistics.quantiles(samples_ms, n=20)[18],
        max(samples_ms),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--max-average-ms", type=float, default=50.0)
    args = parser.parse_args()

    connection = sqlite3.connect(f"file:{args.database}?mode=ro", uri=True)
    connection.execute("PRAGMA case_sensitive_like = ON")
    try:
        count = connection.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        print(f"catalog: {count:,} tracks")

        failed = False
        results: list[tuple[str, float, float, float]] = []
        for name, sql, params in QUERIES:
            plan = query_plan(connection, sql, params)
            average_ms, p95_ms, max_ms = benchmark(
                connection, sql, params, args.iterations
            )
            results.append((name, average_ms, p95_ms, max_ms))
            print(
                f"{name:16} avg={average_ms:8.3f} ms p95={p95_ms:8.3f} ms plan={plan}"
            )

            # Every benchmark query has a matching index in schema.sql. A full
            # table scan is therefore a schema/query regression, even if a fast
            # CI machine happens to hide it in wall-clock timing.
            if "SCAN tracks" in plan and "USING INDEX" not in plan:
                print(f"ERROR: {name} fell back to a full table scan")
                failed = True
            if average_ms > args.max_average_ms:
                print(
                    f"ERROR: {name} exceeded the {args.max_average_ms:.1f} ms "
                    "average-query budget"
                )
                failed = True

        total_average_ms = sum(average_ms for _, average_ms, _, _ in results)
        average_query_ms = total_average_ms / len(results)
        slowest_name, _, _, slowest_max_ms = max(results, key=lambda result: result[3])

        print()
        print("benchmark summary")
        print(f"  tracks:            {count:,}")
        print(f"  queries:           {len(results)}")
        print(f"  iterations:  	     {args.iterations:,}")
        print(f"  total query time:  {total_average_ms:8.3f} ms")
        print(f"  average/query:     {average_query_ms:8.3f} ms")
        print(f"  slowest query:     {slowest_max_ms:8.3f} ms ({slowest_name})")
        if failed:
            raise SystemExit(1)
    finally:
        connection.close()


if __name__ == "__main__":
    main()
