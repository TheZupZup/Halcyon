#!/usr/bin/env bash
# Prove that the committed Flatpak can build after its declared sources have
# been fetched, with source downloads disabled for the actual build.
#
# This deliberately separates the only networked phase (flatpak-builder
# fetching manifest-declared sources) from the build phase. If pub, CMake, a
# plugin, or another build command tries to fetch something undeclared, the
# second phase fails instead of quietly using the network or a developer cache.

set -euo pipefail

APP_ID="io.github.thezupzup.linthra"
MANIFEST="io.github.thezupzup.linthra.yml"
BUILD_DIR="flatpak-builder-offline-smoke"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n==> %s\n' "$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLATPAK_DIR="$REPO_ROOT/flatpak"

command -v flatpak >/dev/null 2>&1 || fail "flatpak is not installed"

if command -v flatpak-builder >/dev/null 2>&1; then
  BUILDER=(flatpak-builder)
elif flatpak info org.flatpak.Builder >/dev/null 2>&1; then
  BUILDER=(flatpak run org.flatpak.Builder)
else
  fail "flatpak-builder is unavailable; install org.flatpak.Builder or your distro's flatpak-builder package"
fi

# flatpak-builder does not install SDK/runtime dependencies implicitly. Keep
# this smoke focused on source/build network independence and fail with a clear
# prerequisite message instead of turning missing runtimes into a misleading
# offline-source failure.
for runtime in \
  "org.gnome.Platform//50" \
  "org.gnome.Sdk//50" \
  "org.freedesktop.Sdk.Extension.llvm20//25.08"; do
  flatpak info "$runtime" >/dev/null 2>&1 ||
    fail "missing $runtime; install the Flatpak build prerequisites documented in docs/flatpak-development.md"
done

cd "$FLATPAK_DIR"
[[ -f "$MANIFEST" ]] || fail "missing generated manifest: flatpak/$MANIFEST"

info "Phase 1/2: fetch only manifest-declared sources"
"${BUILDER[@]}" --user --download-only --force-clean "$BUILD_DIR" "$MANIFEST"

# Keep .flatpak-builder's source downloads from phase 1, but do not allow its
# per-module build cache to satisfy phase 2. --disable-cache forces every module
# to execute its build commands again; --disable-download means those commands
# can use only the sources already fetched from the manifest.
rm -rf -- "$BUILD_DIR"

info "Phase 2/2: uncached build with all source downloads disabled"
"${BUILDER[@]}" \
  --user \
  --disable-cache \
  --disable-download \
  --force-clean \
  "$BUILD_DIR" \
  "$MANIFEST"

printf '\nPASS: %s rebuilt every module from declared sources with downloads disabled.\n' "$APP_ID"
printf 'No module build result, developer pub cache, or undeclared source fetch was reused.\n'
printf 'Build tree kept at flatpak/%s for inspection; remove it when finished.\n' "$BUILD_DIR"
