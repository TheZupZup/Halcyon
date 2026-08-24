# Flatpak (local build — issues #432, #433, #434)

This is the packaging **foundation**: enough to build Linthra's native Flutter
Linux bundle inside `flatpak-builder`, install it, launch the real
`io.github.thezupzup.linthra` app from the application menu, and get real,
audible local and remote playback through a fully self-contained audio
runtime. It is deliberately not the Flathub submission — the icon and
AppStream metadata that go with the desktop entry are still open, and so are
the sandbox permissions; see "What's deferred" below and the comments in
`io.github.thezupzup.linthra.yml` itself.

## Audio runtime

The Flatpak bundles its own `libmpv`, built from source together with its
`ffmpeg`/`libplacebo`/`libass` dependencies (see the `modules:` comments in
`flatpak-flutter.yml`) and installed under `/app/lib`. **Host `mpv-libs` /
`libmpv` is never used and is not required to install or run the Flatpak** —
`media_kit`/`just_audio_media_kit` dlopen the bundled copy, which resolves
before anything under `/usr/lib*` or `/lib*` because the Flatpak sandbox
exposes no host library path. Playback uses `--socket=pulseaudio` for audio
output, which reaches both a native PulseAudio session and PipeWire's
`pipewire-pulse` compatibility server (there is no separate PipeWire
finish-arg). The bundled ffmpeg is also built with `--enable-network
--enable-gnutls`, so the same libmpv decodes local files and plays HTTP(S)
audio streams (Jellyfin, Navidrome/Subsonic, Plex) without any host codec or
TLS library — see the `ffmpeg` module comments for exactly which formats that
covers and why no additional codec library was needed.

