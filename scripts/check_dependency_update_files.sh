#!/usr/bin/env bash
#
# check_dependency_update_files.sh — assert an automatic Dart/Flutter package
# update only touches the one file such an update is allowed to touch.
#
# The "Dart dependency updates" workflow (and its local twin
# scripts/update_dart_dependencies.sh) re-resolves the dependency graph with the
# pinned Flutter SDK and writes the result to exactly one file:
#
#   * pubspec.lock                                (the resolved dependency set)
#
# Nothing else. In particular an automatic update must never rewrite the
# constraints in pubspec.yaml, never touch application or test code to make a
# new package version compile, and never go near the release surface — F-Droid
# metadata, Fastlane, release notes, signing material, licenses or the app
# version. Those are the changes a human decides on, in a PR they wrote.
#
# `flutter pub upgrade` already behaves that way: it resolves inside the
# existing constraints and only rewrites the lockfile. This guard is the check
# that the behaviour actually held, so the bot cannot quietly grow a wider
# blast radius than it was designed for.
#
# It is used in two places, deliberately:
#
#   1. In the updater itself, before a commit is created at all.
#   2. In CI, on every `deps/` PR, so the boundary is re-checked against the
#      real PR diff — including anything pushed onto the branch afterwards.
#
# Usage:
#
#   # Explicit list (one path per line) on stdin:
#   git diff --name-only <base>..HEAD | scripts/check_dependency_update_files.sh
#
#   # Or as arguments:
#   scripts/check_dependency_update_files.sh pubspec.lock
#
# Read-only, no network, no secrets. Sibling guard:
# scripts/check_release_bump_files.sh does the same job for release/ PRs.

set -uo pipefail

# Collect candidate paths from arguments, else from stdin.
paths=()
if [ "$#" -gt 0 ]; then
  paths=("$@")
else
  while IFS= read -r line; do
    [ -n "$line" ] && paths+=("$line")
  done
fi

if [ "${#paths[@]}" -eq 0 ]; then
  echo "No changed files provided; nothing to check."
  exit 0
fi

# Returns 0 if the given path is allowed in an automatic dependency update.
is_allowed() {
  case "$1" in
    pubspec.lock)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

offenders=()
for p in "${paths[@]}"; do
  is_allowed "$p" || offenders+=("$p")
done

if [ "${#offenders[@]}" -eq 0 ]; then
  echo "OK: dependency update touches only pubspec.lock (${#paths[@]} file(s))."
  exit 0
fi

{
  echo "ERROR: this looks like an automatic dependency update, but it changes"
  echo "files outside the allowed set:"
  echo
  for p in "${offenders[@]}"; do
    echo "  - $p"
  done
  echo
  echo "An automatic Dart/Flutter package update may only rewrite:"
  echo "  - pubspec.lock"
  echo
  echo "It must not change dependency constraints (pubspec.yaml), application"
  echo "or test code, the app version, F-Droid metadata, Fastlane files,"
  echo "release notes, signing files or licenses. If this update genuinely"
  echo "needs one of those, it is not an automatic update — a human should"
  echo "open that PR and explain the change."
} >&2
exit 1
