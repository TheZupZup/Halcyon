# Vendored `just_audio_media_kit`

Linthra vendors this package for one reason: upstream has no public hook for
setting extra libmpv options at player creation, and Linthra needs one on two
paths — production playback and the headless audio smoke test. Everything here
is upstream source except the two hunks in [`upstream.patch`](upstream.patch).

## Provenance

| | |
| --- | --- |
| Package | [`just_audio_media_kit`](https://pub.dev/packages/just_audio_media_kit) |
| Version | 2.1.0 |
| Upstream archive | `https://pub.dev/api/archives/just_audio_media_kit-2.1.0.tar.gz` |
| Archive SHA-256 | `f3cf04c3a50339709e87e90b4e841eef4364ab4be2bdbac0c54cc48679f84d23` |
| Upstream repository | <https://github.com/Pato05/just_audio_media_kit> |
| License | MIT (`LICENSE`, unmodified) |

The archive digest is the same `sha256` `pubspec.lock` recorded for the hosted
dependency before it was vendored, so the swap is verifiable against the
lockfile history rather than on trust.

### What is vendored

Every file pub ships in the package archive **except `example/`** (a full
sample Flutter app: not compiled, not analyzed, and not part of the dependency).
`upstream.sha256` lists each vendored file with its **pristine upstream**
digest; `pubspec.lock` is Linthra's own addition, so the standalone analysis of
this package resolves deterministically.

## The patch

Two hunks, ten added lines, no deletions:

1. `lib/just_audio_media_kit.dart` — adds `JustAudioMediaKit.mpvProperties`, an
   optional `Map<String, String>` that defaults to empty.
2. `lib/mediakit_player.dart` — applies each entry with the package's existing
   `setProperty` helper right after `Player()` construction, next to the
   identical `prefetch-playlist` call upstream already makes.

Nothing else changes: no new dependency, no new I/O, no new process or library
loading. With the map left empty the generated libmpv calls are byte-for-byte
what upstream makes; Linthra does not leave it empty (see below), so the
difference from upstream is exactly the properties it sets and nothing more.

### Why

Headless Linux CI has no PipeWire/Pulse device. libmpv autoselects PipeWire on
Ubuntu and fails to open the WAV even when `ALSA_CONFIG_PATH` points the default
PCM at the null plugin, so the native audio lifecycle smoke test needs `ao=alsa`
set on each libmpv instance before playback starts. Upstream exposes
`setProperty` internally but has no public hook for extra mpv options at player
creation (unlike `prefetchPlaylist`).

### Who sets it

**Two callers, and production is one of them.** This hook is *not* CI-only —
removing it breaks shipped playback behaviour, not just a test.

| Caller | Sets | Why |
| --- | --- | --- |
| `lib/core/services/linux_playback_controller.dart` (`linuxMpvProperties`) | `cache-on-disk=no` | media_kit turns mpv's on-disk demuxer cache on for every player; Linthra streams audio and manages its own offline cache, and mpv logs `[lavf] Failed to create file cache.` on every stream where it cannot write the temporary file ([#405](https://github.com/thezupzup/linthra/issues/405)). |
| `tool/linux_audio_backend_smoke.dart` | `ao=alsa` | The headless CI case described above. |

The smoke target layers its value on top of the production defaults rather than
replacing them (`resolveLinuxMpvProperties` merges), so CI exercises the same
cache configuration production uses, with only the output device swapped.

## Auditing this directory

`./scripts/check_vendored_packages.sh` verifies the whole claim above **offline**
(no downloads): it reverse-applies `upstream.patch` onto a copy of the vendored
tree and checks the result against `upstream.sha256`. If the two hunks are the
only local change, the restored files hash to upstream's; any other edit — or a
patch that no longer describes the tree — fails the check.

The same script analyzes the package from its own directory with the
repository's pinned Flutter toolchain, because the root `analysis_options.yaml`
excludes `third_party/**` (upstream code is not held to Linthra's stricter lint
set). CI runs it on every PR.

### Refreshing against a new upstream version

1. Download the new archive and verify its `sha256` against pub.dev.
2. Replace every file listed in `upstream.sha256` with the new upstream copy and
   regenerate that manifest from the pristine tree.
3. Re-apply the two hunks (`git apply upstream.patch`, or by hand if they moved)
   and regenerate `upstream.patch` from the pristine-vs-vendored diff. **Do not
   drop them because upstream gained something similar** without checking both
   callers in *Who sets it* first: production playback depends on this hook, so
   losing it is a silent behaviour change, not a test-only regression.
4. Update the table above, refresh `pubspec.lock`, and run
   `./scripts/check_vendored_packages.sh`.
5. If upstream ever adds its own public hook for player-creation properties,
   move both callers onto it and drop the patch — that is the outcome this
   vendoring exists to make unnecessary.
