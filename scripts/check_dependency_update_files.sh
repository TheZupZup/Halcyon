#!/usr/bin/env bash
#
# check_dependency_update_files.sh — assert an automatic update only touches
# the files that kind of update is allowed to touch.
#
# Linthra runs two automatic updaters (issue #362), and each one writes exactly
# one file:
#
#   --kind dart-packages   pubspec.lock       the resolved dependency set
#                          .github/workflows/dart-dependency-updates.yml
#                          scripts/update_dart_dependencies.sh
#
#   --kind flutter-sdk     .flutter-version   the pinned Flutter SDK
#                          .github/workflows/flutter-sdk-updates.yml
#
# The kinds are deliberately separate allowlists rather than one union. A
# lockfile refresh has no business editing the toolchain pin, and an SDK bump
# has no business re-resolving the lockfile — that second resolution is a
# human's call, because the committed pubspec.lock is what the reproducible
# F-Droid build resolves from (docs/release-process.md §7). Sharing one list
# would silently give each updater the other's reach.
#
# Nothing else is allowed in either kind. In particular an automatic update
# must never rewrite the constraints in pubspec.yaml, never touch application
# or test code to make a new version compile, and never go near the release
# surface — F-Droid metadata, Fastlane, release notes, signing material,
# licenses or the app version. Those are the changes a human decides on, in a
# PR they wrote.
#
# The updaters already behave that way by construction (`flutter pub upgrade`
# only rewrites the lockfile; the SDK updater writes one version string). This
# guard is the check that the behaviour actually held, so a bot cannot quietly
# grow a wider blast radius than it was designed for.
#
# It is used in two places, deliberately:
#
#   1. In the updater itself, before a commit is created at all.
#   2. In CI, on every `deps/` and `toolchain/` PR, so the boundary is
#      re-checked against the real PR diff — including anything pushed onto the
#      branch afterwards.
#
# Usage:
#
#   # Explicit list (one path per line) on stdin:
#   git diff --name-only <base>..HEAD | scripts/check_dependency_update_files.sh
#   git diff --name-only <base>..HEAD \
#     | scripts/check_dependency_update_files.sh --kind flutter-sdk
#
#   # Or as arguments:
#   scripts/check_dependency_update_files.sh pubspec.lock
#   scripts/check_dependency_update_files.sh --kind flutter-sdk .flutter-version
#
# --kind defaults to dart-packages, the updater that came first.
#
# Read-only, no network, no secrets. Sibling guard:
# scripts/check_release_bump_files.sh does the same job for release/ PRs.

set -uo pipefail

kind="dart-packages"

# Collect candidate paths from arguments, else from stdin.
paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --kind needs a value (dart-packages or flutter-sdk)." >&2
        exit 1
      fi
      kind="$2"
      shift 2 ;;
    --kind=*)
      kind="${1#--kind=}"
      shift ;;
    *)
      paths+=("$1")
      shift ;;
  esac
done

# The allowlist for this kind, and the sentence explaining what the updater is.
case "$kind" in
  dart-packages)
    allowed=("pubspec.lock")
    what="Dart/Flutter package update" ;;
  flutter-sdk)
    allowed=(".flutter-version")
    what="Flutter SDK update" ;;
  *)
    echo "ERROR: unknown --kind '$kind' (expected dart-packages or flutter-sdk)." >&2
    exit 1 ;;
esac

if [ "${#paths[@]}" -eq 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && paths+=("$line")
  done
fi

if [ "${#paths[@]}" -eq 0 ]; then
  echo "No changed files provided; nothing to check."
  exit 0
fi

# Returns 0 if the given path is allowed for this kind of automatic update.
is_allowed() {
  local candidate="$1" entry
  for entry in "${allowed[@]}"; do
    [ "$candidate" = "$entry" ] && return 0
  done
  return 1
}

offenders=()
for p in "${paths[@]}"; do
  is_allowed "$p" || offenders+=("$p")
done

if [ "${#offenders[@]}" -eq 0 ]; then
  echo "OK: $what touches only ${allowed[*]} (${#paths[@]} file(s))."
  exit 0
fi

{
  echo "ERROR: this looks like an automatic $what, but it changes"
  echo "files outside the allowed set:"
  echo
  for p in "${offenders[@]}"; do
    echo "  - $p"
  done
  echo
  echo "An automatic $what may only rewrite:"
  for p in "${allowed[@]}"; do
    echo "  - $p"
  done
  echo
  echo "It must not change dependency constraints (pubspec.yaml), application"
  echo "or test code, the app version, F-Droid metadata, Fastlane files,"
  echo "release notes, signing files or licenses — nor the file the *other*"
  echo "updater owns. If this update genuinely needs one of those, it is not an"
  echo "automatic update — a human should open that PR and explain the change."
} >&2
exit 1
