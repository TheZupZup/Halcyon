# Flatpak (local build — issues #432, #433)

This is the packaging **foundation**: enough to build Linthra's native Flutter
Linux bundle inside `flatpak-builder`, install it, and launch the real
`io.github.thezupzup.linthra` app to real, audible local and remote playback
through a fully self-contained audio runtime. It is deliberately not the
Flathub submission and not a desktop-integrated package — see "What's
deferred" below and the comments in `io.github.thezupzup.linthra.yml` itself.

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

## Files here

| File | What it is |
| --- | --- |
| `flatpak-flutter.yml` | Hand-authored input. Never built directly. |
| `io.github.thezupzup.linthra.yml` | **Generated.** The real manifest `flatpak-builder` consumes. Do not hand-edit — regenerate instead (below). |
| `generated/sources/pubspec.json` | **Generated.** One pinned, hashed source per package in the committed `pubspec.lock` (plus Flutter's own internal `flutter_tools` package), so `flutter pub get --offline` inside the sandbox never touches pub.dev. Also carries two known per-plugin fixes from flatpak-flutter's own `foreign-deps` database: `sqlite3_flutter_libs` and `media_kit_libs_linux`'s own CMake `FetchContent` downloads (sqlite amalgamation, mimalloc) are pre-placed at the exact cache paths CMake checks before downloading, so they're satisfied without a network hit even though `linux/CMakeLists.txt` already disables/redirects both independently. |
| `generated/modules/flutter-sdk-3.44.7.json` | **Generated.** Pins the Dart SDK and Linux engine artifacts for the exact `.flutter-version` tag by their real `storage.googleapis.com` URLs and sha256, plus a small patch so Flutter's own internal tool bootstrap runs `pub upgrade --offline`. |
| `generated/patches/` | **Generated.** The two patches referenced above. |

## Building, installing, running

### Fedora Atomic (Kinoite / Silverblue) — the normal case

`flatpak` itself is already part of the base image. Install `flatpak-builder`
as a Flatpak app rather than layering it — no `rpm-ostree install`, no reboot:

```bash
flatpak install --user flathub org.flatpak.Builder \
  org.gnome.Platform//50 org.gnome.Sdk//50 \
  org.freedesktop.Sdk.Extension.llvm20//25.08

cd flatpak
flatpak run org.flatpak.Builder --user --force-clean --repo=repo \
  flatpak-builder-build io.github.thezupzup.linthra.yml

flatpak --user remote-add --if-not-exists --no-gpg-verify \
  linthra-dev repo
flatpak --user install -y linthra-dev io.github.thezupzup.linthra

flatpak run io.github.thezupzup.linthra
```

(A shell alias, e.g. `alias flatpak-builder='flatpak run org.flatpak.Builder'`
in `~/.bashrc`, lets you type the commands below as-is instead.)

### Fedora Workstation / other distros with a native `flatpak-builder`

Install both from your package manager (Fedora: `sudo dnf install flatpak
flatpak-builder`) and drop the `flatpak run org.flatpak.Builder` prefix —
everywhere above, run plain `flatpak-builder ...` instead.

### Running from inside another sandbox (e.g. this repo opened in the VS Code Flatpak)

If your own terminal is itself inside a Flatpak sandbox, neither `flatpak`
nor `flatpak-builder` is reachable directly — prefix every command above
(from either section) with `flatpak-spawn --host`, e.g.
`flatpak-spawn --host flatpak run org.flatpak.Builder --user ...`. This is
an extra note for that specific situation, not the normal path.

Nothing above needs network access during the actual sandboxed build —
`flatpak-builder`'s normal declared-source fetch (`generated/sources/pubspec.json`,
the Flutter SDK module, the ffmpeg/libplacebo/libass/mpv archives) happens
before the sandbox is entered, exactly like any other Flatpak module.

To uninstall: `flatpak --user uninstall io.github.thezupzup.linthra` and
`flatpak --user remote-delete linthra-dev`.

## Testing audio locally

The committed manifest grants `--socket=pulseaudio` but no filesystem or
network access, matching #438/#439/#440's scope. To manually verify playback
of your own local files or a real remote stream, use *temporary*,
non-committed `flatpak override` grants and revoke exactly what you added
afterward — never add these to `io.github.thezupzup.linthra.yml`, and never
use `--reset`, which wipes *every* persistent override you have for this app
(including any unrelated ones you already had) rather than just the one this
test added:

```bash
# Local file: point a temporary filesystem grant at a directory with a test
# track, launch, play it from within the app, then revoke that exact grant.
flatpak --user override --filesystem=/path/to/test-music:ro io.github.thezupzup.linthra
flatpak run io.github.thezupzup.linthra
flatpak --user override --nofilesystem=/path/to/test-music io.github.thezupzup.linthra

# Remote HTTP(S) stream: same idea with network instead.
flatpak --user override --share=network io.github.thezupzup.linthra
flatpak run io.github.thezupzup.linthra
flatpak --user override --unshare=network io.github.thezupzup.linthra
```

Confirm each grant is actually gone afterward — check the specific
permission you added rather than assuming empty output, since you may
already have unrelated overrides set for this app:

```bash
flatpak override --user --show io.github.thezupzup.linthra
# Look for the absence of the filesystem/network line you added above;
# any other overrides already there are not this test's concern.
```

should no longer list the `filesystem`/`network` line the test added, though
any other override you already had for this app before testing is expected
to remain. Automated audio smoke coverage is #446's job, not this file's.

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

* **Desktop file** (#434), **AppStream metainfo** (#435), **scalable icon
  packaging** (#436) — `rename-desktop-file`/`rename-icon`/`--filesystem`
  finish-args and the associated install steps are absent on purpose.
* **Provider network access** (#440) — no permanent `--share=network`.
  #433 proved the bundled ffmpeg/libmpv can decode HTTP(S) audio using only a
  *temporary*, non-committed `flatpak override --user --share=network`
  applied and removed for that validation; permanently granting Linthra
  network access for real provider use (Jellyfin/Navidrome-Subsonic/Plex) is
  #440's job, not this manifest's.
* **Filesystem/portal permissions** (#438/#439), **Secret Service** (#441) —
  no `--filesystem=host|home` or `--talk-name=org.freedesktop.secrets`.
  Jellyfin/Subsonic/Plex session restore and secure-storage reads already
  degrade to "not signed in" without them (`docs/linux-desktop.md` §"Secure
  storage"). #433's local-audio validation likewise used a temporary,
  non-committed filesystem override rather than a committed grant.
* **Video codecs, hardware acceleration/hwaccel, subtitle-adjacent tuning
  beyond what libmpv/libass require to build** — Linthra is audio-only; the
  ffmpeg/mpv build stays scoped to the container/codec/protocol support
  Linthra's supported formats and HTTP(S) streaming actually need.
* **CI** (#444), **automated launch/audio smoke tests** (#445/#446), **local-
  library sandbox test** (#447), **Fedora Atomic development documentation**
  (#448) — out of scope here; this file is the minimal "how do I build and
  validate this locally" note #432/#433 asked for.
