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
> working audio, and installs a desktop entry, Linthra's own icon, and AppStream
> metainfo so the app appears in the application menu and in software centres.
> It is not the Flathub submission: normal network access is enabled for
> configured self-hosted servers and provider credentials are kept in the
> desktop keyring through the Secret Service, but there is no filesystem grant
> beyond the folders the user picks through the desktop portal.
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
| Credentials | host Secret Service (encrypted) | same Secret Service, reached with one D-Bus name grant ([Secure credential storage](#secure-credential-storage)) |
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
--socket=wayland  --socket=fallback-x11  --share=ipc  --share=network
--device=dri      --socket=pulseaudio    --talk-name=org.freedesktop.secrets
```

`--share=network` is the minimum Flatpak capability for Linthra's existing
HTTP(S) clients to reach configured Jellyfin, Navidrome/Subsonic, and Plex
endpoints. It enables ordinary network destinations (LAN addresses, hostnames,
valid HTTPS endpoints, and remote/tunnel URLs) but exposes no host files and
grants no D-Bus API. Discovery (mDNS/SSDP/broadcast) is separate and is not
enabled by this change.

`--talk-name=org.freedesktop.secrets` is the whole of the manifest's D-Bus
surface: permission to talk (not own) to the one session-bus name libsecret
connects to for the Secret Service, and nothing else. It is what makes saved
Jellyfin/Navidrome/Plex credentials work inside the sandbox on a host whose
portal has no Secret implementation. See
[Secure credential storage](#secure-credential-storage) for the full
reasoning, what is stored, and how to test it.

The following are **expected**, not bugs, and not worth debugging:

* Unrelated host files are invisible — there is no `--filesystem=` grant
  ([#439](https://github.com/TheZupZup/Linthra/issues/439) is the remaining
  permission audit). Picking a **music folder** does work, and needs no grant:
  the chooser goes through xdg-desktop-portal and the folder comes back through
  the document portal ([#438](https://github.com/TheZupZup/Linthra/issues/438),
  see [`flatpak/README.md`](../flatpak/README.md#local-music-folders)).
* Saved sessions come back signed in
  ([#441](https://github.com/TheZupZup/Linthra/issues/441)), because
  credentials go to the platform keyring like they do natively. What is *not*
  a bug: a locked or missing keyring produces a visible storage error and
  leaves the providers signed out. Linthra never falls back to plaintext, and
  it never writes a credential to a file. See
  [Secure credential storage](#secure-credential-storage).
* Linthra is in the application menu now
  ([#434](https://github.com/TheZupZup/Linthra/issues/434)) with its own icon
  ([#436](https://github.com/TheZupZup/Linthra/issues/436)) and an AppStream
  listing ([#435](https://github.com/TheZupZup/Linthra/issues/435)). `flatpak run`
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

Do not add filesystem or D-Bus permissions to test networking. For a deliberate
one-shot failure test, remove the packaged network share only for that launch:

```bash
flatpak run --unshare=network io.github.thezupzup.linthra
```

Use this rather than `flatpak override`, whose grants persist and can obscure
what the manifest actually provides.

## Secure credential storage

Provider credentials go where they go natively: the platform keyring. The
manifest's one D-Bus grant is what reaches it from inside the sandbox.

```
--talk-name=org.freedesktop.secrets
```

`flutter_secure_storage_linux` is a thin libsecret wrapper, and libsecret picks
its backend at runtime: inside a sandbox it prefers its portal-backed encrypted
file backend when xdg-desktop-portal answers `org.freedesktop.portal.Secret`
(the usual GNOME case, no finish-arg needed), and otherwise falls back to the
Secret Service backend, which connects to the session-bus name above. Granting
that one name is what makes the fallback path work, and it is the narrowest
grant that does: talk, not own, to one exact well-known name.
[`flatpak/README.md`](../flatpak/README.md#secure-credential-storage) has the
full derivation, the table of what each provider stores, and why no wider D-Bus
or filesystem permission was added.

Three things are worth knowing while debugging:

* **Nothing is stored in the clear, ever.** One class,
  `SecureSessionStorage`, is the app's only caller of `flutter_secure_storage`,
  and it has no fallback: a failed write stores nothing anywhere else, and a
  failed read is an error rather than a silent "not signed in".
* **Keyring failures are visible.** Missing, locked and denied are surfaced as
  recoverable sign-in/storage errors on the provider's settings card. The
  message never carries a token, a password, or the platform's own error text.
* **Never print a secret while debugging this.** `secret-tool search` shows
  attributes, which is all you need; `secret-tool lookup` prints the secret
  itself, so do not use it here.

### Manual test: save, read, restart, delete

1. Launch, then sign in to Jellyfin, Navidrome/Subsonic and Plex.
2. Confirm where it landed. On a host using the Secret Service backend (no
   Secret portal, e.g. a KDE session) the plugin's item is labelled
   `io.github.thezupzup.linthra/FlutterSecureStorage` with the attribute
   `account=io.github.thezupzup.linthra.secureStorage`:

   ```bash
   secret-tool search account io.github.thezupzup.linthra.secureStorage
   ```

   It shows in Seahorse ("Passwords and Keys") or KWalletManager too. On a host
   using the portal file backend (the usual GNOME case) `secret-tool search`
   finds nothing and the item is in the app's own encrypted
   `~/.var/app/io.github.thezupzup.linthra/data/keyrings/default.keyring`
   instead. Both are correct; see
   [`flatpak/README.md`](../flatpak/README.md#secure-credential-storage).
3. Quit and relaunch (`flatpak run io.github.thezupzup.linthra`). All three
   providers come back signed in with no re-entry, and a track streams.
4. Sign out of each. The cards return to signed-out and the keyring item is
   gone from `secret-tool search` and from Seahorse/KWalletManager.
5. Nothing in the clear:

   ```bash
   grep -rIl "your-test-token" ~/.var/app/io.github.thezupzup.linthra/ || \
     echo "no plaintext credential"
   ```

   The file backend's `data/keyrings/default.keyring`, on hosts where that is
   the path in use, is ciphertext and does not match.

### Manual test: locked or unavailable service

1. **Locked.** Lock the keyring on the host and sign in:

   ```bash
   secret-tool lock --collection='login'   # GNOME/gnome-keyring
   ```

   KDE: close the wallet in KWalletManager. Expect a visible "Couldn't save
   your … sign-in on this device. Unlock your keyring and try again.", the app
   still usable, and no crash. Unlock, retry, and the sign-in completes.
2. **Unavailable.** Withhold the grant for one launch:

   ```bash
   flatpak run --no-talk-name=org.freedesktop.secrets io.github.thezupzup.linthra
   ```

   On a host using the Secret Service backend: saved sessions report a restore
   error, a new sign-in reports the storage failure, nothing is written
   anywhere else, and a normal relaunch recovers with credentials intact. On a
   host whose portal provides the Secret implementation, libsecret uses the
   portal-backed file backend and this launch behaves normally. That difference
   between GNOME and KDE-style hosts is expected, not a failure.
3. **No keyring at all.** In a bare session with no Secret Service and no
   portal Secret implementation, expect the same recoverable errors as (2),
   with the app fully usable for local music.

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
3. Test a configured LAN server: enter its direct address (for example
   `http://192.168.1.20:8096`) in the Jellyfin, Navidrome/Subsonic, or Plex
   connection UI, sign in, sync, and play a track. Repeat with its hostname.
4. Test a real remote `https://` endpoint (or tunnel URL) the same way. Use a
   valid certificate; never weaken TLS verification for this test.
5. Test recovery: stop the server or launch once with
   `flatpak run --unshare=network io.github.thezupzup.linthra`. A retry should
   use Linthra's existing configured-but-unreachable/offline provider state,
   the app and cached playback should remain usable, and a normal relaunch
   after restoring connectivity should recover.
6. Local music without any grant: launch plainly
   (`flatpak run io.github.thezupzup.linthra`), then Settings ▸ Local music ▸
   *Select a folder*. The system's own folder chooser opens (the portal, run on
   the host), and the folder you pick scans. Check that it really went through
   the portal rather than a filesystem grant:

   ```bash
   flatpak documents io.github.thezupzup.linthra
   flatpak run --command=ls io.github.thezupzup.linthra "$XDG_RUNTIME_DIR/doc"
   ```

   The first lists what the portal exported for the app and the second shows it
   inside the sandbox; the scanned path is under there. Quit and relaunch and
   the same folder still scans. `flatpak document-unexport /path/to/test-music`
   on the host revokes it, after which Linthra says the folder can no longer be
   reached and keeps the library it already indexed instead of emptying it.
7. Credentials: sign in, restart, and sign out as described in
   [Secure credential storage](#secure-credential-storage), including one
   locked-keyring pass. Sessions survive the restart, sign-out clears the
   keyring item, and a locked keyring produces a visible error rather than a
   crash or a silent loss.
8. `flatpak info --show-permissions io.github.thezupzup.linthra` → shows
   `shared=network;ipc;`, no `filesystems=` line, and a `[Session Bus Policy]`
   section whose only entry is `org.freedesktop.secrets=talk`, i.e. still just
   the seven finish-args listed above and no sandbox widened by accident.
