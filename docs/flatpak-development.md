# Flatpak development on Fedora Atomic

How to build, install, run, debug and clean up Linthra's Flatpak on an
immutable Fedora system (**Kinoite**, **Silverblue**, or any other rpm-ostree
variant) without layering anything onto the host image. Everything here also
works on Fedora Workstation and other distributions — see
[Other distributions](#other-distributions) for the one command that differs.

Three docs, three jobs:

* **This page** — the contributor workflow: host tools, build, install, run,
  rebuild, clean, debug.
* [`flatpak/README.md`](../flatpak/README.md) — what the packaging *files* are,
  why the manifest looks the way it does, and what is deliberately not in it
  yet.
* [`linux-desktop.md`](./linux-desktop.md) — the **native** Flutter Linux
  build, which is a different thing with different dependencies. See
  [Native Linux vs Flatpak](#native-linux-vs-flatpak) before mixing the two.

> Flatpak packaging is in progress ([issue #376](https://github.com/TheZupZup/Linthra/issues/376)).
> The committed manifest builds, installs and launches the real app with
> working audio, and installs a desktop entry and Linthra's own icon so the app
> appears properly in the application menu, but it is not the Flathub
> submission: there is no AppStream metadata yet, and no network, filesystem or
> Secret Service access.
> See [What the sandbox allows today](#what-the-sandbox-allows-today).

All commands are relative to the repository. Run them from the repository root
unless a block starts with `cd flatpak`.

## Native Linux vs Flatpak

The two builds share Dart source and nothing else. Do not install host
packages for one expecting them to help the other.

| | Native Flutter Linux | Flatpak |
| --- | --- | --- |
| Where you work on Atomic | inside a `toolbox` | on the **host** |
| Toolchain | clang/cmake/ninja + GTK 3, libsecret, xz headers from your distro | `org.gnome.Sdk//50` + the LLVM SDK extension, inside `flatpak-builder` |
| libmpv | **host** `mpv-libs`/`libmpv` required at runtime | **bundled** in the image; host libmpv is never loaded and is not required |
| Build | `flutter build linux --release` | `flatpak run org.flatpak.Builder …` (below) |
| Run | `./build/linux/x64/release/bundle/linthra` | `flatpak run io.github.thezupzup.linthra` |
| App data | `~/.local/share/` and `~/.config/` | `~/.var/app/io.github.thezupzup.linthra/` |
| Credentials | host Secret Service (encrypted) | not granted yet — sessions degrade to "not signed in" |
| Automated checks | `./scripts/verify_linux.sh` | manual today — see [Smoke testing](#smoke-testing) |

A libmpv-related failure in one says nothing about the other: the Flatpak
carries its own ffmpeg/libplacebo/libass/mpv chain under `/app/lib`, so it runs
on a host with no mpv installed at all, and the native bundle keeps needing the
host library documented in
[linux-desktop.md](./linux-desktop.md#required-packages).

## Host tools

`flatpak` itself is already part of the Fedora Atomic base image. The only
other thing you need is `flatpak-builder`, and it is available **as a Flatpak**
— so nothing gets layered onto the host image and no reboot is involved.

> Do **not** `rpm-ostree install flatpak-builder`. Layering costs a reboot,
> slows every future system update, and buys nothing here: `org.flatpak.Builder`
> is the same tool, sandboxed, and the Flatpak build never needs the native
> Linux toolchain from
> [linux-desktop.md](./linux-desktop.md#required-packages) on the host.

```bash
# A user-level Flathub remote. Fedora's preinstalled remote is filtered on some
# images, so add the full one for your user; both can coexist.
flatpak remote-add --user --if-not-exists \
  flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# flatpak-builder, plus the runtime/SDK/extension the manifest declares.
flatpak install --user flathub \
  org.flatpak.Builder \
  org.gnome.Platform//50 org.gnome.Sdk//50 \
  org.freedesktop.Sdk.Extension.llvm20//25.08
```

Those versions mirror the committed manifest. If a manifest bump ever makes
them stale, read the current values instead of trusting this page:

```bash
grep -E '^(app-id|runtime|runtime-version|sdk):|Extension\.' \
  flatpak/io.github.thezupzup.linthra.yml
```

`org.gnome.Sdk//50` is built on freedesktop-sdk 25.08, which is where the
`//25.08` branch of the LLVM extension comes from. `flatpak-builder` can also
resolve all of that from the manifest itself, which never goes stale:

```bash
cd flatpak
flatpak run org.flatpak.Builder --user --install-deps-from=flathub \
  --install-deps-only flatpak-builder-build io.github.thezupzup.linthra.yml
```

Also expect to spend **several GB** and a long first build: ffmpeg,
libplacebo, libass and mpv are compiled from source, and the Flutter SDK plus
the Linux engine artifacts are downloaded. Both land in the git-ignored
`flatpak/.flatpak-builder/` cache and are reused afterwards.

Typing `flatpak run org.flatpak.Builder` everywhere gets old; an alias in
`~/.bashrc` makes every command below read like the upstream documentation:

```bash
alias flatpak-builder='flatpak run org.flatpak.Builder'
```

### When toolbox is (and isn't) the answer

| Task | Where |
| --- | --- |
| `flutter` / native Linux build / `./scripts/verify_linux.sh` | **toolbox** — that is what [linux-desktop.md](./linux-desktop.md#required-packages) sets up |
| Any `flatpak` or `flatpak-builder` command on this page | **host** — a toolbox has no access to the host's Flatpak installations |
| `./scripts/regenerate_flatpak_sources.sh` | either — it needs `git`, `python3` and network, not Flatpak. Run it on the host, or in a toolbox if your image lacks them |

If your terminal is *itself* inside a Flatpak (e.g. the VS Code Flatpak),
prefix host commands with `flatpak-spawn --host`, e.g.
`flatpak-spawn --host flatpak run org.flatpak.Builder --user …`. That is the
escape hatch for that specific situation, not the normal path.

### Other distributions

On Fedora Workstation, Debian/Ubuntu, Arch and friends, install
`flatpak-builder` from the package manager (Fedora:
`sudo dnf install flatpak flatpak-builder`) and drop the
`flatpak run org.flatpak.Builder` prefix — run plain `flatpak-builder …`
instead. Everything else on this page is identical.

## Build

```bash
cd flatpak
flatpak run org.flatpak.Builder --user --force-clean --repo=repo \
  flatpak-builder-build io.github.thezupzup.linthra.yml
```

* `io.github.thezupzup.linthra.yml` is **generated** — never hand-edit it. See
  [Regenerating the pinned sources](#regenerating-the-pinned-sources).
* `flatpak-builder-build/` and `repo/` are the build tree and the local Flatpak
  repository. Both are git-ignored.
* `--force-clean` empties `flatpak-builder-build/` only. It does **not** touch
  the `flatpak/.flatpak-builder/` download and per-module build cache, so it is
  not a clean build and is safe to keep in the loop.
* The app module builds from your working tree (the manifest's
  `type: dir, path: ..`), so uncommitted changes are picked up.
* The sandboxed build itself has no network. Every source — pub packages, the
  Flutter SDK, the ffmpeg/mpv archives — is fetched from the pinned URLs
  *before* the sandbox is entered, like any other Flatpak module.

## Install locally

User-level, no `sudo`, nothing system-wide:

```bash
cd flatpak
flatpak --user remote-add --if-not-exists --no-gpg-verify linthra-dev repo
flatpak --user install -y linthra-dev io.github.thezupzup.linthra
```

`--no-gpg-verify` is correct here and only here: this is your own unsigned
local build repository, not a distribution channel.

## Run

```bash
flatpak run io.github.thezupzup.linthra
```

That is the packaged app, in its sandbox, with its bundled audio runtime — the
same command a user would run. It is **not** the same as launching the native
bundle (`./build/linux/x64/release/bundle/linthra`), which uses your host's
libraries and your host's data directories. When you are checking a packaging
change, only the `flatpak run` form proves anything.

Launch from a terminal while developing: that is where the app's stdout and
stderr go.

## Rebuild after changing Linthra source

Repeat the build command, then update the installed app:

```bash
cd flatpak
flatpak run org.flatpak.Builder --user --force-clean --repo=repo \
  flatpak-builder-build io.github.thezupzup.linthra.yml
flatpak --user update io.github.thezupzup.linthra
```

Unchanged modules come straight from the cache, so ffmpeg, libplacebo, libass
and mpv are not rebuilt — only the `linthra` module is. A full rebuild is only
needed when the manifest's own modules change, and even then flatpak-builder
decides that for you. **Do not delete `flatpak/.flatpak-builder/` to "get a
clean build"** unless you are specifically debugging the cache: it throws away
the compiled dependency chain and the next build starts from source again.

If an update ever refuses to apply, reinstall over the top:

```bash
flatpak --user install --reinstall -y linthra-dev io.github.thezupzup.linthra
```

## Regenerating the pinned sources

Only needed when `.flutter-version` or `pubspec.lock` changes — not on a normal
source edit:

```bash
./scripts/regenerate_flatpak_sources.sh
```

It regenerates `flatpak/io.github.thezupzup.linthra.yml` and
`flatpak/generated/` from `flatpak/flatpak-flutter.yml`, using a pinned
flatpak-flutter checkout in `.tool/`. Needs network (it pins every dependency
by URL + sha256). Review the diff before committing — see
[`flatpak/README.md`](../flatpak/README.md#regenerating-the-pinned-sources).

## Clean and uninstall

Ordered least to most destructive. Nothing here needs `sudo`.

| Command | Removes | Cost of running it |
| --- | --- | --- |
| `flatpak --user uninstall io.github.thezupzup.linthra` | the installed dev build | Safe. Leaves `~/.var/app/…` data behind |
| `flatpak --user remote-delete linthra-dev` | the local dev remote | Safe |
| `rm -rf flatpak/flatpak-builder-build flatpak/repo` | build tree + local repo | Safe; both are recreated by the next build. Delete the remote too, or it dangles |
| `flatpak --user uninstall --unused` | runtimes nothing installed needs any more | Safe, but re-downloads them next time you build |
| `rm -rf flatpak/.flatpak-builder` | downloaded sources + every cached module build | **Expensive.** The next build recompiles ffmpeg/libplacebo/libass/mpv and re-downloads the Flutter SDK |
| `flatpak --user uninstall --delete-data io.github.thezupzup.linthra` | the app **and** `~/.var/app/io.github.thezupzup.linthra/` | **Destructive.** Wipes the Flatpak install's settings, library database and cache. Your native build's data under `~/.local/share`/`~/.config` is untouched |
| `rm -rf .tool/flatpak-flutter .tool/flatpak-flutter-venv` | the source-regeneration tool checkout | Safe; refetched by `regenerate_flatpak_sources.sh` |

The audio/network testing in
[`flatpak/README.md`](../flatpak/README.md#testing-audio-locally) leaves
nothing to clean up: those permissions are passed to `flatpak run` and last
only for that invocation. That is why it does not use `flatpak override` —
override grants persist, `--nofilesystem=…`/`--unshare=network` add a
*negative* override rather than deleting the grant, and `--reset` wipes
*every* persistent override you have for the app, including unrelated ones you
set yourself.

## Debugging

### Output and logs

```bash
# Run from a terminal: the app's stdout/stderr appear there directly.
flatpak run io.github.thezupzup.linthra

# Flatpak's own sandbox setup, when the app dies before printing anything.
flatpak --verbose run io.github.thezupzup.linthra

# Launched from the desktop rather than a terminal? Its output usually lands
# in the journal.
journalctl --user -b | grep -i linthra
```

### Inside the sandbox

```bash
# One-off command in the app's own runtime.
flatpak run --command=sh io.github.thezupzup.linthra -c 'ls /app/lib/linthra'

# Confirm the bundled audio runtime is really there (host libmpv is never used).
flatpak run --command=sh io.github.thezupzup.linthra -c 'ls /app/lib | grep -i mpv'

# A shell with the SDK's tools instead of the bare platform runtime
# (needs org.gnome.Sdk//50, installed in Host tools above).
flatpak run --devel --command=bash io.github.thezupzup.linthra

# Attach to an already-running instance.
flatpak ps
flatpak enter <instance-id> sh
```

### Permissions

```bash
# What the package itself declares.
flatpak info --show-permissions io.github.thezupzup.linthra

# Full metadata: runtime, commit, SDK, installed size.
flatpak info io.github.thezupzup.linthra
flatpak info -m io.github.thezupzup.linthra

# Persistent local overrides — what *you* have granted on top, not what's
# packaged. Empty if you have stuck to one-shot `flatpak run` permissions.
flatpak override --user --show io.github.thezupzup.linthra
```

### What the sandbox allows today

The committed manifest grants exactly:

```
--socket=wayland  --socket=fallback-x11  --share=ipc
--device=dri      --socket=pulseaudio
```

So these are **expected**, not bugs, and not worth debugging:

* Jellyfin, Navidrome/Subsonic and Plex cannot reach a server — there is no
  `--share=network` yet ([#440](https://github.com/TheZupZup/Linthra/issues/440)).
* No local music folder is visible — no filesystem or portal access yet
  ([#438](https://github.com/TheZupZup/Linthra/issues/438) /
  [#439](https://github.com/TheZupZup/Linthra/issues/439)).
* Saved sessions come back as "not signed in" — no Secret Service access yet
  ([#441](https://github.com/TheZupZup/Linthra/issues/441)). Linthra treats
  that as signed-out and keeps running; it never falls back to plaintext.
* Linthra is in the application menu now
  ([#434](https://github.com/TheZupZup/Linthra/issues/434)) with its own icon
  ([#436](https://github.com/TheZupZup/Linthra/issues/436)) — but with no
  software-centre listing
  ([#435](https://github.com/TheZupZup/Linthra/issues/435)). `flatpak run`
  still works and is what these debugging commands assume.

  To check the icon in an installed build, list what the app exported and what
  it installed:

  ```bash
  ls ~/.local/share/flatpak/exports/share/icons/hicolor/scalable/apps/
  flatpak run --command=ls io.github.thezupzup.linthra \
    /app/share/icons/hicolor/scalable/apps
  ```

  Both should show `io.github.thezupzup.linthra.svg` — the same name the
  desktop entry's `Icon=` looks up. A launcher that still draws the generic
  icon after that is usually caching: log out and back in, or run
  `gtk4-update-icon-cache -f ~/.local/share/flatpak/exports/share/icons/hicolor`.

To exercise those paths anyway, pass the permission to `flatpak run` for a
single launch — it applies to that invocation only, so there is nothing to
revoke and nothing left behind:

```bash
flatpak run --filesystem=/path/to/test-music:ro io.github.thezupzup.linthra
flatpak run --share=network io.github.thezupzup.linthra
```

Use that rather than `flatpak override`, whose grants persist and cannot be
cleanly undone — see
[`flatpak/README.md`](../flatpak/README.md#testing-audio-locally). Never commit
either permission to the manifest.

## Smoke testing

**There is no Flatpak-specific automated smoke test yet, and no Flatpak CI.**
Nothing in `.github/workflows/` builds or launches the Flatpak; validating a
packaging change is manual today. The follow-ups:

| Coverage | Issue |
| --- | --- |
| `flatpak-builder` CI validation/build | [#444](https://github.com/TheZupZup/Linthra/issues/444) |
| Flatpak launch smoke | [#445](https://github.com/TheZupZup/Linthra/issues/445) |
| Flatpak audio playback smoke | [#446](https://github.com/TheZupZup/Linthra/issues/446) |
| Local-library sandbox test | [#447](https://github.com/TheZupZup/Linthra/issues/447) |

What **does** exist is `./scripts/verify_linux.sh`, and it is a *native* check:
it builds and runs `tool/linux_audio_backend_smoke.dart` with the host
toolchain against the host's libmpv, outside any sandbox. It catches app and
native-runner regressions, and says nothing about whether the package is
correct. Run it for source changes; it is not a substitute for building the
Flatpak.

Until #445/#446 land, the manual pass for a packaging change is:

1. Build and install as above (a rebuild is enough; a from-scratch build only
   when you changed the manifest's modules).
2. `flatpak run io.github.thezupzup.linthra` → the window opens and renders.
   A missing bundled library shows up here, as a startup failure before the
   first frame.
3. Play audio with a one-shot permission —
   `flatpak run --filesystem=/path/to/test-music:ro io.github.thezupzup.linthra`,
   or `--share=network` for a stream, per
   [`flatpak/README.md`](../flatpak/README.md#testing-audio-locally). It lasts
   for that launch only.
4. `flatpak info --show-permissions io.github.thezupzup.linthra` → still only
   the five finish-args listed above, i.e. you did not widen the sandbox by
   accident.