**Native, non-Flatpak Linthra is unaffected**: `flutter build linux` outside
this packaging still links nothing at build time and still expects the
system `mpv-libs`/`libmpv` runtime documented in
[docs/linux-desktop.md](../docs/linux-desktop.md#required-packages). The two
are independent audio runtimes by design; only the Flatpak is self-contained.

## Desktop entry

`../linux/packaging/io.github.thezupzup.linthra.desktop` is what puts Linthra
in the application menu. The `linthra` module installs it verbatim:

```
install -Dm644 linux/packaging/io.github.thezupzup.linthra.desktop \
  /app/share/applications/io.github.thezupzup.linthra.desktop
```

`/app/share/applications` is the only directory flatpak-builder exports from at
`finish` time, and it only exports files whose name starts with the app id —
this one *is* the app id, so there is no `rename-desktop-file` in the manifest.
Export
rewrites `Exec=linthra` into the host-side `flatpak run …` form, so the entry
carries the bare command and no absolute path; the same file works unchanged
for a native package that puts `linthra` on `PATH`.

Two things keep it honest, both offline and both already in CI
(`.github/workflows/linux-desktop-build.yml`):

```bash
desktop-file-validate linux/packaging/io.github.thezupzup.linthra.desktop
python3 scripts/check_linux_runner.py
```

The first is syntax — note that `desktop-file-validate` exits 0 even for
warnings and "will be fatal in the future" errors, so CI and
`scripts/verify_linux.sh` treat *any* output from it as a failure rather than
trusting its exit status. The second is identity: `scripts/check_linux_runner.py`
checks the entry's filename, `Name`, `Exec`, `Icon` and `Categories` against
the same sources of truth the Linux runner is held to (`AppInfo.name`,
`pubspec.yaml`'s `name`, Android's `applicationId`), and checks that **both**
this directory's manifests — the hand-authored template and the generated
manifest — actually install it, so a regeneration that was never run shows up
as a failure rather than as a Flatpak with no menu entry.

## Files here

| File | What it is |
| --- | --- |
| `flatpak-flutter.yml` | Hand-authored input. Never built directly. |
| `../linux/packaging/io.github.thezupzup.linthra.desktop` | Hand-authored, and not Flatpak-only: the installed desktop entry (#434), which this manifest copies into `/app/share/applications/` for flatpak-builder to export. It lives beside the rest of the Linux packaging inputs rather than here so a future native package installs the same file. |
| `io.github.thezupzup.linthra.yml` | **Generated.** The real manifest `flatpak-builder` consumes. Do not hand-edit — regenerate instead (below). |
| `generated/sources/pubspec.json` | **Generated.** One pinned, hashed source per package in the committed `pubspec.lock` (plus Flutter's own internal `flutter_tools` package), so `flutter pub get --offline` inside the sandbox never touches pub.dev. Also carries two known per-plugin fixes from flatpak-flutter's own `foreign-deps` database: `sqlite3_flutter_libs` and `media_kit_libs_linux`'s own CMake `FetchContent` downloads (sqlite amalgamation, mimalloc) are pre-placed at the exact cache paths CMake checks before downloading, so they're satisfied without a network hit even though `linux/CMakeLists.txt` already disables/redirects both independently. |
| `generated/modules/flutter-sdk-3.44.7.json` | **Generated.** Pins the Dart SDK and Linux engine artifacts for the exact `.flutter-version` tag by their real `storage.googleapis.com` URLs and sha256, plus a small patch so Flutter's own internal tool bootstrap runs `pub upgrade --offline`. |
| `generated/patches/` | **Generated.** The two patches referenced above. |

## Building, installing, running

The full contributor workflow — host tools, build, install, run, rebuild,
clean/uninstall and debugging, written for Fedora Atomic (Kinoite/Silverblue)
and usable anywhere else — is
[docs/flatpak-development.md](../docs/flatpak-development.md). The short
version, run from this directory:

```bash
flatpak run org.flatpak.Builder --user --force-clean --repo=repo \
  flatpak-builder-build io.github.thezupzup.linthra.yml

flatpak --user remote-add --if-not-exists --no-gpg-verify linthra-dev repo
flatpak --user install -y linthra-dev io.github.thezupzup.linthra

flatpak run io.github.thezupzup.linthra
```

On a distribution with a native `flatpak-builder`, drop the
`flatpak run org.flatpak.Builder` prefix and run plain `flatpak-builder ...`.
To uninstall: `flatpak --user uninstall io.github.thezupzup.linthra` and
`flatpak --user remote-delete linthra-dev`.

Nothing above needs network access during the actual sandboxed build —
`flatpak-builder`'s normal declared-source fetch (`generated/sources/pubspec.json`,
the Flutter SDK module, the ffmpeg/libplacebo/libass/mpv archives) happens
before the sandbox is entered, exactly like any other Flatpak module.

## Testing audio locally

The committed manifest grants `--socket=pulseaudio` but no filesystem or
network access, matching #438/#439/#440's scope. To manually verify playback
of your own local files or a real remote stream, pass the extra permission to
`flatpak run` itself. Options given there apply to that one invocation only,
so there is nothing to revoke afterwards and nothing is left behind:

```bash
# Local file: read-only access to a directory with a test track, for this
# launch only. Play it from within the app.
flatpak run --filesystem=/path/to/test-music:ro io.github.thezupzup.linthra

# Remote HTTP(S) stream: same idea with network instead.
flatpak run --share=network io.github.thezupzup.linthra
```

Do **not** use `flatpak override` for this. Its grants are persistent, and the
apparent undo is not one: `--nofilesystem=…`/`--unshare=network` record a
*negative* override on top of the grant rather than deleting it, so the app
keeps leftover permission state either way. `--reset` is worse — it wipes
*every* persistent override you have for this app, including unrelated ones
you set yourself. A one-shot `flatpak run` permission avoids the whole problem.

Never add these permissions to `io.github.thezupzup.linthra.yml` either: a
committed grant is #440's (network) and #438/#439's (filesystem) decision, not
a testing convenience. The package itself is unchanged by the runs above, and
stays that way:

```bash
flatpak info --show-permissions io.github.thezupzup.linthra
# Still only the manifest's finish-args — a permission passed to `flatpak run`
# never appears here.
```

Automated audio smoke coverage is #446's job, not this file's.

## Regenerating the pinned sources

Re-run this whenever `.flutter-version` or `pubspec.lock` changes:

```bash
./scripts/regenerate_flatpak_sources.sh
```

It fetches [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter)
(the tool referenced by Flutter's own deployment docs and by
`flatpak/flatpak-builder-tools`) into `.tool/` if needed — pinned to an exact
commit SHA in `scripts/regenerate_flatpak_sources.sh` (`TOOL_COMMIT`, the
`0.15.0` release), never a moving branch — and re-generates
`io.github.thezupzup.linthra.yml` and `generated/` from `flatpak-flutter.yml`
and the current `pubspec.lock`. Diff the result before committing.

## What's deferred

Not in this manifest — each has its own issue:

* **AppStream metainfo** (#435), **scalable icon packaging** (#436) — no
  `<app-id>.metainfo.xml` and no icon is installed, so the desktop entry's
  `Icon=io.github.thezupzup.linthra` currently resolves to nothing and the
  launcher falls back to a generic icon. The entry deliberately names the icon
  anyway: #436 installs the files under exactly that name and nothing here has
  to change when it lands. `rename-desktop-file`/`rename-icon` are not used and
  are not needed — everything is installed under the app id already.
* **Provider network access** (#440) — no permanent `--share=network`.
  #433 proved the bundled ffmpeg/libmpv can decode HTTP(S) audio using only a
  temporary, non-committed grant for that validation (see
  [Testing audio locally](#testing-audio-locally)); permanently granting
  Linthra network access for real provider use
  (Jellyfin/Navidrome-Subsonic/Plex) is #440's job, not this manifest's.
* **Filesystem/portal permissions** (#438/#439), **Secret Service** (#441) —
  no `--filesystem=host|home` or `--talk-name=org.freedesktop.secrets`.
  Jellyfin/Subsonic/Plex session restore and secure-storage reads already
  degrade to "not signed in" without them (`docs/linux-desktop.md` §"Secure
  storage"). #433's local-audio validation likewise used a temporary,
  non-committed filesystem grant rather than a committed one.
* **Video codecs, hardware acceleration/hwaccel, subtitle-adjacent tuning
  beyond what libmpv/libass require to build** — Linthra is audio-only; the
  ffmpeg/mpv build stays scoped to the container/codec/protocol support
  Linthra's supported formats and HTTP(S) streaming actually need.
* **CI** (#444), **automated launch/audio smoke tests** (#445/#446), **local-
  library sandbox test** (#447) — out of scope here; this file is the minimal
  "how do I build and validate this locally" note #432/#433 asked for, and
  [docs/flatpak-development.md](../docs/flatpak-development.md) is the
  contributor workflow around it.
