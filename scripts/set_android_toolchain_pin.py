#!/usr/bin/env python3
"""set_android_toolchain_pin.py — move exactly one Android toolchain pin.

The write half of the Android toolchain updater (issue #362, PR 5). It is the
only script in this repository allowed to change the Gradle, AGP or Kotlin pin,
and the change it makes is deliberately tiny: one version string, in one file,
found by the shared pattern in scripts/toolchain_pins.py, with every other byte
of the file carried through untouched.

    python3 scripts/set_android_toolchain_pin.py --tool agp --version 1.2.3

Doing this in Python rather than with `sed` in the workflow is not ceremony.
`agp` and `kotlin` live in the *same file*, so the edit has to be aimed by
content, not by filename — and the aiming has to be the same aiming
scripts/check_toolchain_pin_diff.py verifies afterwards, or the guard would be
checking something the writer never touches. Sharing one module is what makes
those two agree.

What it refuses
---------------

  * a version that is not a bare MAJOR.MINOR.PATCH;
  * a version that is not strictly newer than the pin — an automatic update
    never proposes a downgrade, and re-writing the same value is a no-op the
    caller should have skipped;
  * a version on a different major — Gradle, AGP and Kotlin majors are all
    manual migrations, and no automatic path may cross one;
  * a pin file that does not contain exactly one place to make the edit.

After writing it reads the file back and confirms the pin is what was asked
for, so the run fails here rather than producing a commit nobody checked.

Exit status: 0 written, 2 refused.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import List, Optional

from toolchain_pins import (
    TOOL_NAMES,
    CheckError,
    find_pin,
    format_version,
    parse_version,
    read_pin_file,
    replace_pin,
    tool,
)


def apply(repo_root: Path, name: str, version_text: str) -> str:
    t = tool(name)
    target = parse_version(version_text, "--version")

    before = read_pin_file(repo_root, name)
    current_text = find_pin(before, name, t.pin_file)
    current = parse_version(current_text, f"{t.pin_file} ({t.label})")

    if target == current:
        raise CheckError(
            f"{t.label} is already pinned to {format_version(current)}; "
            "nothing to write"
        )
    if target < current:
        raise CheckError(
            f"refusing to move {t.label} from {format_version(current)} back "
            f"to {format_version(target)} — an automatic update never proposes "
            "a downgrade"
        )
    if target[0] != current[0]:
        raise CheckError(
            f"refusing to move {t.label} from {format_version(current)} to "
            f"{format_version(target)}: that crosses a major version. A "
            "major toolchain upgrade is a manual migration (#362) and gets an "
            "issue, never an automatic pin change."
        )

    after = replace_pin(before, name, format_version(target))
    if after == before:
        raise CheckError(f"rewriting {t.pin_file} produced no change")

    path = repo_root / t.pin_file
    path.write_text(after, encoding="utf-8")

    # Read it back rather than trusting the write: the guard downstream is
    # worth more if this step has already proven the file says what we meant.
    written = find_pin(path.read_text(encoding="utf-8"), name, t.pin_file)
    if written != format_version(target):
        raise CheckError(
            f"{t.pin_file} reads back as {written!r} after writing "
            f"{format_version(target)!r}"
        )
    return (
        f"{t.label}: {format_version(current)} -> {format_version(target)} "
        f"in {t.pin_file}"
    )


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Set one Android toolchain pin to a newer version.",
    )
    parser.add_argument("--tool", required=True, choices=TOOL_NAMES)
    parser.add_argument("--version", required=True, help="The new version.")
    parser.add_argument(
        "--repo-root",
        help="Repository root holding the pin files (default: this checkout).",
    )
    args = parser.parse_args(argv)

    repo_root = (
        Path(args.repo_root)
        if args.repo_root
        else Path(__file__).resolve().parent.parent
    )

    try:
        print(apply(repo_root, args.tool, args.version))
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
