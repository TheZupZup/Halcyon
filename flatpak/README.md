# Flatpak (local build — issues #432, #433, #434)

This is the packaging **foundation**: enough to build Linthra's native Flutter
Linux bundle inside `flatpak-builder`, install it, launch the real
`io.github.thezupzup.linthra` app from the application menu, and get real,
audible local and remote playback through a fully self-contained audio
runtime, with Linthra's own icon on the launcher entry and AppStream metainfo
for a software-centre listing, and let the user point Linthra at a music
folder through the desktop portal without granting any host filesystem
access, and keep provider credentials in the desktop keyring through the
Secret Service. It is deliberately not the Flathub submission:
some sandbox permissions are still deferred; see "What's deferred" below and
the comments in `io.github.thezupzup.linthra.yml` itself.

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

The description covers local playback. The sandbox also permits normal network
connections for user-configured Jellyfin, Navidrome/Subsonic, and Plex servers.

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

## Network access and endpoint validation

The committed manifest grants exactly `--share=network` for networking. Flatpak
otherwise gives an application no network namespace access, so this is the
minimum capability that lets Linthra's existing HTTP clients connect to a
user-configured Jellyfin, Navidrome/Subsonic, or Plex server. It covers ordinary
IPv4/IPv6 sockets: direct LAN addresses, DNS hostnames, HTTPS, and remote or
tunnel endpoints all behave as normal network destinations.

