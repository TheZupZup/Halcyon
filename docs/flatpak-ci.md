# Flatpak CI validation

Linthra's Flatpak packaging has a dedicated GitHub Actions build in
`.github/workflows/flatpak-build.yml`. It runs on packaging-relevant pull
requests and pushes to `main`, plus manual dispatches.

The workflow is intentionally read-only and does not use repository secrets, so
fork pull requests can run the same validation as maintainer branches.

## What CI proves

The job starts from a clean Ubuntu runner and:

1. installs Flatpak, flatpak-builder, AppStream and desktop-entry validators;
2. runs Linthra's committed Linux packaging checks;
3. validates the desktop entry and AppStream metadata;
4. adds a user-level Flathub remote;
5. asks flatpak-builder to install the SDK/runtime prerequisites declared by the
   generated manifest;
6. builds the real generated Flatpak manifest with module-cache reuse disabled;
7. exports the result into a local Flatpak repository and verifies that export.

No `actions/cache` entry is used by this workflow. Correctness therefore does
not depend on developer machine state or a warm GitHub Actions cache. The build
uses `--disable-rofiles-fuse` only to avoid requiring FUSE support from the
hosted runner; it does not widen the application's Flatpak sandbox.

## Reproduce the build locally

Install the host tooling first. On Fedora Atomic, the contributor setup in
[`flatpak-development.md`](./flatpak-development.md) remains the recommended
path. On a distribution with native `flatpak-builder`, the core CI sequence is:

```bash
python3 scripts/check_linux_runner.py
python3 test/tooling/check_linux_runner_test.py

desktop-file-validate \
  linux/packaging/io.github.thezupzup.linthra.desktop
appstreamcli validate \
  linux/packaging/io.github.thezupzup.linthra.metainfo.xml

flatpak remote-add --user --if-not-exists \
  flathub https://dl.flathub.org/repo/flathub.flatpakrepo

cd flatpak
flatpak-builder \
  --user \
  --install-deps-from=flathub \
  --install-deps-only \
  --force-clean \
  flatpak-builder-ci \
  io.github.thezupzup.linthra.yml

rm -rf -- flatpak-builder-ci repo-ci
flatpak-builder \
  --user \
  --force-clean \
  --disable-cache \
  --disable-rofiles-fuse \
  --repo=repo-ci \
  flatpak-builder-ci \
  io.github.thezupzup.linthra.yml

flatpak build-update-repo repo-ci
```

The workflow does not replace the stricter offline-source smoke from #442 or the
installed-app launch/audio/library smoke tests tracked separately. Its job is to
catch broken manifests, missing declared build inputs, SDK/runtime resolution
problems and clean-runner packaging failures before they reach Flathub.
