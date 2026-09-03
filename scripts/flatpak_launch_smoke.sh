#!/usr/bin/env bash
# Install Linthra from a local Flatpak repository and prove that the packaged
# application reaches a real desktop window inside its sandbox.
#
# This is intentionally credential- and network-independent. It uses an Xvfb
# display only for deterministic CI window detection; production users keep the
# manifest's normal Wayland/fallback-X11 behavior.

set -euo pipefail

APP_ID="io.github.thezupzup.linthra"
REMOTE_NAME="linthra-ci-smoke-$$"
REPO_PATH="${1:-repo-ci}"
WINDOW_TITLE="Linthra"
TIMEOUT_SECONDS="${LINTHRA_FLATPAK_LAUNCH_TIMEOUT:-30}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v flatpak >/dev/null 2>&1 || fail "flatpak is not installed"
command -v xvfb-run >/dev/null 2>&1 || fail "xvfb-run is not installed"
command -v xwininfo >/dev/null 2>&1 || fail "xwininfo is not installed"
command -v dbus-run-session >/dev/null 2>&1 || fail "dbus-run-session is not installed"

REPO_PATH="$(cd "$REPO_PATH" && pwd)" || fail "local Flatpak repo not found: $REPO_PATH"
[[ -f "$REPO_PATH/config" ]] || fail "not a Flatpak repository: $REPO_PATH"

# Never replace or remove a contributor's existing Linthra installation. CI
# starts clean, while a local reproduction must opt into a clean environment
# instead of accidentally launching an older installed build.
if flatpak --user info "$APP_ID" >/dev/null 2>&1 ||
  flatpak --system info "$APP_ID" >/dev/null 2>&1; then
  fail "$APP_ID is already installed; remove it or run this smoke in a clean user environment"
fi

cleanup() {
  flatpak kill "$APP_ID" >/dev/null 2>&1 || true
  flatpak --user uninstall -y "$APP_ID" >/dev/null 2>&1 || true
  flatpak --user remote-delete "$REMOTE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# This uniquely named remote points only at the unsigned repository produced by
# the same CI job. --no-gpg-verify must never be used for Flathub or another
# public remote.
flatpak --user remote-add \
  --no-gpg-verify \
  "$REMOTE_NAME" \
  "$REPO_PATH"
flatpak --user install -y "$REMOTE_NAME" "$APP_ID"

printf 'Installed %s from local repository %s.\n' "$APP_ID" "$REPO_PATH"

export APP_ID WINDOW_TITLE TIMEOUT_SECONDS
xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' \
  dbus-run-session -- bash -c '
    set -euo pipefail

    log_file="$(mktemp)"
    trap '\''rm -f "$log_file"'\'' EXIT

    flatpak run "$APP_ID" >"$log_file" 2>&1 &
    app_pid=$!

    deadline=$((SECONDS + TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
      if xwininfo -root -tree 2>/dev/null | grep -Fq "\"$WINDOW_TITLE\""; then
        printf "PASS: packaged %s opened a %s window.\n" "$APP_ID" "$WINDOW_TITLE"
        flatpak kill "$APP_ID" >/dev/null 2>&1 || true
        wait "$app_pid" >/dev/null 2>&1 || true
        exit 0
      fi

      if ! kill -0 "$app_pid" >/dev/null 2>&1; then
        wait "$app_pid" || status=$?
        status="${status:-0}"
        printf "FAIL: %s exited before opening its window (status %s).\n" \
          "$APP_ID" "$status" >&2
        cat "$log_file" >&2
        exit 1
      fi

      sleep 0.5
    done

    printf "FAIL: %s did not open a %s window within %ss.\n" \
      "$APP_ID" "$WINDOW_TITLE" "$TIMEOUT_SECONDS" >&2
    cat "$log_file" >&2
    flatpak kill "$APP_ID" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    exit 1
  '
