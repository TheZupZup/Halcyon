# linthra_core (Rust)

`linthra_core` is Linthra's high-performance library engine. Its first job is to make searching very large catalogs predictable without making Flutter walk 100,000–200,000 track objects for every keystroke.

## Current scope

- dependency-free Rust core
- immutable inverted index
- title / artist / album / album-artist / provider tokens
- prefix search with AND semantics across query terms
- deterministic ranking
- synthetic 200,000-track regression benchmark

The crate is intentionally **not wired into Flutter yet**. The core is being benchmarked and stabilized behind a small API first; the later FFI binding can then be reviewed independently without mixing Android packaging risk into the indexing algorithm.

## Run it

```bash
cargo test --manifest-path native/linthra_core/Cargo.toml
cargo run --release --manifest-path native/linthra_core/Cargo.toml --bin benchmark_200k
```

The benchmark uses a generous 50 ms average-query regression ceiling so shared CI runners stay reliable. It is a guard against accidentally turning search into an O(full catalog) operation, not a claim that every device will have identical timings.

## Good contribution areas

Rust contributors can work here without knowing Flutter. Useful next steps include Unicode-aware normalization, compact index serialization, incremental index updates, cross-provider duplicate candidates, album grouping primitives, memory benchmarks, and the eventual stable Dart/Flutter FFI boundary.
