# Linux desktop

Linthra has a native Flutter Linux target. This page is how to build and run it,
what works today, and what deliberately does not yet.

> **Linux is not production-ready.** This is the second milestone of
> [issue #376](https://github.com/TheZupZup/Linthra/issues/376): the app
> compiles, launches, renders in a real desktop window, and plays local and
> server audio. Desktop media controls and packaging are later milestones.
> Android is unaffected and remains the platform Linthra actually ships on.

## What exists after this milestone

* `linux/` is committed, like `android/`. No `flutter create` step.
* `flutter build linux` produces a runnable bundle.
* The window carries Linthra's real identity: application id
  `io.github.thezupzup.linthra` (the same reverse-DNS id as the Android build),
  window title `Linthra`, a 1180×780 default size and a 420×600 minimum.
* Every shared layer is the same code Android runs: domain models, providers,
  repositories, routing, theming, the local scanner, and the Jellyfin /
  Navidrome / Subsonic / Plex integrations.
* Server credentials persist in **encrypted** storage on Linux, through the
  desktop Secret Service (see [Secure storage](#secure-storage)).
* CI builds the Linux target on every PR
  ([`linux-desktop-build.yml`](../.github/workflows/linux-desktop-build.yml)).
  For an official release, that same workflow is separately dispatched to
  build at the exact release tag, package the bundle into a `.tar.gz`, and
  attach it to the GitHub Release — see [Release tarball](#release-tarball)
  below and
  [docs/release-process.md §4a](./release-process.md#4a-linux-release-tarball-dispatched-alongside-the-android-build).

## Required packages

The Flutter Linux toolchain plus the native libraries Linthra's plugins need,
for the **native** build described on this page.

> Building the **Flatpak** instead? None of these packages are needed for it —
> it brings its own toolchain and bundles its own libmpv. See
> [flatpak-development.md](./flatpak-development.md).

### Fedora / Fedora Kinoite

```bash
sudo dnf install \
  clang cmake ninja-build pkgconf-pkg-config \
  gtk3-devel xz-devel libsecret-devel mpv-libs mpv-devel
```

On **Kinoite** (and any rpm-ostree system) do development work inside a
toolbox rather than layering packages onto the host image:

```bash
toolbox create linthra
toolbox enter linthra
# then run the dnf command above inside the toolbox
```

### Debian / Ubuntu

```bash
sudo apt install \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev libsecret-1-dev libmpv-dev
```

### Arch

```bash
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 xz libsecret mpv
```

### What each one is for

| Package | Needed by |
| --- | --- |
| `clang`, `cmake`, `ninja`, `pkg-config` | the Flutter Linux build itself |
| GTK 3 development headers | the Flutter Linux embedder |
| `liblzma` / `xz` development headers | Flutter tool prerequisite |
| **libsecret development headers** | `flutter_secure_storage_linux` — encrypted credential storage. Not optional: without it the plugin does not build, and Linthra never falls back to plaintext credentials. |
| **libmpv** | `just_audio_media_kit` / `media_kit` — local and HTTP(S) audio decoding, seeking, timing, and output through PulseAudio or PipeWire. Ubuntu's `libmpv-dev`, Fedora's `mpv-libs` + `mpv-devel`, and Arch's `mpv` provide it. |

At **runtime** the app additionally needs libmpv and wants a Secret Service provider
(`gnome-keyring` on GNOME, `kwallet` with its Secret Service interface on KDE).
Both are present on a standard Fedora Workstation or Kinoite install.

## Building and running from source

```bash
./scripts/setup_flutter.sh                       # the pinned Flutter (no sudo)
export PATH="$PWD/.tool/flutter/bin:$PATH"

flutter config --enable-linux-desktop
flutter pub get --enforce-lockfile
flutter run -d linux                             # or: flutter build linux --release
```

A release build lands in `build/linux/x64/release/bundle/`; run
`./build/linux/x64/release/bundle/linthra`.

To run the same checks CI runs:

```bash
./scripts/verify_linux.sh
```

That does `pub get --enforce-lockfile`, `dart format --set-exit-if-changed`,
`flutter analyze`, `flutter test`, the runner configuration check, the desktop
entry check (`desktop-file-validate` on
`linux/packaging/io.github.thezupzup.linthra.desktop`, skipped with a note if
`desktop-file-utils` is not installed), the same
native audio lifecycle smoke CI runs (builds and runs
`tool/linux_audio_backend_smoke.dart`), and `flutter build linux --release`.
It skips the smoke test and the build if the native packages above are
missing — including the libmpv *runtime* library, checked the same way
media_kit loads it, since a Linux build succeeds without libmpv but can't play
anything — and says which ones. `scripts/verify_android.sh` is unchanged and
still the Android twin.

### Building without a network

`sqlite3_flutter_libs` compiles SQLite into the app so the Drift catalog runs on
the same engine and the same compile flags Android uses. On Linux its CMake
downloads the SQLite amalgamation from `sqlite.org` while *configuring* the
build. That is fine on a normal machine and impossible in a sandboxed or
air-gapped build — including `flatpak-builder`, which builds with networking
disabled.

`linux/CMakeLists.txt` therefore honours `LINTHRA_SQLITE3_SOURCE_DIR`: point it
at an already-unpacked amalgamation (a directory containing `sqlite3.c`) and
nothing is downloaded.

```bash
LINTHRA_SQLITE3_SOURCE_DIR=/path/to/sqlite-autoconf-XXXXXXX \
  flutter build linux --release
```

It works through CMake's own `FETCHCONTENT_SOURCE_DIR_<NAME>` hook, so the
plugin is neither patched nor vendored — leave the variable unset and the build
is byte-for-byte the upstream one. `scripts/check_linux_runner.py` fails if the
seam is ever removed, because losing it breaks nothing on a machine with a
network and would only surface at packaging time.

## Secure storage

`flutter_secure_storage` publishes a real Linux implementation
(`flutter_secure_storage_linux`), and Linthra uses it unchanged. On Linux it
stores through **libsecret**, i.e. the freedesktop Secret Service — the same
place your other desktop apps keep credentials — instead of Android's Keystore.
Jellyfin, Subsonic/Navidrome and Plex sessions are encrypted at rest on Linux
exactly as they are on Android.

What is stored: one entry per provider (`jellyfin_session_v1`,
`subsonic_session_v1`, `plex_session_v1`), each the JSON of a session object.
Passwords are never among them: Jellyfin exchanges one for an access token,
Subsonic derives a salt+token pair and discards it, Plex is token-based from
the start.

Three runtime facts worth knowing:

* A Secret Service provider must be running and **unlocked**. On a normal
  desktop session the login keyring is unlocked at login and nothing is asked
  of you. On a bare window manager with no keyring daemon, or with the keyring
  locked, reads and writes fail.
* A failure is reported, not swallowed. The three provider stores go through
  one wrapper, `SecureSessionStorage`
  (`lib/data/repositories/secure_session_storage.dart`), which turns a platform
  failure into a typed `SecureStorageException` (unavailable, locked, denied,
  unknown) carrying nothing from the platform error, so a token cannot reach a
  log or a diagnostics report through it. The provider settings cards turn that
  into a recoverable message ("Couldn't save your Jellyfin sign-in on this
  device. Unlock your keyring and try again."), the app stays usable, and a
  session that could not be saved is not adopted: it would look signed in until
  the next launch and then be gone.
* Credential storage was not weakened to make Linux work, and Linthra has no
  plaintext fallback on any platform. A failed write stores nothing in
  preferences, the database, the cache, or any file Linthra writes.

In the **Flatpak** the same plugin reaches secure storage differently, and
without any D-Bus permission: libsecret detects the sandbox and, when the
desktop provides the xdg-desktop-portal Secret portal (GNOME via gnome-keyring,
KDE Plasma 6 via KWallet's `ksecretd`), keeps its own gcrypt-encrypted store
under the app's data directory with the master secret handed over by that
portal. Encrypted at rest either way, and libsecret's storage in both cases,
just not the shared keyring collection this page's native build uses. See
[flatpak-development.md](./flatpak-development.md#secure-credential-storage).

## Audio playback

Linux uses `just_audio_media_kit`, which implements the same `just_audio`
platform contract as Android's engine but delegates decoding and output to
media_kit/libmpv. This was chosen over a second, parallel playback stack because
Linthra's existing `JustAudioPlaybackController` already owns the difficult
parts: ordered playable candidates, offline-to-stream fallback, queue mutation,
shuffle/repeat, completion, retries, position/duration state, ReplayGain, and
safe errors. `LinuxPlaybackController` only registers the Linux implementation;
Android still constructs `JustAudioPlaybackController` and therefore remains on
ExoPlayer, `audio_service`, and its existing audio-focus behavior.

The same resolved URI path handles regular filesystem files and direct or
transcoded Jellyfin, Navidrome/Subsonic, and supported Plex HTTP(S) URLs. No
source-specific player exists and credentials remain in the existing resolver.

### Vendored `just_audio_media_kit`

`just_audio_media_kit` is vendored under `third_party/just_audio_media_kit`
(and wired in through a `dependency_overrides` path entry) rather than pulled
from pub.dev. The local delta is two hunks that add
`JustAudioMediaKit.mpvProperties`, an optional map of libmpv properties applied
at player creation, so the headless CI smoke target can force `ao=alsa` where
there is no PipeWire/Pulse device. Production sets nothing, so the libmpv calls
are identical to the published package's.

`third_party/just_audio_media_kit/PATCHES.md` records the exact upstream
version and archive digest, what is and isn't vendored, and how to refresh it.
`scripts/check_vendored_packages.sh` (run by CI and by
`scripts/verify_linux.sh`) analyzes the package from its own directory with the
pinned toolchain and proves — offline — that the tree is still upstream plus
that recorded patch.

libmpv provides broad codec/container support and PulseAudio/PipeWire output.
It is a native runtime dependency, not a binary downloaded when Linthra starts.
The Flatpak manifest therefore builds libmpv as a declared module and bundles
it, so the packaged app needs no host libmpv at all
([flatpak-development.md](./flatpak-development.md)).
`media_kit_libs_linux` normally offers an optional build-time mimalloc download;
Linthra explicitly disables it in `linux/CMakeLists.txt`, so this backend adds no
undeclared network access to an isolated `flatpak-builder` build.

## Remaining Linux limitations

| Area | State | Why |
| --- | --- | --- |
| **Audio playback** | Supported | media_kit/libmpv through `LinuxPlaybackController`; local files and resolved Jellyfin, Navidrome/Subsonic, and Plex HTTP(S) streams share one backend. |
| **Suspend / resume** | Supported (app side); real device/sink timing varies | Lifecycle `paused`→`resumed` arms a bounded Linux-only reload of an actively playing track after a short backoff ([issue #466](https://github.com/TheZupZup/Linthra/issues/466)). See [Suspend / resume (manual matrix)](#suspend--resume-manual-matrix). |
| **Light/Dark/System theme** | Supported (app side); the native brightness bridge itself is Flutter's, not independently verified here | Settings → Appearance's System/Light/Dark choice ([issue #459](https://github.com/TheZupZup/Linthra/issues/459)) is the same shared `ThemeModePreference`/`ThemeModeController` Android uses, mapped onto `MaterialApp`'s own `themeMode` — no `gsettings`/D-Bus/GNOME/KDE-specific code in Linthra itself, and no separate Linux theme path (`test/app/theme_mode_test.dart` proves that). *Supplying* System's brightness on Linux is Flutter's GTK embedder (via the XDG desktop portal or a GNOME GSettings fallback); that native bridge is outside Linthra's code and isn't exercised by `flutter test`, which runs on the Dart VM and injects brightness straight into Flutter's test `PlatformDispatcher`. Reproducing the real bridge deterministically in CI would need a running portal daemon or GNOME schemas — exactly the DE-specific setup this app avoids adding — so it stays untested here and is a known gap, not a claimed guarantee. |
| Media session / MPRIS | Supported | `PlatformMediaSessionBinding` routes Linux to `MprisMediaSessionBinding`, which exports `/org/mpris/MediaPlayer2` and owns `org.mpris.MediaPlayer2.linthra` ([issue #397](https://github.com/TheZupZup/Linthra/issues/397)). Shells get PlaybackStatus, Metadata, Position and the transport methods; media keys work through the same interface. `audio_service` is still never initialised on Linux — it stays the Android delegate. A machine with no session bus simply gets no desktop controls. |
| Android Auto | Android-only, by design | It is an Android platform integration, not a Linthra feature. |
| Media notification + `POST_NOTIFICATIONS` | Android-only, by design | There is no equivalent gate on Linux; desktop controls come from MPRIS instead. Standalone track-change notifications are [issue #400](https://github.com/TheZupZup/Linthra/issues/400). |
| Android audio focus | Android-only, by design | `JustAudioPlaybackController` already scopes its focus handling to Android/iOS. |
| SAF (`content://` folders) | Android-only, by design | Linux picks a real filesystem path. The scanner's desktop path is the one that runs. |
| Folder chooser | Supported | Linthra's own runner channel (`linux/runner/folder_picker_channel.cc`) opens `GtkFileChooserNative`: the ordinary GTK dialog natively, and the xdg-desktop-portal chooser inside the Flatpak, where `file_picker`'s `zenity`/`kdialog` do not exist ([issue #438](https://github.com/TheZupZup/Linthra/issues/438)). `scripts/check_linux_runner.py` holds the runner's channel name to the Dart side's. |
| Lost folder access | Supported | A selected folder that stops resolving (unmounted drive, deleted folder, revoked portal document) is reported as a recoverable "select it again" state on the Local music card, and the indexed catalog is left alone rather than replaced with an empty scan. |
| Local tag/artwork reading | Unsupported | `UnsupportedLocalMetadataReader` on every filesystem scan, Android included. Tracks fall back to filename/folder derivation. A real desktop reader is later work in #376. |
| Chromecast | Android/iOS only | Already gated in `cast_providers.dart`; Linux keeps the honest "cast unavailable" service. |
| Share sheet, launcher-icon switching | Android-only, by design | No desktop equivalent; the UI simply omits them. |
| Desktop layout, keyboard shortcuts | Not started | The existing layout renders in the window and is usable for development. The desktop UX pass is later work in #376. |

Nothing in that table is faked. Each one is an explicit implementation behind an
existing interface, so it is visible in the code and covered by tests — with
one caveat: the Light/Dark/System theme row's *app-side* wiring is covered, but
the native GTK/portal brightness bridge underneath it is Flutter's own
responsibility and is not, and cannot easily be, exercised by `flutter test`;
see that row for why.

## How platform selection works

Linthra picks platform implementations behind interfaces, never with a
`Platform.isLinux` check inside a widget. Two pieces make that testable:

* **`HostPlatform`** (`lib/core/platform/host_platform.dart`) — the platform as
  a value rather than a `dart:io` read. Production uses `HostPlatform.current`;
  tests pass `HostPlatform.android` or `HostPlatform.linux`, so *both* branches
  of every seam can be asserted from one machine.
* **`hostPlatformProvider`** (`lib/data/repositories/host_platform_provider.dart`)
  — the same value for provider-level selection, overridable in a
  `ProviderContainer`.

The seams that branch on it:

| Seam | Android | Linux |
| --- | --- | --- |
| `PlatformMediaSessionBinding` | `audio_service` session | inert, never touches `audio_service` |
| `localPlaybackControllerProvider` | `JustAudioPlaybackController` (ExoPlayer) | `LinuxPlaybackController` (media_kit/libmpv) |
| `PlatformFolderPickerService` | SAF tree picker | runner GTK chooser (`GtkFileChooserNative`), which GTK routes to xdg-desktop-portal inside the Flatpak; `file_picker` only as a fallback |
| `PlatformAudioFileScanner` | SAF content-resolver walk | `dart:io` walk |
| `safDocumentListerProvider` | native content resolver | unsupported |
| `safPermissionProbeProvider` | native grant probe | unsupported |
| `localLyricsReaderProvider` | SAF sibling document | filesystem sibling |
| `PlatformShareService` | `ACTION_SEND` | no-op |
| `PlatformLauncherIconService` | `<activity-alias>` toggle | no-op |

Adding a platform-specific behaviour means adding a row here, not a check in a
widget.

## How the desktop layout adapts

Presentation is the one thing that does *not* branch on `HostPlatform`. Layout
adapts on the **width a widget is actually given**, so the same window is laid
out the same way wherever it runs, and a Linux window narrowed to 600 px gets
the phone layout rather than a cramped desktop one.

`lib/shared/layout/adaptive_layout.dart` holds the whole vocabulary:

| Piece | What it does |
| --- | --- |
| `WindowSizeClass` | `compact` (< 600), `medium` (< 1000), `expanded` (< 1600), `large` — Material's window size classes, with the phone thresholds left where Android already behaves |
| `windowSizeClassFor(width)` | the pure breakpoint function, so the thresholds are unit-testable |
| `AdaptiveLayoutBuilder` | resolves the class from the widget's own `BoxConstraints` — inside the desktop shell a screen is narrower than the window by the navigation rail, and a pane is narrower still |
| `AdaptiveContentWidth` | caps and centres a single column (`maxContentWidth`, or `maxFormWidth` for settings), a no-op below the cap |

What it buys, per surface:

* **Album grid** — cards stay between 200 and 260 logical px and the grid adds
  columns instead of inflating covers: 5 across at 1280, 7 at 1920, 10 at 2560,
  where before every desktop width got the same six mobile-sized cards.
* **Artists** — the same rows flow into 2–5 columns rather than one row per
  monitor width.
* **Songs, playlists, downloads, settings** — one column, capped and centred,
  so a title and its trailing action never end up a screen apart.
* **Album and artist detail** — at `expanded` and up, a persistent left pane
  (cover/portrait, counts, Play and Shuffle) beside the scrolling track list.
  Selection mode falls back to the single column.
* **Now Playing** — at `expanded` and up, the cover sits beside the metadata
  and transport, and lyrics open *next to* the cover instead of replacing it.
  Same `_showLyrics` state and same playback state as the stacked layout.

Both breakpoints in the app agree by construction: the shell swaps its bottom
bar for the navigation rail at 900 px of window, and a feature screen inside it
only reaches `expanded` once the space left over is 1000 px wide.

Tests: `test/shared/layout/adaptive_layout_test.dart`,
`test/features/library/album_grid_test.dart`,
`test/features/library/artist_grid_test.dart`,
`test/features/library/detail_desktop_layout_test.dart`,
`test/features/player/player_desktop_layout_test.dart` — each covers the phone
width alongside 1280, 1920, 2560 and ultrawide, so a change that only looks
right on one monitor fails.

## Guardrails

* `scripts/check_linux_runner.py` — the committed runner still matches the app's
  identity (`APPLICATION_ID` = Android's `applicationId`, `BINARY_NAME` =
  the package name, window title = `AppInfo.name`), it still makes the four
  desktop-identity calls below in the places where GTK honours them, the window
  metrics are sane, the offline SQLite seam is wired, and nothing under `linux/`
  hardcodes an absolute host path.
  Tests: `test/tooling/check_linux_runner_test.py`.
* `scripts/flatpak_launch_smoke.sh` — launches the packaged Flatpak twice and
  reads `WM_CLASS` and `_NET_WM_ICON` back off the real window each time, so a
  window that stops answering to the application id fails CI.
* `test/app/linux_startup_test.dart` — every provider `main()` reads before the
  first frame constructs on a Linux host, with no Android MethodChannel
  binding among them.
* `test/features/library/library_platform_bindings_test.dart` and
  `test/features/player/playback_platform_binding_test.dart` — each seam picks
  the Android implementation on Android and the desktop one on Linux.

`linux/CMakeLists.txt` and `linux/runner/my_application.cc` are listed as
`unmanaged_files` in `.metadata`, so `flutter migrate` leaves Linthra's edits
alone. If someone re-runs `flutter create --platforms=linux .` anyway, the
checker above is what catches the reverted title and the lost SQLite seam.

## Desktop identity

Everything Linthra installs on Linux is named `io.github.thezupzup.linthra`: the
desktop entry, the icon, the AppStream component, the Flatpak. The *running
window* only joins them if the runner says so, and each display server reads a
different thing, so `linux/runner/my_application.cc` sets all of them from
`APPLICATION_ID` (never from a literal):

| Call | Where | What reads it |
| --- | --- | --- |
| `g_set_prgname(APPLICATION_ID)` | `my_application_new()`, before `gtk_init()` | GTK 3 sends this as the Wayland `xdg_toplevel` app id, and as the instance half of X11's `WM_CLASS` |
| `gdk_set_program_class(APPLICATION_ID)` | `my_application_startup()`, **after** the chain-up | the class half of `WM_CLASS`. GDK's default is the program name with its first letter upper-cased, which is not the app id |
| `gtk_window_set_default_icon_name(APPLICATION_ID)` | same | GTK attaches the themed icon as `_NET_WM_ICON`; without it the window has no icon of its own |
| `g_set_application_name(AppInfo.name)` | same | `g_get_application_name()`, which GTK and portals show to the user |

The two in `my_application_startup()` have to run after the chain-up to
`GtkApplication::startup`: that is what calls `gtk_init()`, and `gtk_init()`
resets GDK's program class unconditionally. Set earlier, they compile, run, and
are thrown away.

`linux/packaging/io.github.thezupzup.linthra.desktop` declares the same X11 pair
as `StartupWMClass=`, so a shell matches the window to the entry exactly rather
than falling back to lower-casing whatever class it finds.

One more thing decides whether the icon appears at all: **the `<svg` root element
has to start within the first 256 bytes of `tool/branding/linthra_icon.svg`**.
An SVG has no magic number, so content sniffing looks for that literal string and
gives up after 256 bytes. Push it past that (a licence header, a `DOCTYPE`, a
descriptive comment between the XML declaration and the root tag) and gdk-pixbuf
refuses the file outright: GTK cannot load it as a themed icon, and every
launcher that resolves icons through that stack shows a generic one. The file
still parses, still validates, and still renders in a browser, which is why the
checker measures the offset. Put comments *inside* the root element.

## Suspend / resume (manual matrix)

System sleep and wake are only partly visible to Flutter: the embedder usually
delivers `AppLifecycleState.paused` → `resumed`, but audio devices (PulseAudio /
PipeWire, Bluetooth sinks) and the network often come back later than that
signal. Linthra therefore:

* arms recovery only on **`paused`** (not brief `inactive` dialogs);
* on Linux, after resume, waits a short backoff then **re-resolves and reloads
  the current track on the same engine** when playback was active across
  suspend — never a second player, so audio cannot duplicate;
* leaves a **user-paused** track paused;
* surfaces the existing error + Retry UI when recovery fails;
* does **not** enable this path on Android (screen-on must never auto-restart).

Automated coverage: `test/core/services/linux_suspend_resume_recovery_test.dart`
and the ActivePlaybackController lifecycle tests. Re-check on a real machine
before a Linux milestone release:

| Scenario | While… | Expect after wake |
| --- | --- | --- |
| Lid close / Sleep | Playing a **local** file | Same track/queue; audio returns near the prior position; no second stream |
| Lid close / Sleep | Playing a **remote** (Jellyfin / Navidrome / Plex) stream | Fresh stream URL; same logical track/queue; Reconnecting… then playing, or error + Retry if the server is still down |
| Lid close / Sleep | **Paused** | Still paused; pressing play resumes the same track |
| Sleep with **Bluetooth** headphones offline | Playing | Recoverable error or success once the sink returns; never hung forever |
| Sleep with **network** offline | Playing remote | Bounded recovery; Retry works when connectivity returns |
| Minimize only (no sleep) | Playing | App stays responsive; no crash; ideally continues without a full reload |
| Repeat sleep/wake **3×** | Playing | Still one coherent queue/position; no growing listener/service leak; UI stays usable |

## Crash-safe playback restore

On Linux, Linthra persists a small **logical** playback session while a track is
queued — provider-namespaced track ids (`jellyfin:…`), local paths, shuffle/
repeat modes, and position. It never writes authenticated stream URLs or
provider tokens. After an unexpected process exit, the next launch restores that
queue as **paused** (never autoplay); pressing play re-resolves remote tracks
through the normal signed-in provider path. Missing local files, signed-out
providers, and wrong-version/corrupt records drop only the invalid rows (or the
whole session) and never block startup.

Automated coverage: `test/core/models/persisted_playback_session_test.dart`,
`test/data/repositories/shared_preferences_playback_session_store_test.dart`,
`test/core/services/playback_session_persistence_test.dart`.

## Release tarball

Every official release gets `Linthra-<tag>-linux-x64.tar.gz` attached to its
GitHub Release automatically — e.g. `Linthra-v0.1.15-linux-x64.tar.gz` for
tag `v0.1.15`. This isn't wired to a tag push or a Release-publish event
(Linthra's release automation creates both using its own `GITHUB_TOKEN`,
and GitHub generally doesn't start new workflow runs from `GITHUB_TOKEN`-
authored events); instead `publish-stable-release.yml` (for stable releases)
and `android-release-build.yml` (for a directly-pushed alpha/beta/rc tag)
explicitly dispatch `linux-desktop-build.yml` at the exact release tag once
the Release exists. The archive is exactly `flutter build linux --release`'s
output (`build/linux/x64/release/bundle/`) at that tag, tarred with the
bundle contents (`linthra`, `lib/`, `data/`, …) at the archive root:

```bash
tar -xzf Linthra-v0.1.15-linux-x64.tar.gz
./Linthra-v0.1.15-linux-x64/linthra
```

**This is the native Linux build, not a self-contained package.** It still
needs the runtime libraries in [Required packages](#required-packages) —
libmpv and GTK 3 in particular — already installed on the machine running it,
and a Secret Service provider for [secure storage](#secure-storage). It is
**not** distro-independent. The eventual [Flatpak](#where-this-is-going) is
the self-contained, sandboxed distribution target; this tarball is a plain
native build for anyone who already has the runtime dependencies on hand, and
it is separate work with no bearing on the Flatpak's design.

See [docs/release-process.md §4a](./release-process.md#4a-linux-release-tarball-dispatched-alongside-the-android-build)
for exactly how the CI job builds and attaches it.

## Where this is going

The Linux distribution target is **Flathub**. A locally installable Flatpak on
Fedora Kinoite is a validation step on the way, not the destination.

That packaging is now underway in #376 and lives outside this page: the
committed manifest is in [`flatpak/`](../flatpak/README.md) and the contributor
workflow for building, installing and debugging it on Fedora Atomic is
[flatpak-development.md](./flatpak-development.md). It builds, installs and
launches with working audio, and installs the desktop entry
(`linux/packaging/io.github.thezupzup.linthra.desktop`, shared with any future
native package rather than Flatpak-only) together with Linthra's icon under
`share/icons/hicolor/` (the scalable SVG launchers resolve, plus the fixed-size
PNGs GTK needs for the window's own `_NET_WM_ICON`) and AppStream metainfo
under
`linux/packaging/io.github.thezupzup.linthra.metainfo.xml`; networking is
granted with one narrow permission, secure storage needs none (it goes through
the desktop's Secret portal), and the remaining filesystem-permission audit is
still an open sub-issue.
None of it changes the native build on this page.

Decisions already taken with that destination in mind:

* one reverse-DNS application id shared with Android, stable and
  Flathub-shaped (`io.github.thezupzup.linthra`);
* no build-time dependency on host filesystem paths (enforced by the checker);
* no runtime downloading of anything that belongs in the build;
* the SQLite escape hatch above, so a network-isolated build is already
  possible;
* every platform integration behind an interface, so a sandboxed portal-based
  implementation can be slotted in without touching feature code.
