# Large-library tooling (Python + SQL)

This directory gives Python/SQL contributors a deterministic way to work on Linthra's 100k–200k-track behaviour without needing a personal music server or a huge real library.

Generate a 200k-track SQLite fixture:

```bash
python3 tools/large_library/generate_sqlite_fixture.py \
  --output /tmp/linthra-200k.sqlite \
  --tracks 200000
```

Run representative indexed-query benchmarks:

```bash
python3 tools/large_library/benchmark_sqlite.py \
  --database /tmp/linthra-200k.sqlite
```

The scripts use only Python's standard library. `schema.sql` is a performance sandbox shaped like the fields Linthra cares about; it is **not** a replacement for the Drift production schema. A useful SQL contribution should show the access pattern it improves and, where practical, the `EXPLAIN QUERY PLAN` result that proves the intended index is used.
