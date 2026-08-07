# Contributing by language

Linthra is a Flutter app, but the project is deliberately becoming polyglot where a language has a real technical job. You do **not** need to learn Dart before you can make a meaningful contribution.

| Language | Owns / improves | Main area |
| --- | --- | --- |
| Dart / Flutter | UI, playback orchestration, providers, onboarding, cross-platform app logic | `lib/`, `test/` |
| Kotlin | Android platform integration, SAF/MediaStore, media session, Android Auto, system channels | `android/app/src/main/kotlin/` |
| Rust | large-library indexing/search, future grouping and duplicate primitives | `native/linthra_core/` |
| C++ | realtime audio DSP, EQ/limiting, future audio analysis and SIMD work | `native/linthra_audio/` |
| Python | release tooling, large-library fixtures, benchmarks, validation | `scripts/`, `tool/`, `tools/` |
| SQL | SQLite schema/index/query performance for very large catalogs | `tools/large_library/schema.sql` and Drift/database work |

## Dart / Flutter

Choose Dart when the change is visible app behaviour: screens, navigation, source/provider flows, player state, caching policy, settings, or tests around those features. Flutter remains the product shell and orchestration layer.

## Kotlin / Android

Choose Kotlin when Android itself is the feature. Linthra already has native channels for scoped-storage scanning, launcher icons, sharing, connectivity, display refresh rate and media artwork. Android Auto/media-session work belongs here when it needs Android APIs rather than Flutter widgets.

## Rust / large libraries

`linthra_core` targets the work that becomes expensive at 100,000–200,000 tracks. Its first responsibility is indexed search with a synthetic 200k regression benchmark. Good follow-up areas include compact index persistence, incremental updates, duplicate candidates, grouping primitives, memory profiling and the eventual stable Flutter FFI boundary.

## C++ / audio DSP

`linthra_audio` owns realtime signal processing. The callback must stay bounded, allocation-free and lock-free. EQ, limiter behaviour, SIMD, channel layouts and loudness/peak analysis are useful C++ contribution areas. The current core is intentionally separated from the `just_audio` mobile binding so DSP math can be reviewed independently from Android playback plumbing.

## Python / tooling

Python should remove repetitive maintainer work or create useful developer fixtures. Linthra already uses Python in release/branding tooling; `tools/large_library/` adds deterministic 200k-track SQLite generation and query benchmarks using only the standard library.

## SQL / database performance

SQL matters when a query that feels instant at 5,000 tracks becomes obvious at 200,000. Contributions should include the query plan and a representative fixture/benchmark when possible. Avoid adding indexes speculatively: each index costs storage and write time, so keep ones that serve measured access patterns.

## Cross-language rule

A language does not enter Linthra just to appear in GitHub's language bar. New native/tooling code should have a clear owner, tests or benchmarks, a small boundary to the rest of the app, and a reason it is better suited to that job than the existing layer.
