#!/usr/bin/env python3
"""toolchain_pins.py — where Linthra's Android toolchain pins live, and how to
read, compare and rewrite exactly one of them.

This is the shared core behind the three Android toolchain scripts (issue
#362, PR 5):

    scripts/check_android_toolchain_update.py   detect      (reads upstream)
    scripts/set_android_toolchain_pin.py        write       (one pin, in place)
    scripts/check_toolchain_pin_diff.py         guard       (verifies a diff)

They share this module on purpose. The detector, the writer and the guard must
agree byte-for-byte on *what a pin is* — if the guard's idea of "the AGP
version" ever drifted from the writer's, the guard would be checking something
the writer never touches, and the safety story would be theatre.

The pins
--------

    gradle   android/gradle/wrapper/gradle-wrapper.properties
             the version inside distributionUrl

    agp      android/settings.gradle
             the version of the `com.android.application` plugin

    kotlin   android/settings.gradle
             the version of the `org.jetbrains.kotlin.android` plugin

Note that `agp` and `kotlin` share one file. That is the whole reason this
module exists as more than a table of filenames: a filename allowlist cannot
tell an AGP bump from a Kotlin bump, so the boundary between those two updaters
has to be expressed in terms of file *content*. Each tool's regex captures its
own version and nothing else, `replace_pin` rewrites only that capture, and
scripts/check_toolchain_pin_diff.py proves — against the real before/after text
— that everything outside that one capture is unchanged.

Versions
--------

A pin is a bare `MAJOR.MINOR.PATCH`. That is the shape
test/tooling/toolchain_pins_test.dart already requires of all three pin files,
so it is also the only shape an automatic update may propose. Upstream rows
that are not bare triples — Gradle's historical two-component tags, every
`-alpha`/`-beta`/`-RC`/`-Beta1` plugin build — are simply not candidates. That
one rule does most of the prerelease filtering for free, structurally, rather
than by trying to enumerate every marker upstream might invent.

CLI
---

The one thing this module does from the command line is *read* a pin out of a
file, which the update workflow needs when it inspects the file already sitting
on an update branch:

    git show "origin/toolchain/agp:android/settings.gradle" > /tmp/pinfile
    python3 scripts/toolchain_pins.py --tool agp --file /tmp/pinfile

It prints the version and exits 0, or explains itself and exits 2. It never
writes anything.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# A pin, and every version an automatic update may propose, is a bare triple.
_VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")

# Markers that make an upstream version string a prerelease. Nothing is decided
# by this list — the bare-triple rule above already rejects every one of these,
# because they all carry a suffix. It exists so the checker can *report* "these
# rows were skipped because they are prereleases" separately from "these rows
# were skipped because they were malformed", which is a genuinely useful
# distinction when reading a run's log.
_PRERELEASE_RE = re.compile(
    r"(?i)(alpha|beta|[-.]rc\b|[-.]rc\d|milestone|preview|nightly|snapshot"
    r"|eap|-dev\b|[-.]m\d+\b)"
)

Version = Tuple[int, int, int]


class CheckError(Exception):
    """Input that cannot be trusted. Always fatal — never worked around."""


class Tool:
    """One pinned tool: where its version lives, and how to find it there."""

    def __init__(
        self,
        name: str,
        label: str,
        pin_file: str,
        pattern: re.Pattern[str],
        describe: str,
    ) -> None:
        self.name = name
        self.label = label
        self.pin_file = pin_file
        # Three groups: everything before the version, the version, everything
        # after. Rewriting group 2 and re-joining is the only edit ever made.
        self.pattern = pattern
        self.describe = describe


TOOLS: Dict[str, Tool] = {
    "gradle": Tool(
        name="gradle",
        label="Gradle",
        pin_file="android/gradle/wrapper/gradle-wrapper.properties",
        # Anchored to the start of the distributionUrl line, and stopping at
        # the distribution filename's extension. distributionBase,
        # distributionPath, zipStoreBase and zipStorePath are not matched at
        # all, so an updater that touched one of them would fail the diff
        # guard.
        #
        # Note that the match ends at `.zip` rather than at the end of the
        # line. Everything a pattern matches but does not capture is dropped by
        # `replace_pin`, so an ungrouped `\s*$` here would silently eat the
        # file's trailing newline — which is precisely the kind of "changed
        # something else" the guard exists to reject.
        pattern=re.compile(
            r"(?m)^(distributionUrl=\S*?/gradle-)(\d+\.\d+\.\d+)(-(?:all|bin)\.zip)"
        ),
        describe="the Gradle version in the wrapper's distributionUrl",
    ),
    "agp": Tool(
        name="agp",
        label="Android Gradle Plugin",
        pin_file="android/settings.gradle",
        pattern=re.compile(
            r'(id\s+"com\.android\.application"\s+version\s+")([^"]+)(")'
        ),
        describe='the version of the "com.android.application" plugin',
    ),
    "kotlin": Tool(
        name="kotlin",
        label="Kotlin Gradle plugin",
        pin_file="android/settings.gradle",
        pattern=re.compile(
            r'(id\s+"org\.jetbrains\.kotlin\.android"\s+version\s+")([^"]+)(")'
        ),
        describe='the version of the "org.jetbrains.kotlin.android" plugin',
    ),
}

TOOL_NAMES: List[str] = list(TOOLS)


def tool(name: str) -> Tool:
    try:
        return TOOLS[name]
    except KeyError:
        raise CheckError(
            f"unknown tool {name!r} (expected one of {', '.join(TOOL_NAMES)})"
        ) from None


# -----------------------------------------------------------------------------
# Versions
# -----------------------------------------------------------------------------


def parse_version(text: object, what: str) -> Version:
    """Parse a bare MAJOR.MINOR.PATCH string, or raise CheckError."""
    if not isinstance(text, str):
        raise CheckError(f"{what} is not a string: {text!r}")
    stripped = text.strip()
    if not stripped:
        raise CheckError(f"{what} is empty")
    match = _VERSION_RE.match(stripped)
    if match is None:
        raise CheckError(
            f"{what} is not a bare MAJOR.MINOR.PATCH version: {stripped!r}"
        )
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def try_version(text: object) -> Optional[Version]:
    """Parse a candidate from upstream, or return None if it is not a triple.

    Used where a non-triple is *expected and fine* — an upstream index lists
    prereleases and legacy tags alongside the releases we care about. Anywhere a
    version has to be trustworthy (a pin, a CLI argument, a target) use
    `parse_version`, which raises instead.
    """
    try:
        return parse_version(text, "version")
    except CheckError:
        return None


def looks_like_prerelease(text: object) -> bool:
    """True when a rejected version string is recognisably a prerelease."""
    return isinstance(text, str) and _PRERELEASE_RE.search(text) is not None


def format_version(version: Version) -> str:
    return "{}.{}.{}".format(*version)


# -----------------------------------------------------------------------------
# Reading, and rewriting, one pin
# -----------------------------------------------------------------------------


def find_pin(text: str, name: str, origin: str = "the pin file") -> str:
    """The version `name` pins in `text`.

    Exactly one match is required. Zero means the file no longer looks the way
    this module thinks it does, and more than one means an edit could not be
    aimed unambiguously — both are refusals, not guesses.
    """
    t = tool(name)
    matches = t.pattern.findall(text)
    if not matches:
        raise CheckError(
            f"{origin} does not contain {t.describe}; refusing to guess "
            f"where {t.label}'s version lives"
        )
    if len(matches) > 1:
        found = ", ".join(sorted({m[1] for m in matches}))
        raise CheckError(
            f"{origin} contains {len(matches)} matches for {t.describe} "
            f"({found}); refusing to edit an ambiguous pin"
        )
    return matches[0][1]


def replace_pin(text: str, name: str, version: str) -> str:
    """`text` with `name`'s pin set to `version`, and nothing else changed.

    Only capture group 2 of the tool's pattern is rewritten, so every byte
    outside the version — comments, other plugins, other properties, ordering,
    trailing whitespace — is carried through untouched by construction.
    """
    t = tool(name)
    find_pin(text, name)  # raises unless there is exactly one place to edit
    return t.pattern.sub(
        lambda m: f"{m.group(1)}{version}{m.group(3)}", text, count=1
    )


def read_pin_file(repo_root: Path, name: str) -> str:
    path = repo_root / tool(name).pin_file
    if not path.is_file():
        raise CheckError(f"missing {path} (a toolchain source of truth)")
    return path.read_text(encoding="utf-8")


def read_pin(repo_root: Path, name: str) -> str:
    """The version `name` is pinned to in this checkout."""
    return find_pin(read_pin_file(repo_root, name), name, tool(name).pin_file)


def other_tools_in(name: str) -> List[str]:
    """The other tools pinned in the same file as `name`.

    `agp` and `kotlin` answer each other here; `gradle` answers nothing. This is
    what lets the diff guard say "the AGP updater moved the Kotlin pin" instead
    of the vaguer "something else in the file changed".
    """
    pin_file = tool(name).pin_file
    return [
        other
        for other in TOOL_NAMES
        if other != name and TOOLS[other].pin_file == pin_file
    ]


# -----------------------------------------------------------------------------
# CLI: read one pin out of one file.
# -----------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Print the version one file pins for one toolchain tool.",
    )
    parser.add_argument("--tool", required=True, choices=TOOL_NAMES)
    parser.add_argument(
        "--file",
        help="Read this file instead of the pin file in --repo-root.",
    )
    parser.add_argument(
        "--repo-root",
        help="Repository root holding the pin files (default: this checkout).",
    )
    args = parser.parse_args(argv)

    try:
        if args.file:
            path = Path(args.file)
            if not path.is_file():
                raise CheckError(f"no such file: {path}")
            print(find_pin(path.read_text(encoding="utf-8"), args.tool, str(path)))
        else:
            root = (
                Path(args.repo_root)
                if args.repo_root
                else Path(__file__).resolve().parent.parent
            )
            print(read_pin(root, args.tool))
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
