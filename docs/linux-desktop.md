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

The Flutter Linux toolchain plus the native libraries Linthra's plugins need.

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
`flutter analyze`, `flutter test`, the runner configuration check, the same
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

Two runtime facts worth knowing:

* A Secret Service provider must be running and **unlocked**. On a normal
  desktop session the login keyring is unlocked at login and nothing is asked of
  you. On a bare window manager with no keyring daemon, reads and writes fail —
  Linthra treats that as "not signed in" and keeps running. It never writes
  credentials anywhere else.
* Credential storage was not weakened to make Linux work, and there is no
  plaintext fallback on any platform.

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

libmpv provides broad codec/container support and PulseAudio/PipeWire output.
It is a native runtime dependency, not a binary downloaded when Linthra starts.
The future Flatpak manifest must build or include libmpv as a declared module.
`media_kit_libs_linux` normally offers an optional build-time mimalloc download;
Linthra explicitly disables it in `linux/CMakeLists.txt`, so this backend adds no
undeclared network access to an isolated `flatpak-builder` build.

## Remaining Linux limitations

| Area | State | Why |
| --- | --- | --- |
| **Audio playback** | Supported | media_kit/libmpv through `LinuxPlaybackController`; local files and resolved Jellyfin, Navidrome/Subsonic, and Plex HTTP(S) streams share one backend. |
| **Light/Dark/System theme** | Supported | Settings → Appearance's System/Light/Dark choice ([issue #459](https://github.com/TheZupZup/Linthra/issues/459)) is the same shared `ThemeModePreference`/`ThemeModeController` Android uses, mapped onto `MaterialApp`'s own `themeMode`. System follows the desktop's light/dark preference through Flutter's Linux (GTK) embedder and updates live with no restart — no `gsettings`/D-Bus/GNOME/KDE-specific code in Linthra itself, and no separate Linux theme path. See `test/app/theme_mode_test.dart`. |
| Media session / MPRIS | Unsupported | `audio_service` is Android/iOS only. `PlatformMediaSessionBinding` returns the inert binding on Linux, so `audio_service` is never initialised there. MPRIS is later desktop work. |
| Android Auto | Android-only, by design | It is an Android platform integration, not a Linthra feature. |
| Media notification + `POST_NOTIFICATIONS` | Android-only, by design | There is no equivalent gate on Linux; desktop controls arrive with MPRIS. |
| Android audio focus | Android-only, by design | `JustAudioPlaybackController` already scopes its focus handling to Android/iOS. |
| SAF (`content://` folders) | Android-only, by design | Linux picks a real filesystem path. The scanner's desktop path is the one that runs. |
| Local tag/artwork reading | Unsupported | `UnsupportedLocalMetadataReader` on every filesystem scan, Android included. Tracks fall back to filename/folder derivation. A real desktop reader is later work in #376. |
| Chromecast | Android/iOS only | Already gated in `cast_providers.dart`; Linux keeps the honest "cast unavailable" service. |
| Share sheet, launcher-icon switching | Android-only, by design | No desktop equivalent; the UI simply omits them. |
| Desktop layout, keyboard shortcuts, media keys | Not started | The existing layout renders in the window and is usable for development. The desktop UX pass is later work in #376. |

Nothing in that table is faked. Each one is an explicit implementation behind an
existing interface, so it is visible in the code and covered by tests.

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
| `PlatformFolderPickerService` | SAF tree picker | `file_picker` filesystem chooser |
| `PlatformAudioFileScanner` | SAF content-resolver walk | `dart:io` walk |
| `safDocumentListerProvider` | native content resolver | unsupported |
| `safPermissionProbeProvider` | native grant probe | unsupported |
| `localLyricsReaderProvider` | SAF sibling document | filesystem sibling |
| `PlatformShareService` | `ACTION_SEND` | no-op |
| `PlatformLauncherIconService` | `<activity-alias>` toggle | no-op |

Adding a platform-specific behaviour means adding a row here, not a check in a
widget.

## Guardrails

* `scripts/check_linux_runner.py` — the committed runner still matches the app's
  identity (`APPLICATION_ID` = Android's `applicationId`, `BINARY_NAME` =
  the package name, window title = `AppInfo.name`), the window metrics are
  sane, the offline SQLite seam is wired, and nothing under `linux/` hardcodes
  an absolute host path. Tests: `test/tooling/check_linux_runner_test.py`.
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
Fedora Kinoite is a validation step on the way, not the destination. Flatpak
packaging — manifest, desktop file, icons, AppStream metadata, sandbox
permissions — is later work in #376 and is not part of this milestone.

Decisions already taken with that destination in mind:

* one reverse-DNS application id shared with Android, stable and
  Flathub-shaped (`io.github.thezupzup.linthra`);
* no build-time dependency on host filesystem paths (enforced by the checker);
* no runtime downloading of anything that belongs in the build;
* the SQLite escape hatch above, so a network-isolated build is already
  possible;
* every platform integration behind an interface, so a sandboxed portal-based
  implementation can be slotted in without touching feature code.
