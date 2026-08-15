#!/usr/bin/env python3
"""check_linux_runner.py — hold the committed Linux runner to Linthra's identity.

The `linux/` directory is Flutter template code that Linthra has edited. That
combination rots quietly: `flutter create --platforms=linux .` regenerates those
files from the template, and a regeneration silently restores the template's
lowercase `"linthra"` window title, drops the window-size constants, and — the
expensive one — drops the SQLite pre-fetch seam that lets the app build with no
network. Nothing fails; the app still compiles. It just stops being Linthra, or
stops building offline, and nobody notices until packaging.

So the identity is asserted against its real sources of truth instead of being
duplicated here:

    application id  <- android/app/build.gradle (applicationId)
    binary name     <- pubspec.yaml (name)
    window title    <- lib/core/app_info.dart (AppInfo.name)

Those three are what a desktop and, later, a Flathub listing key off. An app id
that disagrees with Android's would mean two different identities for one
product; a window title that disagrees with `AppInfo.name` would mean the title
bar and the About screen disagree.

It also checks two things that are about *how* the runner builds rather than
what it is called:

  * the SQLite pre-fetch seam (LINTHRA_SQLITE3_SOURCE_DIR) is still there, so a
    network-isolated build — flatpak-builder included — stays possible;
  * nothing under linux/ hardcodes an absolute host path, which would make the
    build depend on one machine's filesystem.

Usage
-----

    python3 scripts/check_linux_runner.py            # check this repository
    python3 scripts/check_linux_runner.py --root DIR # check another checkout

Read-only, offline, no dependencies beyond the standard library. Exit status: 0
if the runner agrees with the app, 2 if it does not.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Paths this script reads, all relative to the repository root.
CMAKELISTS = Path("linux") / "CMakeLists.txt"
MY_APPLICATION = Path("linux") / "runner" / "my_application.cc"
PUBSPEC = Path("pubspec.yaml")
APP_INFO = Path("lib") / "core" / "app_info.dart"
BUILD_GRADLE = Path("android") / "app" / "build.gradle"

# The CMake variable linux/CMakeLists.txt uses to accept an already-unpacked
# SQLite amalgamation instead of downloading one. See docs/linux-desktop.md.
SQLITE_SOURCE_VARIABLE = "LINTHRA_SQLITE3_SOURCE_DIR"

# An absolute path baked into the native build would tie it to one machine.
# `/` alone is far too common in CMake (every ${VAR}/sub path), so this looks
# for a quoted or bare token that starts at a real filesystem root.
ABSOLUTE_PATH_PATTERN = re.compile(
    r'(?<![\w$/{])/(?:home|Users|root|opt|usr/local|tmp|var|mnt|media)/[\w./-]+'
)


class CheckError(Exception):
    """A file could not be read or a required value could not be found."""


def _read(root: Path, relative: Path) -> str:
    path = root / relative
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise CheckError(f"cannot read {relative}: {error}") from error


def _extract(text: str, pattern: str, what: str, where: Path) -> str:
    """Return the single capture group of `pattern` in `text`.

    Requiring exactly one match is the point: a second `set(BINARY_NAME ...)`
    or a second `static const char* kApplicationName` means the file no longer
    has one answer, and picking the first would hide that.
    """
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if not matches:
        raise CheckError(f"{where}: could not find {what}")
    if len(matches) > 1:
        raise CheckError(f"{where}: found {len(matches)} definitions of {what}, expected 1")
    return matches[0]


def application_id(root: Path) -> str:
    """The GTK application id the Linux runner registers under."""
    return _extract(
        _read(root, CMAKELISTS),
        r'^set\(APPLICATION_ID\s+"([^"]+)"\)',
        "APPLICATION_ID",
        CMAKELISTS,
    )


def binary_name(root: Path) -> str:
    """The on-disk name of the built executable."""
    return _extract(
        _read(root, CMAKELISTS),
        r'^set\(BINARY_NAME\s+"([^"]+)"\)',
        "BINARY_NAME",
        CMAKELISTS,
    )


def window_title(root: Path) -> str:
    """The user-visible name the runner puts in the title/header bar."""
    return _extract(
        _read(root, MY_APPLICATION),
        r'kApplicationName\s*=\s*"([^"]+)"',
        "kApplicationName",
        MY_APPLICATION,
    )


def window_metric(root: Path, name: str) -> int:
    """One of the runner's window-size constants."""
    return int(
        _extract(
            _read(root, MY_APPLICATION),
            rf"{name}\s*=\s*(\d+);",
            name,
            MY_APPLICATION,
        )
    )


