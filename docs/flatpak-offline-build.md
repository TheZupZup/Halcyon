# Flatpak network-independent build audit

Issue: #442  
Parent: #376

Linthra's Flatpak is designed so the **build itself does not need network
access**. Network is used only before the sandboxed build, when
`flatpak-builder` fetches sources that are already declared in the manifest and
content-addressed where the source type supports it.

This distinction matters:

- **source-fetch phase:** network is allowed so `flatpak-builder` can download
  the exact URLs declared by the manifest;
- **build phase:** no undeclared download is permitted. Dart packages, Flutter
  artifacts, native archives and plugin inputs must already be present.

## Sources of truth

The hand-authored input is `flatpak/flatpak-flutter.yml`. The file actually
consumed by `flatpak-builder` is the generated
`flatpak/io.github.thezupzup.linthra.yml`.

`pubspec.lock` remains authoritative for Dart package versions. Running:

```bash
./scripts/regenerate_flatpak_sources.sh
```

uses the pinned `flatpak-flutter` generator to turn that lockfile and the
project's pinned Flutter version into committed source declarations under
`flatpak/generated/`.

The generator itself needs network access because its job is to discover and
record upstream archive URLs and hashes. That is a maintainer-time generation
step, not Flatpak build-time networking.

## Dart / Flutter

`flatpak/generated/sources/pubspec.json` contains one versioned pub.dev archive
for every hosted package in `pubspec.lock`, with a SHA-256 and a destination
inside the build's private `.pub-cache`. Matching hosted-hash entries are also
pre-created.

The generated Flutter SDK module provides `setup-flutter.sh`, whose dependency
resolution command is:

```text
flutter pub get --offline
```

The generated application module then builds with:

```text
flutter build linux --release --no-pub
```

So neither dependency resolution nor the Flutter build can silently refresh a
package from pub.dev during the Flatpak build.

The authoritative template still says `flutter pub get --enforce-lockfile`;
the generator converts that into the offline setup step while preserving the
committed lockfile as the dependency set.

## Native sources

The generated manifest declares the native runtime chain explicitly. Current
modules include FFmpeg, libplacebo and its build helpers, libass, and mpv. Each
archive source carries a SHA-256.

Two Flutter plugins deserve special attention because their upstream Linux
builds can otherwise fetch native code from CMake:

### sqlite3_flutter_libs

The plugin normally obtains the SQLite amalgamation with `FetchContent`.
Linthra's `linux/CMakeLists.txt` provides `LINTHRA_SQLITE3_SOURCE_DIR` and sets
`FETCHCONTENT_SOURCE_DIR_SQLITE3` before generated plugin CMake is included.
The Flatpak source generator also predeclares the exact SQLite archive used by
the locked plugin version.

### media_kit_libs_linux

The plugin can optionally fetch/build mimalloc. Linthra does not require that
allocator and forces:

```cmake
MIMALLOC_USE_STATIC_LIBS OFF
```

before generated plugin CMake is included. The generated source set also
contains the plugin's pinned mimalloc input, so a generator/plugin change cannot
quietly depend on a warm developer cache.

## Automatic regression guard

`test/tooling/flatpak_offline_build_test.dart` runs with the normal Flutter test
suite. It checks that:

- the template keeps lockfile enforcement and a `--no-pub` build;
- the generated build uses the offline setup script and has no build network
  grant;
- every hosted package/version in `pubspec.lock` has a generated pub-cache
  archive and hosted-hash entry;
- generated archive downloads have SHA-256 values;
- the SQLite pre-fetch seam and mimalloc-disable switch remain in CMake;
- the generated source set still carries the known SQLite/mimalloc native
  inputs;
- top-level native archive sources in the generated manifest remain hashed.

This is intentionally a structural CI guard. The end-to-end proof is the build
smoke below.

## End-to-end offline build smoke

Install the Flatpak build prerequisites from `docs/flatpak-development.md`, then
run from the repository root:

```bash
bash scripts/flatpak_offline_build_smoke.sh
```

The script performs two separate `flatpak-builder` invocations against the
**generated** manifest:

1. `--download-only` fetches the manifest-declared sources into
   flatpak-builder's source cache and exits;
2. the module build directory is discarded, then a clean build runs with
   `--disable-download`.

The second phase therefore cannot ask flatpak-builder to retrieve a missing
source. Normal flatpak-builder build sandboxing also means a hidden `pub get`,
CMake `FetchContent`, curl/wget, or similar undeclared build-time download does
not get a network escape hatch from Linthra's runtime `--share=network` finish
argument.

A failure in phase 2 is useful: it means something required by the build was not
properly declared/prefetched, which is exactly what #442 is meant to catch.

The smoke deliberately uses the normal `.flatpak-builder` source cache between
the two phases. That is not a developer pub cache: it is flatpak-builder's own
cache populated exclusively from the manifest during phase 1. The app module's
`PUB_CACHE` points into `/run/build/linthra/.pub-cache`, populated by declared
sources for that build.

## Clean-machine validation

For the strongest local validation, start without Linthra's previous Flatpak
build state:

```bash
cd flatpak
rm -rf .flatpak-builder flatpak-builder-offline-smoke
cd ..
bash scripts/flatpak_offline_build_smoke.sh
```

Deleting `.flatpak-builder` is intentionally expensive: the first phase must
redownload and the second must rebuild the entire FFmpeg/libplacebo/libass/mpv
chain. Do it for release/Flathub readiness testing, not for every edit.

Do **not** copy a host `~/.pub-cache` into the build tree. A successful smoke
must come only from the generated source declarations.

## Updating dependencies

When `pubspec.lock` or `.flutter-version` changes:

1. run `./scripts/regenerate_flatpak_sources.sh`;
2. review changes to the generated manifest and `flatpak/generated/`;
3. run normal CI/tests, including `flatpak_offline_build_test.dart`;
4. run `bash scripts/flatpak_offline_build_smoke.sh` when Flatpak is available;
5. for release/submission readiness, repeat once from a deleted
   `.flatpak-builder` cache.

Do not hand-edit generated source lists to make an offline failure disappear.
Fix the authoritative dependency/source input or the generation rule, then
regenerate so the result stays reviewable and reproducible.
