# Flatpak (local build — issue #432)

This is the packaging **foundation**: enough to build Linthra's native Flutter
Linux bundle inside `flatpak-builder`, install it, and launch the real
`io.github.thezupzup.linthra` app to a usable first frame. It is
deliberately not the Flathub submission, not a desktop-integrated package, and
not a full audio-quality Flatpak — see "What's deferred" below and the
comments in `io.github.thezupzup.linthra.yml` itself.

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
* **Provider network access** (#440), **filesystem/portal permissions**
  (#438/#439), **Secret Service** (#441) — no `--share=network`,
  `--filesystem=host|home`, or `--talk-name=org.freedesktop.secrets`.
  Jellyfin/Subsonic/Plex session restore and secure-storage reads already
  degrade to "not signed in" without them (`docs/linux-desktop.md` §"Secure
  storage").
* **Full audio runtime** (#433) — the `ffmpeg`/`libplacebo`/`libass`/`mpv`
  modules here build the *smallest* libmpv that lets Linthra's startup
  bootstrap (which dlopens libmpv before the first frame — see
  `lib/core/services/linux_playback_controller.dart`) succeed instead of
  crashing. `--socket=pulseaudio` is likewise absent: startup only registers
  the backend and never opens an audio device before first frame (verified —
  the installed Flatpak reaches the same first frame without it). Codec
  breadth, hardware acceleration, actual audio output, and tuned mpv options
  are #433's job, not this one's.
* **CI** (#444), **automated launch/audio smoke tests** (#445/#446), **Fedora
  Atomic development documentation** (#448) — out of scope here; this file is
  the minimal "how do I build this locally" note #432 asked for.