def android_application_id(root: Path) -> str:
    """Android's applicationId — the identity Linux has to match."""
    return _extract(
        _read(root, BUILD_GRADLE),
        r'^\s*applicationId\s*=\s*"([^"]+)"',
        "applicationId",
        BUILD_GRADLE,
    )


def pubspec_name(root: Path) -> str:
    """The Dart package name, which is also the executable name."""
    return _extract(_read(root, PUBSPEC), r"^name:\s*(\S+)", "name", PUBSPEC)


def app_display_name(root: Path) -> str:
    """`AppInfo.name` — the product name the app shows about itself."""
    return _extract(
        _read(root, APP_INFO),
        r"static const String name\s*=\s*'([^']+)'",
        "AppInfo.name",
        APP_INFO,
    )


def absolute_paths_under_linux(root: Path) -> list[str]:
    """Absolute host paths hardcoded in the committed Linux build files.

    Only the files Linthra owns are scanned. `linux/flutter/ephemeral` is
    generated per build and is not in git.
    """
    findings: list[str] = []
    linux_dir = root / "linux"
    for path in sorted(linux_dir.rglob("*")):
        if not path.is_file():
            continue
        if "ephemeral" in path.relative_to(linux_dir).parts:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in ABSOLUTE_PATH_PATTERN.findall(line):
                findings.append(f"{path.relative_to(root)}:{line_number}: {match}")
    return findings


def check(root: Path) -> list[str]:
    """Return the problems found, empty when the runner is consistent."""
    problems: list[str] = []

    def compare(label: str, actual: str, expected: str, source: str) -> None:
        if actual != expected:
            problems.append(
                f"{label} is {actual!r} but {source} says {expected!r}"
            )

    compare(
        "linux/CMakeLists.txt APPLICATION_ID",
        application_id(root),
        android_application_id(root),
        "android/app/build.gradle applicationId",
    )
    compare(
        "linux/CMakeLists.txt BINARY_NAME",
        binary_name(root),
        pubspec_name(root),
        "pubspec.yaml name",
    )
    compare(
        "linux/runner/my_application.cc kApplicationName",
        window_title(root),
        app_display_name(root),
        "lib/core/app_info.dart AppInfo.name",
    )

    # Window metrics: a minimum larger than the default would open the window
    # already clamped, which reads as the app ignoring its own default.
    minimum_width = window_metric(root, "kMinimumWindowWidth")
    minimum_height = window_metric(root, "kMinimumWindowHeight")
    default_width = window_metric(root, "kDefaultWindowWidth")
    default_height = window_metric(root, "kDefaultWindowHeight")
    if minimum_width > default_width or minimum_height > default_height:
        problems.append(
            f"minimum window size {minimum_width}x{minimum_height} exceeds the "
            f"default {default_width}x{default_height}"
        )
    if minimum_width <= 0 or minimum_height <= 0:
        problems.append("minimum window size must be positive")

    # The offline-build seam. Losing it does not break any build that has a
    # network, which is exactly why it needs a guard.
    cmakelists = _read(root, CMAKELISTS)
    if SQLITE_SOURCE_VARIABLE not in cmakelists:
        problems.append(
            f"{CMAKELISTS} no longer honours {SQLITE_SOURCE_VARIABLE}, so the "
            "Linux build cannot be made to skip the SQLite download "
            "(see docs/linux-desktop.md)"
        )
    elif "FETCHCONTENT_SOURCE_DIR_SQLITE3" not in cmakelists:
        problems.append(
            f"{CMAKELISTS} sets {SQLITE_SOURCE_VARIABLE} but never forwards it "
            "to FETCHCONTENT_SOURCE_DIR_SQLITE3, so it has no effect"
        )

    for finding in absolute_paths_under_linux(root):
        problems.append(f"absolute host path in the Linux build: {finding}")

    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check the committed Linux runner against Linthra's identity."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root to check (default: this repository)",
    )
    args = parser.parse_args(argv)

    try:
        problems = check(args.root)
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if problems:
        print("Linux runner configuration problems:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 2

    print("Linux runner configuration OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
