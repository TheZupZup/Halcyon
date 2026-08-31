#!/usr/bin/env python3
"""check_toolchain_pin_diff.py — prove an automatic toolchain update changed
one version number and nothing else.

The content-aware half of the Android toolchain guard (issue #362, PR 5).
scripts/check_dependency_update_files.sh answers "which files moved"; this
script answers the question a filename cannot:

    android/settings.gradle holds *two* pins. Did the AGP updater move the AGP
    version — or did it also, quietly, move Kotlin's, or reword the comment
    above them?

A filename allowlist says "settings.gradle changed" and is satisfied. That is
not good enough for two independent updaters sharing one file, so the boundary
between them is checked against the file's actual before/after text.

How the proof works
-------------------

Not by reading the diff and hoping the interesting hunk was spotted. Instead:

    1. Find the tool's own version in the *before* text and in the *after*
       text. Exactly one match in each; zero or several is a refusal.
    2. Take the *after* text and put the *before* version back into it.
    3. Require the result to equal the *before* text byte for byte.

If anything else moved — the other plugin's version, a comment, whitespace, an
unrelated property, a reordered line — step 3 fails, because putting the old
version back could not possibly reproduce the old file. There is no list of
"things to watch out for" to keep up to date; everything outside that one
capture group is protected by construction.

On top of that the version itself has to be sane: a bare `MAJOR.MINOR.PATCH`,
strictly newer than before, and on the same major. An automatic update never
proposes a downgrade and never crosses a major.

In git mode the changed-file set is checked too, so this one command is enough
to reject an update branch that also touched application code, tests,
`pubspec.yaml`, F-Droid metadata, Fastlane files, release notes, signing
material or a license.

Usage
-----

    # Against the working tree, before the updater commits anything:
    python3 scripts/check_toolchain_pin_diff.py --kind agp --base HEAD

    # Against a real PR diff, in CI:
    python3 scripts/check_toolchain_pin_diff.py --kind agp \\
        --base "$BASE_SHA" --head HEAD

    # Against two files, with no git repository at all (how the tests drive it):
    python3 scripts/check_toolchain_pin_diff.py --kind agp \\
        --before-file old.gradle --after-file new.gradle

Read-only, no network, no secrets. Exit status: 0 the change is within the
boundary, 2 it is not.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

from toolchain_pins import (
    TOOL_NAMES,
    CheckError,
    find_pin,
    format_version,
    other_tools_in,
    parse_version,
    replace_pin,
    tool,
)


def git(repo_root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise CheckError(
            "git {} failed: {}".format(" ".join(args), result.stderr.strip())
        )
    return result.stdout


def changed_files(repo_root: Path, base: str, head: Optional[str]) -> List[str]:
    args = ["diff", "--name-only", base]
    if head is not None:
        args.append(head)
    return [line for line in git(repo_root, *args).splitlines() if line.strip()]


def read_at(repo_root: Path, ref: Optional[str], path: str) -> str:
    """The contents of `path` at `ref`, or in the working tree when ref is None."""
    if ref is None:
        file = repo_root / path
        if not file.is_file():
            raise CheckError(f"missing {path} in the working tree")
        return file.read_text(encoding="utf-8")
    return git(repo_root, "show", f"{ref}:{path}")


def check_content(kind: str, before: str, after: str, origin: str) -> str:
    """The heart of the guard. Returns a one-line summary, or raises."""
    t = tool(kind)

    before_text = find_pin(before, kind, f"{origin} (before)")
    after_text = find_pin(after, kind, f"{origin} (after)")

    if before == after:
        return f"{t.label}: {origin} is unchanged."

    # Named separately from the byte comparison below purely for the error
    # message. "the AGP update also moved the Kotlin pin" is a far more useful
    # failure than "something outside the AGP version changed".
    for other in other_tools_in(kind):
        other_before = find_pin(before, other, f"{origin} (before)")
        other_after = find_pin(after, other, f"{origin} (after)")
        if other_before != other_after:
            raise CheckError(
                f"this is an automatic {t.label} update, but it also moves the "
                f"{tool(other).label} pin in {origin} "
                f"({other_before} -> {other_after}). The two updaters share "
                "this file and must never write each other's version — that "
                "upgrade belongs in its own PR."
            )

    # Put the old version back. If the result is not the old file, something
    # outside this tool's version changed.
    restored = replace_pin(after, kind, before_text)
    if restored != before:
        raise CheckError(
            f"this is an automatic {t.label} update, but {origin} differs from "
            "its previous contents by more than "
            f"{t.describe}. An automatic update may rewrite that one version "
            "string and nothing else — not comments, not whitespace, not any "
            "other setting in the same file."
        )

    before_version = parse_version(before_text, f"{origin} (before)")
    after_version = parse_version(after_text, f"{origin} (after)")

    if after_version < before_version:
        raise CheckError(
            f"refusing a downgrade of {t.label}: "
            f"{format_version(before_version)} -> {format_version(after_version)}. "
            "An automatic update never proposes a downgrade."
        )
    if after_version[0] != before_version[0]:
        raise CheckError(
            f"this {t.label} change crosses a major version: "
            f"{format_version(before_version)} -> {format_version(after_version)}. "
            "A major toolchain upgrade is a manual migration (#362) and gets "
            "an issue, never an automatic pin change."
        )

    return (
        f"OK: automatic {t.label} update moves {format_version(before_version)} "
        f"-> {format_version(after_version)} in {origin}, and changes nothing else."
    )


def check_git(repo_root: Path, kind: str, base: str, head: Optional[str]) -> str:
    t = tool(kind)
    paths = changed_files(repo_root, base, head)
    if not paths:
        return f"{t.label}: no files changed; nothing to check."

    offenders = [path for path in paths if path != t.pin_file]
    if offenders:
        raise CheckError(
            "this looks like an automatic {} update, but it changes files "
            "outside the one it owns:\n{}\n\nAn automatic {} update may only "
            "rewrite:\n  - {}\n\nIt must not touch application or test code, "
            "pubspec.yaml, pubspec.lock, the app version, F-Droid metadata, "
            "Fastlane files, release notes, signing material, licenses, or "
            "another tool's pin.".format(
                t.label,
                "\n".join(f"  - {path}" for path in offenders),
                t.label,
                t.pin_file,
            )
        )

    return check_content(
        kind,
        read_at(repo_root, base, t.pin_file),
        read_at(repo_root, head, t.pin_file),
        t.pin_file,
    )


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Assert an automatic toolchain update rewrote one version string "
            "and nothing else."
        ),
    )
    parser.add_argument("--kind", required=True, choices=TOOL_NAMES)
    parser.add_argument(
        "--base", help="Compare against this git ref (the PR base, or HEAD)."
    )
    parser.add_argument(
        "--head",
        help="The other side of the comparison (default: the working tree).",
    )
    parser.add_argument("--before-file", help="File holding the previous contents.")
    parser.add_argument("--after-file", help="File holding the new contents.")
    parser.add_argument(
        "--repo-root",
        help="Repository root for git mode (default: this checkout).",
    )
    args = parser.parse_args(argv)

    file_mode = args.before_file is not None or args.after_file is not None
    if file_mode:
        if args.base is not None or args.head is not None:
            parser.error(
                "--before-file/--after-file cannot be combined with --base/--head"
            )
        if args.before_file is None or args.after_file is None:
            parser.error("--before-file and --after-file must be given together")
    elif args.base is None:
        parser.error("give either --base (git mode) or --before-file/--after-file")

    try:
        if file_mode:
            before = Path(args.before_file)
            after = Path(args.after_file)
            for file in (before, after):
                if not file.is_file():
                    raise CheckError(f"no such file: {file}")
            summary = check_content(
                args.kind,
                before.read_text(encoding="utf-8"),
                after.read_text(encoding="utf-8"),
                tool(args.kind).pin_file,
            )
        else:
            repo_root = (
                Path(args.repo_root)
                if args.repo_root
                else Path(__file__).resolve().parent.parent
            )
            summary = check_git(repo_root, args.kind, args.base, args.head)
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
