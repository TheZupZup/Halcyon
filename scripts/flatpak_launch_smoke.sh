#!/usr/bin/env bash
# Install Linthra from a local Flatpak repository and prove that the packaged
# application reaches a real desktop window inside its sandbox, and that the
# window introduces itself as io.github.thezupzup.linthra (#554).
#
# This is intentionally credential- and network-independent. It uses an Xvfb
# display only for deterministic CI window detection; production users keep the
# manifest's normal Wayland/fallback-X11 behavior. Because Xvfb is X11, this
# exercises the sandbox's --socket=fallback-x11 path, which is also the one
# whose identity a headless runner can actually read back: WM_CLASS and
# _NET_WM_ICON are X properties. Wayland sends the same application id as the
# xdg_toplevel app id, from the same g_set_prgname() call, and there is no
# headless compositor here to ask.

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
command -v xprop >/dev/null 2>&1 || fail "xprop is not installed"
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

    # The xwininfo tree line for the Linthra window, which carries both its X
    # window id and the WM_CLASS pair every other X client sees:
    #
    #   0x600003 "Linthra": ("io.github.thezupzup.linthra" "io.github.thezupzup.linthra")
    #
    # Empty until the window exists, which is also how the wait loop below knows
    # it has not appeared yet.
    window_line() {
      xwininfo -root -tree 2>/dev/null | grep -F "\"$WINDOW_TITLE\":" | head -n 1 || true
    }

    # Read one X property off the window, first line only: xprop renders
    # _NET_WM_ICON as ASCII art of the icon, and all these checks need is the
    # header line.
    window_property() {
      xprop -id "$1" "$2" 2>&1 | head -n 1 || true
    }

    # Wait for an X property to appear on the window, because the window shows
    # up in the X tree before it carries all of them.
    #
    # GTK sets them in one pass through gtk_window_realize(), but not at one
    # moment. The title and the WM_CLASS pair are attributes of the
    # gdk_window_new() call that creates the window, so they are on it from its
    # first instant. The icon is set last: gtk_window_realize_icon() runs at the
    # end of the same function, and it first has to resolve the icon name
    # through the icon theme (which round-trips to the X server for the theme
    # name, flushing everything queued before it) and then decode the PNGs it
    # finds. On a cold Flatpak install that lookup is slow enough to be visible,
    # and xwininfo/xprop are separate X clients that see the window as soon as
    # it exists.
    #
    # Sampling once therefore reads a real window mid-realize and can miss an
    # icon that lands a few milliseconds later. That is a race in this smoke
    # test, not in the app, and it failed the Flatpak build on main. Poll to the
    # same deadline as the window itself instead: an icon that never resolves
    # still fails, which is the regression this guards.
    wait_for_property() {
      local window_id="$1"
      local property="$2"
      local deadline=$((SECONDS + TIMEOUT_SECONDS))
      local value

      while :; do
        value="$(window_property "$window_id" "$property")"
        case "$value" in
          "" | *"not found"*) ;;
          *)
            printf "%s\n" "$value"
            return 0
            ;;
        esac

        (( SECONDS < deadline )) || break
        sleep 0.25
      done

      printf "%s\n" "$value"
      return 1
    }

    # Close the app and wait for its window to actually leave the X server, so
    # the next launch cannot match a window left behind by the previous one.
    stop_app() {
      flatpak kill "$APP_ID" >/dev/null 2>&1 || true
      wait "$1" >/dev/null 2>&1 || true

      local attempt
      for attempt in $(seq 1 20); do
        [ -z "$(window_line)" ] && return 0
        sleep 0.25
      done
      printf "WARNING: a %s window is still mapped after closing the app.\n" \
        "$WINDOW_TITLE" >&2
    }

    # One full launch: start the packaged app, wait for its window, and hold that
    # window to the application id. Both checks are about desktop identity rather
    # than rendering:
    #
    #   WM_CLASS      is what a launcher matches a window against on X11. GTK
    #                 builds the pair from g_get_prgname() and
    #                 gdk_get_program_class(); the class half only equals the app
    #                 id because linux/runner/my_application.cc sets it, and it is
    #                 the value the desktop entry StartupWMClass= declares.
    #   _NET_WM_ICON  is the icon the window itself carries. GTK attaches it from the icon name
    #                 the runner sets as the default, so its presence proves the
    #                 hicolor icons the Flatpak installed actually resolve from
    #                 inside the sandbox (#558: the rasters, since gdk-pixbuf has
    #                 no SVG loader there). Without it every task switcher and
    #                 panel falls back to a generic icon.
    launch_and_check() {
      local what="$1"
      local app_pid deadline line window_id wm_class expected icon status

      : >"$log_file"
      flatpak run "$APP_ID" >"$log_file" 2>&1 &
      app_pid=$!

      line=""
      deadline=$((SECONDS + TIMEOUT_SECONDS))
      while (( SECONDS < deadline )); do
        line="$(window_line)"
        [ -n "$line" ] && break

        if ! kill -0 "$app_pid" >/dev/null 2>&1; then
          status=0
          wait "$app_pid" || status=$?
          printf "FAIL: %s exited before opening its window (%s, status %s).\n" \
            "$APP_ID" "$what" "$status" >&2
          cat "$log_file" >&2
          return 1
        fi

        sleep 0.5
      done

      if [ -z "$line" ]; then
        printf "FAIL: %s did not open a %s window within %ss (%s).\n" \
          "$APP_ID" "$WINDOW_TITLE" "$TIMEOUT_SECONDS" "$what" >&2
        cat "$log_file" >&2
        stop_app "$app_pid"
        return 1
      fi

      printf "PASS: packaged %s opened a %s window (%s).\n" \
        "$APP_ID" "$WINDOW_TITLE" "$what"

      window_id="$(printf "%s\n" "$line" | awk "{print \$1}")"

      wm_class="$(wait_for_property "$window_id" WM_CLASS)" || true
      expected="WM_CLASS(STRING) = \"$APP_ID\", \"$APP_ID\""
      if [ "$wm_class" != "$expected" ]; then
        printf "FAIL: the %s window does not identify as %s (%s).\n" \
          "$WINDOW_TITLE" "$APP_ID" "$what" >&2
        printf "  expected: %s\n" "$expected" >&2
        printf "  actual:   %s\n" "$wm_class" >&2
        cat "$log_file" >&2
        stop_app "$app_pid"
        return 1
      fi
      printf "PASS: %s\n" "$wm_class"

      # All that matters is that the property exists at all.
      if ! icon="$(wait_for_property "$window_id" _NET_WM_ICON)"; then
        printf "FAIL: the %s window carries no _NET_WM_ICON after %ss (%s), so\n" \
          "$WINDOW_TITLE" "$TIMEOUT_SECONDS" "$what" >&2
        printf "      the installed %s icon did not resolve inside the sandbox.\n" \
          "$APP_ID" >&2
        cat "$log_file" >&2
        stop_app "$app_pid"
        return 1
      fi
      printf "PASS: %s window carries _NET_WM_ICON (%s).\n" "$WINDOW_TITLE" "$icon"

      stop_app "$app_pid"
    }

    launch_and_check "first launch"

    # Close and reopen. Identity has to survive a restart, or a relaunch from the
    # launcher lands beside the entry it came from instead of grouping with it.
    launch_and_check "reopen after close"
  '