This grant does **not** expose arbitrary host files and adds no D-Bus access
of its own. There is still no `--filesystem=host`, `--filesystem=home`, or
broad D-Bus grant; the manifest's only D-Bus entry is the single Secret Service
name covered in [Secure credential storage](#secure-credential-storage), which
networking neither needs nor affects. It also does not add mDNS, SSDP, or
broadcast discovery behavior: issue #440 covers endpoints the user configured
directly; provider discovery remains separate.

After building and installing the Flatpak, validate a LAN endpoint by entering
its direct address (for example `http://192.168.1.20:8096`) in the matching
provider's connection screen, signing in, syncing, and playing a track. Repeat
with a hostname if the server has one. Validate a remote endpoint by entering a
real `https://` hostname (including a tunnel URL if that is how the server is
normally exposed), then sign in, sync, and play a track. Do not disable TLS or
certificate verification: use the same valid endpoint that native Linthra uses.

Verify recoverable failure behavior without changing the manifest:

1. While connected, note that the provider is available and its tracks play.
2. Stop the test server, disconnect the network, or run a one-shot denial with
   `flatpak run --unshare=network io.github.thezupzup.linthra`.
3. Retry the provider operation. Linthra should report its existing configured
   but unreachable/offline provider state; the app must remain usable and any
   cached track must remain playable.
4. Restore the server/network, launch normally, and retry. The provider should
   become available again through the existing reachability recovery path.

Inspect the installed package rather than relying on the source file:

```bash
flatpak info --show-permissions io.github.thezupzup.linthra
flatpak override --user --show io.github.thezupzup.linthra
```

The first command prints the installed metadata: `shared=network;ipc;`
(alongside the existing windowing, GPU, and audio grants), no `filesystems=`
line at all, and a `[Session Bus Policy]` section whose only entry is
`org.freedesktop.secrets=talk`. The second reveals persistent local overrides
that could invalidate the test.

## Secure credential storage

The committed manifest grants exactly one D-Bus permission for credentials
(#441):

```
--talk-name=org.freedesktop.secrets
```

**Why that name, and why only that one.** `flutter_secure_storage`'s Linux
implementation (`flutter_secure_storage_linux` 1.2.3) has no store of its own:
it calls libsecret's `secret_password_storev_sync` / `secret_password_lookupv_sync`
and nothing else. libsecret decides at runtime how to satisfy those calls
(`secret-backend.c`, `backend_get_impl_type`):

* Inside a sandbox (`/.flatpak-info` present) it first asks
  xdg-desktop-portal for `org.freedesktop.portal.Secret` version 1. If that
  answers, libsecret uses its **file backend**: a gcrypt-encrypted file under
  the app's own data directory whose master key comes from the portal, which in
  turn gets it from the host's keyring. Every Flatpak may talk to the portal,
  so that path needs no finish-arg. This is the usual case on GNOME, where
  gnome-keyring provides the portal implementation.
* If the portal has no Secret implementation (or reports a different version),
  libsecret falls back to its **Secret Service backend** and connects to the
  session-bus name `org.freedesktop.secrets` (`SECRET_SERVICE_BUS_NAME` in
  libsecret's own headers). A Flatpak's D-Bus proxy hides names the manifest
  does not grant, so without this line every credential read and write inside
  the sandbox fails on such a host. KDE/kwallet sessions are the common case.

`--talk-name` is the narrowest grant that covers the second path: permission to
*talk* (not own) to exactly one well-known name on the session bus. Everything
wider was rejected deliberately, and `scripts/check_linux_runner.py` fails the
build if any of it reappears: `--socket=session-bus`, any
`--talk-name=org.freedesktop.*` or `…secrets.*` wildcard,
`--own-name=org.freedesktop.secrets`, and the same name on the system bus. No
filesystem grant was added either; nothing in the credential path opens a file.

**What is stored there.** One entry per provider, each the JSON of a session
object, written by the three secure stores in
`../lib/data/repositories/`:

| Key | Provider | Contents |
| --- | --- | --- |
| `jellyfin_session_v1` | Jellyfin | server URL, user id/name, access token, device id |
| `subsonic_session_v1` | Navidrome/Subsonic | server URL, username, salt, derived token |
| `plex_session_v1` | Plex | server URL, machine identifier, token, selected library keys |

Passwords are never stored: Jellyfin exchanges one for an access token,
Subsonic derives a salt+token pair and discards it, Plex is token-based from
the start. Everything else (library rows, preferences, playback state) stays in
SQLite and preferences and holds no secret.

**No plaintext fallback.** All three stores go through one class,
`SecureSessionStorage`, which is the only thing in the app that touches
`flutter_secure_storage`. It has no alternative path: if the platform store
cannot take a value, the write fails and nothing is written to preferences, the
database, the cache, or a file, and a read that fails is an error rather than a
silent "no session". Failures are translated into a typed
`SecureStorageException` carrying only an operation and a cause (unavailable,
locked, denied, unknown), never the platform error text, the key, or the
value, so a keyring problem cannot leak a token into a log, a diagnostics
report, or a crash report. Jellyfin, Navidrome/Subsonic and Plex each turn that
into a visible, recoverable message: "Couldn't save your … sign-in on this
device. Unlock your keyring and try again." A session that could not be saved
is not adopted, because it would look signed in until the next launch and then
be gone.

`test/data/repositories/secure_session_storage_test.dart` drives the real
plugin channel (`plugins.it_nomads.com/flutter_secure_storage`) with the exact
`PlatformException`s the Linux plugin raises, and covers save, read after a
restart, delete, the missing/locked/denied service, and the absence of any
fallback write.

### Testing it in the sandbox

Save, read after restart, delete:

1. Build, install and launch (above). Sign in to Jellyfin, Navidrome/Subsonic
   and Plex.
2. Confirm on the host where the credential landed. Which of libsecret's two
   backends is in use decides what you will see, and both are correct:

   * **Secret Service backend** (no Secret portal on the host, e.g. a KDE
     session): the plugin's item is labelled
     `io.github.thezupzup.linthra/FlutterSecureStorage` with the attribute
     `account=io.github.thezupzup.linthra.secureStorage`, and shows up in the
     host keyring:

     ```bash
     secret-tool search account io.github.thezupzup.linthra.secureStorage
     ```

     GNOME users see the same item in Seahorse ("Passwords and Keys"), KDE
     users in KWalletManager.
   * **Portal file backend** (the usual GNOME case): `secret-tool search` finds
     nothing, because the item is in the app's own encrypted
     `~/.var/app/io.github.thezupzup.linthra/data/keyrings/default.keyring`,
     whose key comes from the portal. That file is ciphertext; step 5 checks it
     holds no readable credential.

   Either way, do not print the secret: `secret-tool search` shows attributes,
   which is what you are checking, while `secret-tool lookup` would print the
   value itself.
3. Quit and relaunch: `flatpak run io.github.thezupzup.linthra`. All three
   providers should come back signed in, without re-entering anything, and a
   track should stream.
4. Sign out of each provider. The card returns to the signed-out state and the
   keyring entry is gone (`secret-tool search …` no longer lists it, and the
   entry disappears from Seahorse/KWalletManager).
5. Check that nothing was written in the clear. There must be no credential in
   the app's own data:

   ```bash
   grep -rIl "your-test-token" ~/.var/app/io.github.thezupzup.linthra/ || \
     echo "no plaintext credential"
   ```

   (The encrypted file backend's `data/keyrings/default.keyring`, when that
   path is the one in use, is ciphertext and will not match.)

Locked or unavailable service:

1. **Locked.** Lock the keyring on the host (`gnome-keyring` users:
   `secret-tool lock --collection='login'`; KDE users: close the wallet in
   KWalletManager), then launch Linthra and sign in. Expect a visible
   "Couldn't save your … sign-in on this device. Unlock your keyring and try
   again.", the app still usable, and no crash. Unlock and retry: the sign-in
   completes.
2. **Unavailable.** Launch once with the grant withheld:

   ```bash
   flatpak run --no-talk-name=org.freedesktop.secrets io.github.thezupzup.linthra
   ```

   On a host that was using the Secret Service backend, saved sessions come
   back as a restore error ("Couldn't restore your saved … sign-in from this
   device."), signing in reports the storage failure, and nothing is written
   anywhere else. A normal `flatpak run` afterwards recovers with the
   credentials intact. On a host whose portal provides the Secret
   implementation, libsecret uses the portal-backed file backend and this
   launch behaves normally, which is the expected difference between the two
   paths, not a failed test.

Use one-shot `flatpak run` flags rather than `flatpak override`: overrides
persist and then hide what the manifest actually grants.

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

* **The remaining filesystem-permission audit** (#439): still no
  `--filesystem=host|home`. Picking a music folder does not need a filesystem
  grant at all (see [Local music folders](#local-music-folders)), and neither
  does credential storage (see
  [Secure credential storage](#secure-credential-storage)).
* **Video codecs, hardware acceleration/hwaccel, subtitle-adjacent tuning
  beyond what libmpv/libass require to build** — Linthra is audio-only; the
  ffmpeg/mpv build stays scoped to the container/codec/protocol support
  Linthra's supported formats and HTTP(S) streaming actually need.
* **CI** (#444), **automated launch/audio smoke tests** (#445/#446), **local-
  library sandbox test** (#447) — out of scope here; this file is the minimal
  "how do I build and validate this locally" note #432/#433 asked for, and
  [docs/flatpak-development.md](../docs/flatpak-development.md) is the
  contributor workflow around it.
