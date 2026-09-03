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
MANIFEST_PATH="$FLATPAK_DIR/$MANIFEST"

manifest_scalar() {
  local key="$1"
  sed -n "s/^${key}:[[:space:]]*//p" "$MANIFEST_PATH" |
    head -n 1 |
    tr -d "'\""
}

command -v flatpak >/dev/null 2>&1 || fail "flatpak is not installed"
[[ -f "$MANIFEST_PATH" ]] || fail "missing generated manifest: flatpak/$MANIFEST"

if command -v flatpak-builder >/dev/null 2>&1; then
  BUILDER=(flatpak-builder)
elif flatpak info org.flatpak.Builder >/dev/null 2>&1; then
  BUILDER=(flatpak run org.flatpak.Builder)
else
  fail "flatpak-builder is unavailable; install org.flatpak.Builder or your distro's flatpak-builder package"
fi

# Read the current runtime requirements from the generated manifest instead of
# duplicating version numbers here. The GNOME SDK itself reports the matching
# freedesktop SDK branch; SDK extensions such as llvm20 use that branch rather
# than GNOME's runtime-version.
runtime_id="$(manifest_scalar runtime)"
runtime_version="$(manifest_scalar runtime-version)"
sdk_id="$(manifest_scalar sdk)"
[[ -n "$runtime_id" && -n "$runtime_version" && -n "$sdk_id" ]] ||
  fail "could not derive runtime/sdk prerequisites from flatpak/$MANIFEST"

runtime_ref="$runtime_id//$runtime_version"
sdk_ref="$sdk_id//$runtime_version"
for runtime_ref_to_check in "$runtime_ref" "$sdk_ref"; do
  flatpak info "$runtime_ref_to_check" >/dev/null 2>&1 ||
    fail "missing $runtime_ref_to_check; install the Flatpak build prerequisites documented in docs/flatpak-development.md"
done

sdk_base_ref="$(flatpak info --show-runtime "$sdk_ref" 2>/dev/null)" ||
  fail "could not determine the base runtime for $sdk_ref"
sdk_extension_branch="${sdk_base_ref##*/}"
[[ -n "$sdk_extension_branch" ]] ||
  fail "could not derive the SDK extension branch from $sdk_base_ref"

mapfile -t sdk_extensions < <(
  awk '
    /^sdk-extensions:/ { in_extensions = 1; next }
    in_extensions && /^  - / { sub(/^  - /, ""); print; next }
    in_extensions && /^[^ ]/ { exit }
  ' "$MANIFEST_PATH" | tr -d "'\""
)
for extension in "${sdk_extensions[@]}"; do
  [[ -n "$extension" ]] || continue
  extension_ref="$extension//$sdk_extension_branch"
  flatpak info "$extension_ref" >/dev/null 2>&1 ||
    fail "missing $extension_ref; install the Flatpak build prerequisites documented in docs/flatpak-development.md"
done

cd "$FLATPAK_DIR"

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
