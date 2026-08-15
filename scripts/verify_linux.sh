#!/usr/bin/env bash
#
# verify_linux.sh — run the Linux desktop checks locally, the way CI runs them.
#
# The twin of scripts/verify_android.sh, for the other platform. Order mirrors
# .github/workflows/linux-build.yml:
#
#   flutter pub get --enforce-lockfile  ->  dart format (check)  ->
#   flutter analyze  ->  flutter test  ->  Linux runner config check  ->
#   flutter build linux --release
#
# The shared checks (format/analyze/test) are deliberately repeated here rather
# than delegated: someone working on the desktop build should be able to run one
# script and know whether they broke anything, without also remembering to run
# the Android one.
#
# Native toolchain: `flutter build linux` needs clang, cmake, ninja, pkg-config
# and the GTK 3 development headers, plus libsecret for encrypted credential
# storage. They are checked up front and a missing one *skips* the build with a
# clear message instead of failing the whole script — the same shape as
# verify_android.sh skipping the APK when there is no Android SDK. See
# docs/linux-desktop.md for the Fedora and Debian/Ubuntu package names.
#
# Flutter resolution: prefer the project-local SDK from setup_flutter.sh
# (.tool/flutter), otherwise fall back to Flutter on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOCAL_FLUTTER_BIN="$REPO_ROOT/.tool/flutter/bin/flutter"

info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

resolve_flutter() {
  if [ -x "$LOCAL_FLUTTER_BIN" ]; then
    FLUTTER="$LOCAL_FLUTTER_BIN"
    PATH="$(dirname "$LOCAL_FLUTTER_BIN"):$PATH"
    export PATH
    info "Using project-local Flutter: $FLUTTER"
  elif command -v flutter >/dev/null 2>&1; then
    FLUTTER="$(command -v flutter)"
    info "Using Flutter from PATH: $FLUTTER"
  else
    die "Flutter not found. Run ./scripts/setup_flutter.sh first."
  fi
  "$FLUTTER" --version | head -1 || true
}

# Report the native build prerequisites that are missing, one per line. Empty
# output means the Linux build can run.
missing_native_deps() {
  local missing=()
  local tool
  for tool in clang cmake ninja pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if command -v pkg-config >/dev/null 2>&1; then
    pkg-config --exists gtk+-3.0 || missing+=("gtk+-3.0 development headers")
    pkg-config --exists libsecret-1 || missing+=("libsecret-1 development headers")
  fi
  printf '%s\n' "${missing[@]+"${missing[@]}"}"
}

FAILED=()

run_step() {
  local label="$1"; shift
  info "$label"
  if "$@"; then
    return 0
  fi
  warn "FAILED: $label"
  FAILED+=("$label")
  return 1
}

main() {
  cd "$REPO_ROOT"
  resolve_flutter

  run_step "flutter pub get --enforce-lockfile" "$FLUTTER" pub get --enforce-lockfile
  run_step "dart format --set-exit-if-changed ." dart format --set-exit-if-changed .
  run_step "flutter analyze" "$FLUTTER" analyze
  run_step "flutter test" "$FLUTTER" test

  # Flutter-independent: the committed runner still matches the app's identity
  # and can still build without a network. Cheap, so it runs before the build.
  run_step "Linux runner configuration" python3 scripts/check_linux_runner.py
  run_step "Linux runner tooling tests" python3 test/tooling/check_linux_runner_test.py

  # Read line by line: a dependency name can contain spaces ("gtk+-3.0
  # development headers"), so word splitting would mangle the report.
  local missing=()
  local dep
  while IFS= read -r dep; do
    [ -n "$dep" ] && missing+=("$dep")
  done < <(missing_native_deps)

  if [ "${#missing[@]}" -eq 0 ]; then
    run_step "flutter build linux --release" "$FLUTTER" build linux --release
  else
    warn "Missing native Linux build dependencies:"
    printf '  - %s\n' "${missing[@]}" >&2
    warn "Skipping 'flutter build linux --release'. See docs/linux-desktop.md"
    warn "for the packages to install. analyze/format/tests still ran above."
  fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    info "Verification FAILED (${#FAILED[@]} step(s)):"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi

  info "Verification passed."
}

main "$@"
