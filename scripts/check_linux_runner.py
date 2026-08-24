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

The same three answers are what the installed desktop entry
(`linux/packaging/<app-id>.desktop`, #434) has to repeat — its filename, its
`Icon=`, its `Name=` and its `Exec=` — so it is checked against those sources
of truth too, rather than against the runner's copy of them. A desktop entry
that disagrees is not a build failure either: it installs, it just launches
nothing, shows the wrong name, or (with a filename that is not the app id)
never gets exported by flatpak-builder at all. The Flatpak manifests are
checked for the install step that puts it in `/app/share/applications`, since
an entry nothing installs is the same silence.

The application icon (#436) is that same silence one step further out. `Icon=`
is an icon-theme *name*, not a path, so it only resolves if a file of exactly
that basename lands in the icon theme; install it one directory too high, or
rename either side, and every launcher quietly falls back to a generic icon
with nothing logged anywhere. So the manifests are checked for the install step
that puts Linthra's canonical vector source into `hicolor/scalable/apps` under
precisely the name `Icon=` asks for, and that source is itself checked for the
two things that would make it unusable inside a sandbox: an absolute host path,
or a reference to a file it does not carry.

It also checks two things that are about *how* the runner builds rather than
what it is called:

  * the temporary Clang exception for flutter_secure_storage_linux stays
    PRIVATE to that plugin target, so the legacy bundled header builds without
    weakening -Werror for Linthra or any other plugin;
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
from xml.etree import ElementTree

# Paths this script reads, all relative to the repository root.
CMAKELISTS = Path("linux") / "CMakeLists.txt"
MY_APPLICATION = Path("linux") / "runner" / "my_application.cc"
PUBSPEC = Path("pubspec.yaml")
APP_INFO = Path("lib") / "core" / "app_info.dart"
BUILD_GRADLE = Path("android") / "app" / "build.gradle"
# The installed desktop entry and the two Flatpak manifests that install it.
# All three are named after the application id, so their real paths are built
# from it at check time rather than hardcoded here.
PACKAGING_DIR = Path("linux") / "packaging"
FLATPAK_DIR = Path("flatpak")
FLATPAK_TEMPLATE = FLATPAK_DIR / "flatpak-flutter.yml"

# Where a Flatpak's desktop entry has to land: flatpak-builder exports what it
# finds in this directory at `finish` time and nothing from anywhere else.
DESKTOP_ENTRY_INSTALL_DIR = "/app/share/applications"

# Linthra's canonical vector app icon: the source design that
# tool/branding/generate_icons.py rasterises into the Android launcher mipmaps
# and the store graphics. Linux packaging installs this file itself rather than
# a copy of it, so there is no second brand mark that can drift from the first.
ICON_SOURCE = Path("tool") / "branding" / "linthra_icon.svg"

# `hicolor` is the fallback theme every icon theme inherits from, and
# `scalable/apps` is where an application's own resolution-independent icon
# belongs — one SVG covers every launcher size and every HiDPI scale, so no
# raster fallbacks are installed. The basename, minus the extension, is the
# icon-theme name the desktop entry's `Icon=` looks up.
ICON_INSTALL_DIR = "/app/share/icons/hicolor/scalable/apps"
ICON_EXTENSION = ".svg"

SVG_ROOT_TAG = "{http://www.w3.org/2000/svg}svg"

# An SVG that pulls in something it does not carry — an <image href=...>, an
# external stylesheet or font, a `file://` or `https://` reference — renders
# differently or not at all inside the sandbox, where none of that is
# reachable. Internal fragment references (`fill="url(#bars)"`, the gradients
# the mark is built from) are exactly what an SVG is supposed to do, so they
# are not matched.
EXTERNAL_REFERENCE_PATTERN = re.compile(
    r"(?:href|src|xlink:href)\s*=\s*[\"']?(?!#)"
    r"|url\(\s*[\"']?(?!#)"
    r"|@import\b",
    re.IGNORECASE,
)

# freedesktop's main categories for an audio player. `Audio` is only valid
# alongside `AudioVideo`, and `Player` alone would leave the entry ungrouped in
# menus that split media by kind. Extra categories (Music, …) are fine.
REQUIRED_CATEGORIES = ("AudioVideo", "Audio", "Player")

DESKTOP_ENTRY_GROUP = "Desktop Entry"

# The CMake variable linux/CMakeLists.txt uses to accept an already-unpacked
# SQLite amalgamation instead of downloading one. See docs/linux-desktop.md.
SQLITE_SOURCE_VARIABLE = "LINTHRA_SQLITE3_SOURCE_DIR"

SECURE_STORAGE_TARGET = "flutter_secure_storage_linux_plugin"
SECURE_STORAGE_WARNING_EXCEPTION = "-Wno-error=deprecated-literal-operator"
SECURE_STORAGE_SCOPED_EXCEPTION = re.compile(
    rf"target_compile_options\(\s*{SECURE_STORAGE_TARGET}\s+PRIVATE\s+"
    rf"{re.escape(SECURE_STORAGE_WARNING_EXCEPTION)}\s*\)"
)

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


def desktop_entry_file(root: Path) -> Path:
    """Where the installed desktop entry has to live, from the app id.

    The filename is not decoration: Flatpak only exports `<app-id>.desktop`,
    and AppStream (#435) will key its component id to the same name.
    """
    return PACKAGING_DIR / f"{android_application_id(root)}.desktop"


def desktop_entry(root: Path) -> dict[str, str]:
    """The `[Desktop Entry]` group of the installed entry, as key -> value.

    A hand-rolled reader rather than `configparser`, which lowercases option
    names by default (`Name` and `Exec` would come back as `name`/`exec`) and
    whose default interpolation treats `%` — the field-code character in a
    desktop `Exec=` — as syntax. Only the default group is returned; a
    localized `Name[de]` key is a distinct key here, and a later group
    (`[Desktop Action …]`) is not read at all.
    """
    text = _read(root, desktop_entry_file(root))
    values: dict[str, str] = {}
    in_group = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            in_group = stripped[1:-1] == DESKTOP_ENTRY_GROUP
            continue
        if in_group and "=" in stripped:
            key, _, value = stripped.partition("=")
            values[key.strip()] = value.strip()
    if not values:
        raise CheckError(
            f"{desktop_entry_file(root)}: no [{DESKTOP_ENTRY_GROUP}] group"
        )
    return values


def desktop_entry_problems(root: Path) -> list[str]:
    """Disagreements between the desktop entry and the app's identity."""
    entry = desktop_entry(root)
    where = desktop_entry_file(root)
    problems: list[str] = []

    def require(key: str, expected: str, source: str) -> None:
        actual = entry.get(key)
        if actual is None:
            problems.append(f"{where}: no {key}=, expected {expected!r} ({source})")
        elif actual != expected:
            problems.append(
                f"{where}: {key}={actual!r} but {source} says {expected!r}"
            )

    require("Type", "Application", "a launchable desktop entry")
    require("Name", app_display_name(root), "lib/core/app_info.dart AppInfo.name")
    # Exec is the bare command, not a path: /app/bin/<name> inside the Flatpak,
    # whatever a native package chose outside it. No `%U`/`%F` field code —
    # Linthra takes no file or URI argument, so accepting one would advertise a
    # handler that silently drops what it is opened with.
    require("Exec", pubspec_name(root), "pubspec.yaml name")
    # Icon is an icon-theme name, which is the app id: #436 installs the icon
    # files under exactly that name.
    require(
        "Icon",
        android_application_id(root),
        "android/app/build.gradle applicationId",
    )

    categories = [item for item in entry.get("Categories", "").split(";") if item]
    missing = [name for name in REQUIRED_CATEGORIES if name not in categories]
    if missing:
        problems.append(
            f"{where}: Categories is missing {', '.join(missing)} — an audio "
            f"player needs {';'.join(REQUIRED_CATEGORIES)}"
        )

    return problems


def desktop_entry_install_problems(root: Path) -> list[str]:
    """Flatpak manifests that do not install the desktop entry.

    Both are checked: `flatpak-flutter.yml` is hand-authored and
    `<app-id>.yml` is generated from it by
    scripts/regenerate_flatpak_sources.sh, so a manifest change that was never
    regenerated leaves the built Flatpak without the entry while the diff looks
    complete.
    """
    app_id = android_application_id(root)
    source = desktop_entry_file(root)
    destination = f"{DESKTOP_ENTRY_INSTALL_DIR}/{app_id}.desktop"
    install = re.compile(
        rf"install\s+-Dm644\s+{re.escape(str(source))}\s+{re.escape(destination)}"
    )

    problems: list[str] = []
    for manifest in (FLATPAK_TEMPLATE, FLATPAK_DIR / f"{app_id}.yml"):
        if install.search(_read(root, manifest)) is None:
            problems.append(
                f"{manifest} does not install {source} to {destination}, so the "
                "built Flatpak has no desktop entry to export"
            )
    return problems


def icon_install_problems(root: Path) -> list[str]:
    """Disagreements between the desktop entry's `Icon=` and the installed icon.

    `Icon=` names a theme entry, so the two halves are only connected by the
    installed file's basename. Both Flatpak manifests are checked, for the same
    reason the desktop entry's install step is: `flatpak-flutter.yml` is
    hand-authored and `<app-id>.yml` is generated from it by
    scripts/regenerate_flatpak_sources.sh, so an icon added to one and not
    regenerated into the other leaves the built Flatpak with no icon while the
    diff looks complete.
    """
    entry = desktop_entry(root)
    icon_name = entry.get("Icon")
    if icon_name is None:
        # desktop_entry_problems() already reports the missing key; without it
        # there is no name to hold the installed file to.
        return []

    destination = f"{ICON_INSTALL_DIR}/{icon_name}{ICON_EXTENSION}"
    install = re.compile(
        rf"install\s+-Dm644\s+{re.escape(str(ICON_SOURCE))}\s+{re.escape(destination)}"
    )

    problems: list[str] = []
    if not (root / ICON_SOURCE).is_file():
        problems.append(
            f"{ICON_SOURCE} is missing — it is the canonical vector source the "
            "Linux packaging installs as the application icon"
        )

    app_id = android_application_id(root)
    for manifest in (FLATPAK_TEMPLATE, FLATPAK_DIR / f"{app_id}.yml"):
        if install.search(_read(root, manifest)) is None:
            problems.append(
                f"{manifest} does not install {ICON_SOURCE} to {destination}, so "
                f"{desktop_entry_file(root)}'s Icon={icon_name} resolves to "
                "nothing and launchers fall back to a generic icon"
            )
    return problems


def icon_source_problems(root: Path) -> list[str]:
    """Things in the icon source that make it unusable as an installed icon.

    Parsed with the standard library rather than shelling out to `xmllint` or
    `rsvg-convert`: this check has to run wherever the rest of the checker does,
    including a CI job that installs no extra packages for it.
    """
    path = root / ICON_SOURCE
    if not path.is_file():
        # icon_install_problems() reports the missing file once.
        return []

    problems: list[str] = []

    # Well-formedness first: a broken SVG installs perfectly and then draws
    # nothing. ElementTree also refuses an undefined entity, which is how a
    # DOCTYPE pulling in an external subset shows up here.
    try:
        element = ElementTree.parse(path).getroot()
    except ElementTree.ParseError as error:
        return [f"{ICON_SOURCE}: not well-formed XML — {error}"]
    if element.tag != SVG_ROOT_TAG:
        problems.append(
            f"{ICON_SOURCE}: root element is {element.tag!r}, not an SVG in the "
            f"{SVG_ROOT_TAG} namespace"
        )
    elif element.get("viewBox") is None:
        # Without a viewBox the drawing has no coordinate system to scale, so
        # the file lands in `scalable/` without actually being scalable — it
        # renders at its intrinsic size and every launcher resamples it.
        problems.append(
            f"{ICON_SOURCE}: no viewBox, so it does not scale — an icon in "
            f"{ICON_INSTALL_DIR} has to render sharply at every size"
        )
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        for match in ABSOLUTE_PATH_PATTERN.findall(line):
            problems.append(
                f"absolute host path in the application icon: "
                f"{ICON_SOURCE}:{line_number}: {match}"
            )
        for match in EXTERNAL_REFERENCE_PATTERN.findall(line):
            problems.append(
                f"{ICON_SOURCE}:{line_number}: the application icon references "
                f"something outside itself ({match.strip()!r}); it has to render "
                "from its own contents inside the sandbox"
            )
    return problems


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

    # The installed desktop entry repeats the identity above; it is checked
    # against the same sources of truth, not against the runner's copy, so a
    # runner that drifts is reported once rather than twice.
    problems.extend(desktop_entry_problems(root))
    problems.extend(desktop_entry_install_problems(root))

    # The application icon (#436): `Icon=` above is only a name, so this is
    # what connects it to a file the built Flatpak actually contains.
    problems.extend(icon_install_problems(root))
    problems.extend(icon_source_problems(root))

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

    # Clang 22 diagnoses the old json.hpp bundled by
    # flutter_secure_storage_linux 1.2.3. The exception must remain both unique
    # and PRIVATE to that plugin; a directory/global suppression would weaken
    # the runner's -Werror contract and hide unrelated warnings.
    cmake_code = "\n".join(
        line for line in cmakelists.splitlines() if not line.lstrip().startswith("#")
    )
    if (
        cmake_code.count(SECURE_STORAGE_WARNING_EXCEPTION) != 1
        or SECURE_STORAGE_SCOPED_EXCEPTION.search(cmake_code) is None
    ):
        problems.append(
            "the deprecated-literal-operator exception must appear exactly "
            f"once and be PRIVATE to {SECURE_STORAGE_TARGET}"
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
