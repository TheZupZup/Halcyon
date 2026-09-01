# Flatpak (local build — issues #432, #433, #434)

This is the packaging **foundation**: enough to build Linthra's native Flutter
Linux bundle inside `flatpak-builder`, install it, launch the real
`io.github.thezupzup.linthra` app from the application menu, and get real,
audible local and remote playback through a fully self-contained audio
runtime, with Linthra's own icon on the launcher entry and AppStream metainfo
for a software-centre listing, and let the user point Linthra at a music
folder through the desktop portal without granting any host filesystem
access. It is deliberately not the Flathub submission —
the sandbox permissions are still open; see "What's deferred" below and the
comments in `io.github.thezupzup.linthra.yml` itself.

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

## Application icon

`Icon=io.github.thezupzup.linthra` in that entry is an icon-theme **name**, not
a path. It resolves because the `linthra` module installs a file of exactly that
name into the icon theme:

```
install -Dm644 tool/branding/linthra_icon.svg \
  /app/share/icons/hicolor/scalable/apps/io.github.thezupzup.linthra.svg
```

Three decisions worth stating:

* **The source is Linthra's canonical vector mark, installed as-is.**
  `tool/branding/linthra_icon.svg` is the design
  `tool/branding/generate_icons.py` rasterises into the Android launcher
  mipmaps and the store graphics — same squircle, same four bars, same
  violet→orange gradient. Nothing here redraws or re-exports it, so there is no
  packaging-only copy that can drift from the brand, exactly as with the
  desktop entry above. Android's icon pipeline is untouched by this.
* **One scalable SVG and no rasters.** A vector is sharp at every launcher size
  and every HiDPI scale factor by construction, so a set of PNG fallbacks could
  only be larger and worse. `hicolor` is the theme every icon theme inherits
  from, and `scalable/apps` is where an application's own icon belongs.
* **No `rename-icon`.** flatpak-builder exports `/app/share/icons/hicolor/**`
  by the same rule it exports desktop files — the basename must start with the
  app id — and this basename *is* the app id.

`scripts/check_linux_runner.py` covers this too, offline and with no extra
packages to install: it holds the installed basename to the entry's `Icon=`,
requires **both** manifests to install it, and checks the SVG itself — that it
is well-formed, that it carries a `viewBox` (a file in `scalable/` that cannot
scale is resampled by every launcher), and that it has no absolute host path
and no reference to anything it does not carry (an external image, stylesheet
or font would render differently, or not at all, inside the sandbox).

## AppStream metainfo

`../linux/packaging/io.github.thezupzup.linthra.metainfo.xml` is the software-
centre listing (#435). The `linthra` module installs it:

```
install -Dm644 linux/packaging/io.github.thezupzup.linthra.metainfo.xml \
  /app/share/metainfo/io.github.thezupzup.linthra.metainfo.xml
```

`/app/share/metainfo` is exported the same way as the desktop entry — the
filename is the app id, so there is no `rename-appdata-file`. `<launchable
type="desktop-id">` and `<icon type="stock">` point at the desktop entry and
icon already installed under that id. Screenshots are omitted until there are
Linux captures; Android shots would misrepresent the desktop window.

The description only covers local playback. Server streaming (Jellyfin /
Navidrome / Subsonic / Plex) stays out until the Flatpak has network
permission (#440).

## Files here

| File | What it is |
| --- | --- |
| `flatpak-flutter.yml` | Hand-authored input. Never built directly. |
| `../linux/packaging/io.github.thezupzup.linthra.desktop` | Hand-authored, and not Flatpak-only: the installed desktop entry (#434), which this manifest copies into `/app/share/applications/` for flatpak-builder to export. It lives beside the rest of the Linux packaging inputs rather than here so a future native package installs the same file. |
| `../linux/packaging/io.github.thezupzup.linthra.metainfo.xml` | Hand-authored AppStream listing (#435). Installed to `/app/share/metainfo/` so software centres can describe Linthra. Lives next to the desktop entry for the same reason. |
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

## Local music folders

Choosing a music folder (#438) needs **no** `finish-args` entry, and adding
`--filesystem=host` or `--filesystem=home` would be the wrong fix for it.

Linthra's Linux runner opens the folder chooser with GTK's
`GtkFileChooserNative` (`../linux/runner/folder_picker_channel.cc`). GTK checks
for `/.flatpak-info` itself and, inside a sandbox, routes that chooser to the
**xdg-desktop-portal** `FileChooser` interface instead of drawing it in
process. Every Flatpak may talk to the portal, so nothing has to be granted:

* the chooser runs on the *host*, so it can browse the user's real home
  directory while the sandbox still cannot;
* only the folder the user actually picked comes back, exported through the
  **document portal** (mounted for every Flatpak at `$XDG_RUNTIME_DIR/doc`) as
  a path under Linthra's own document store;
* that path is a real directory the `dart:io` scan walks unchanged, so the
  scanner needs no Flatpak-specific branch and no hardcoded sandbox path;
* the export persists, so the folder is still readable after a restart, and
  revoking it (or unplugging the drive) makes the path stop resolving rather
  than silently returning nothing — Linthra reports that as "select the folder
  again" and leaves the indexed library alone.

What the Flatpak deliberately does **not** get is everything else: unrelated
host files stay invisible, which is the whole point of picking this route over
a filesystem grant.

`file_picker`, which the app uses on other desktops, cannot do this — its Linux
implementation shells out to `zenity`/`qarma`/`kdialog`, and the sandbox
contains none of them. It stays as the fallback for a build with no runner
channel; native (non-Flatpak) Linux gets the ordinary in-process GTK dialog
from the same code path.

`scripts/check_linux_runner.py` holds the runner's channel name to the Dart
side's, so the two cannot drift into a silent fallback.

## What's deferred

Not in this manifest — each has its own issue:

* **Provider network access** (#440) — no permanent `--share=network`.
  #433 proved the bundled ffmpeg/libmpv can decode HTTP(S) audio using only a
  temporary, non-committed grant for that validation (see
  [Testing audio locally](#testing-audio-locally)); permanently granting
  Linthra network access for real provider use
  (Jellyfin/Navidrome-Subsonic/Plex) is #440's job, not this manifest's.
* **The remaining filesystem-permission audit** (#439) and **Secret Service**
  (#441) — no `--filesystem=host|home` or
  `--talk-name=org.freedesktop.secrets`. Jellyfin/Subsonic/Plex session restore
  and secure-storage reads already degrade to "not signed in" without them
  (`docs/linux-desktop.md` §"Secure storage"). Picking a music folder no longer
  needs a filesystem grant at all — see [Local music folders](#local-music-folders).
* **Video codecs, hardware acceleration/hwaccel, subtitle-adjacent tuning
  beyond what libmpv/libass require to build** — Linthra is audio-only; the
  ffmpeg/mpv build stays scoped to the container/codec/protocol support
  Linthra's supported formats and HTTP(S) streaming actually need.
* **CI** (#444), **automated launch/audio smoke tests** (#445/#446), **local-
  library sandbox test** (#447) — out of scope here; this file is the minimal
  "how do I build and validate this locally" note #432/#433 asked for, and
  [docs/flatpak-development.md](../docs/flatpak-development.md) is the
  contributor workflow around it.
