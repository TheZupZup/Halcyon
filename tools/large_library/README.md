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

Each query prints its own line, then a summary block:

```
benchmark summary
  tracks:                   200,000
  queries:                        4
  iterations per query:         200
  sum of query averages:      4.250 ms
  average per query:          1.062 ms
  slowest single run:         9.500 ms (provider album)
```

Every query is timed the same number of times and reported as a mean, so
`sum of query averages` adds up those per-query means rather than the
wall-clock time the run spent querying, and `slowest single run` is the single
slowest timed iteration, not the slowest query on average.

The summary rendering has unit tests:

```bash
python3 test/tooling/large_library_benchmark_test.py
```

The scripts use only Python's standard library. `schema.sql` is a performance sandbox shaped like the fields Linthra cares about; it is **not** a replacement for the Drift production schema. A useful SQL contribution should show the access pattern it improves and, where practical, the `EXPLAIN QUERY PLAN` result that proves the intended index is used.
