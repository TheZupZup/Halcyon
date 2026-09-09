#!/usr/bin/env python3
"""check_release_metadata_sync.py: one release version, everywhere (#452).

A Linthra release version is written down in five places, and every one of them
is read by something different:

  * pubspec.yaml                      `version: NAME+CODE`, the source of truth
  * lib/core/app_info.dart            what the About screen shows
  * fastlane/.../changelogs/CODE.txt  what Google Play shows
  * metadata/<app-id>.yml             what F-Droid's update checker compares
  * linux/packaging/*.metainfo.xml    what software centres and Flathub show

They drift silently. Nothing fails to build when the AppStream `<release>` entry
still names last month's version: the Flatpak builds, installs and runs, and a
software centre simply tells everyone the wrong thing about what they just
installed. Flathub then carries that listing.

So this script reads all five and reports every disagreement at once, with the
command that fixes them (`scripts/prepare_release_bump.py`, which writes all
five). It is read-only: it never edits a file, never runs git, and makes no
network calls.

Usage
-----

    python3 scripts/check_release_metadata_sync.py
    python3 scripts/check_release_metadata_sync.py --tag v0.2.6
    python3 scripts/check_release_metadata_sync.py --repo-root /path/to/checkout

`--tag` additionally asserts the tag about to be pushed is the one the
repository is prepared for; without it the pubspec version is the reference.
Exit code 0 means everything agrees, 1 means it does not.

The version-to-versionCode encoding and the F-Droid VercodeOperation transform
are imported from prepare_release_bump.py rather than re-implemented, so the
check and the fix can never disagree about the rules.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from prepare_release_bump import (
    VersionError,
    appstream_releases,
    fdroid_current_version_code,
    is_prerelease,
    parse_release_date,
    version_from_tag,
)

APP_ID = "io.github.thezupzup.linthra"

PUBSPEC = Path("pubspec.yaml")
APP_INFO = Path("lib/core/app_info.dart")
FDROID = Path("metadata") / f"{APP_ID}.yml"
METAINFO = Path("linux/packaging") / f"{APP_ID}.metainfo.xml"
FLATPAK_MANIFEST = Path("flatpak") / f"{APP_ID}.yml"

_PUBSPEC_VERSION = re.compile(r"^version:\s*(\S+)\s*$", re.MULTILINE)
_DEV_VERSION_NAME = re.compile(r"_devVersionName\s*=\s*'([^']*)'")
_FDROID_CURRENT_VERSION = re.compile(r"^CurrentVersion:\s*(\S+)\s*$", re.MULTILINE)
_FDROID_CURRENT_CODE = re.compile(r"^CurrentVersionCode:\s*(\d+)\s*$", re.MULTILINE)


def pubspec_version(text):
    """Return (versionName, versionCode) from a pubspec `version:` line."""
    match = _PUBSPEC_VERSION.search(text)
    if match is None:
        raise VersionError("pubspec.yaml has no `version:` line.")
    raw = match.group(1)
    if "+" not in raw:
        raise VersionError(
            'pubspec.yaml version "{}" has no "+versionCode" suffix.'.format(raw)
        )
    name, _, code = raw.partition("+")
    if not code.isdigit():
        raise VersionError(
            'pubspec.yaml versionCode "{}" is not a number.'.format(code)
        )
    return name, int(code)


def _read(root, relative):
    path = root / relative
    if not path.exists():
        return None
    return path.read_text()


def check_app_info(root, version_name):
    text = _read(root, APP_INFO)
    if text is None:
        return ["{} is missing.".format(APP_INFO)]
    match = _DEV_VERSION_NAME.search(text)
    if match is None:
        return ["{} has no _devVersionName declaration.".format(APP_INFO)]
    if match.group(1) != version_name:
        return [
            "{}: _devVersionName is {}, expected {} (the About screen would "
            "show the wrong version).".format(APP_INFO, match.group(1), version_name)
        ]
    return []


def check_changelog(root, version_code):
    relative = Path(
        "fastlane/metadata/android/en-US/changelogs/{}.txt".format(version_code)
    )
    path = root / relative
    if not path.exists():
        return [
            "{} is missing (Play would ship this release with no release "
            "notes).".format(relative)
        ]
    if not path.read_text().strip():
        return ["{} is empty.".format(relative)]
    return []


def check_fdroid(root, version_name, version_code):
    text = _read(root, FDROID)
    if text is None:
        # Not every checkout carries the draft F-Droid entry.
        return []
    problems = []
    current = _FDROID_CURRENT_VERSION.search(text)
    if current is None:
        problems.append("{} has no CurrentVersion line.".format(FDROID))
    elif current.group(1) != version_name:
        problems.append(
            "{}: CurrentVersion is {}, expected {}.".format(
                FDROID, current.group(1), version_name
            )
        )

    code = _FDROID_CURRENT_CODE.search(text)
    expected = fdroid_current_version_code(text, version_code)
    if code is None:
        problems.append("{} has no CurrentVersionCode line.".format(FDROID))
    elif int(code.group(1)) != expected:
        problems.append(
            "{}: CurrentVersionCode is {}, expected {} (versionCode {} through "
            "the declared VercodeOperation).".format(
                FDROID, code.group(1), expected, version_code
            )
        )
    return problems


def check_appstream(root, version_name):
    """The listing half: newest entry first, and it names this release."""
    text = _read(root, METAINFO)
    if text is None:
        return []
    releases = appstream_releases(text)
    if releases is None:
        return ["{} has no <releases> block.".format(METAINFO)]
    if not releases:
        return ["{}: <releases> is empty.".format(METAINFO)]

    problems = []
    seen = set()
    previous_code = None
    for _, attributes in releases:
        version = attributes.get("version")
        if not version:
            problems.append("{}: a <release> entry has no version.".format(METAINFO))
            continue
        if version in seen:
            problems.append("{}: version {} is listed twice.".format(METAINFO, version))
        seen.add(version)

        try:
            _, code = version_from_tag(version)
        except VersionError:
            problems.append(
                "{}: release version {} is not a Linthra release version.".format(
                    METAINFO, version
                )
            )
            continue

        date = attributes.get("date")
        if not date:
            problems.append("{}: release {} has no date.".format(METAINFO, version))
        else:
            try:
                parse_release_date(date)
            except VersionError as err:
                problems.append("{}: release {}: {}".format(METAINFO, version, err))

        # A pre-release offered as the current stable build is how an alpha
        # ends up installed by someone who wanted a release.
        development = attributes.get("type") == "development"
        if is_prerelease(version) and not development:
            problems.append(
                '{}: release {} is a pre-release and needs type="development".'.format(
                    METAINFO, version
                )
            )
        if not is_prerelease(version) and development:
            problems.append(
                "{}: release {} is a stable version but is marked "
                'type="development".'.format(METAINFO, version)
            )

        if previous_code is not None and code >= previous_code:
            problems.append(
                "{}: release {} is listed after a lower version; entries must "
                "be newest first.".format(METAINFO, version)
            )
        previous_code = code

    newest = releases[0][1].get("version")
    if newest != version_name:
        problems.append(
            "{}: newest <release> is {}, expected {} (software centres and "
            "Flathub read this entry).".format(METAINFO, newest, version_name)
        )
    return problems


def check_flatpak_manifest(root, version_name):
    """Guard the day the manifest stops building the working checkout.

    The committed manifest builds `type: dir` — the checkout itself — so its
    source version *is* the pubspec version and cannot drift. A Flathub
    submission manifest (#451) pins Linthra's own git tag instead, and that one
    can point at last month's release while everything else says otherwise. So
    the check is conditional: it only fires once such a source exists.
    """
    text = _read(root, FLATPAK_MANIFEST)
    if text is None:
        return []
    problems = []
    for match in re.finditer(
        r"url:\s*\S*github\.com/TheZupZup/Linthra(?:\.git)?\s*$",
        text,
        flags=re.MULTILINE | re.IGNORECASE,
    ):
        tail = text[match.end() : match.end() + 400]
        tag = re.search(r"^\s*tag:\s*'?\"?(?P<tag>[^'\"\s]+)", tail, re.MULTILINE)
        if tag is None:
            continue
        expected = "v{}".format(version_name)
        if tag.group("tag") not in (expected, version_name):
            problems.append(
                "{}: the Linthra source is pinned to {}, expected {}.".format(
                    FLATPAK_MANIFEST, tag.group("tag"), expected
                )
            )
    return problems


def check(root, tag=None):
    """Return every disagreement found, as user-readable lines."""
    pubspec = _read(root, PUBSPEC)
    if pubspec is None:
        return ["{} is missing; is --repo-root a Linthra checkout?".format(PUBSPEC)]

    version_name, version_code = pubspec_version(pubspec)
    expected_name, expected_code = version_from_tag(version_name)

    problems = []
    if expected_code != version_code:
        problems.append(
            "pubspec.yaml: versionCode is {}, expected {} for version {}.".format(
                version_code, expected_code, version_name
            )
        )
    if tag is not None:
        tag_name, _ = version_from_tag(tag)
        if tag_name != expected_name:
            problems.append(
                "tag {} does not match pubspec version {}.".format(tag, version_name)
            )

    problems += check_app_info(root, version_name)
    problems += check_changelog(root, version_code)
    problems += check_fdroid(root, version_name, version_code)
    problems += check_appstream(root, version_name)
    problems += check_flatpak_manifest(root, version_name)
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Check that pubspec, About screen, Play changelog, F-Droid "
            "metadata and the AppStream listing all name the same release."
        )
    )
    parser.add_argument(
        "--tag",
        default="",
        help="Release tag to check against, e.g. v0.2.6 (default: none).",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repository root (default: the checkout this script lives in).",
    )
    args = parser.parse_args(argv)

    root = args.repo_root.resolve()
    try:
        problems = check(root, args.tag or None)
    except VersionError as err:
        print("ERROR: {}".format(err), file=sys.stderr)
        return 1

    if problems:
        print("ERROR: release metadata disagrees about the version:", file=sys.stderr)
        print(file=sys.stderr)
        for problem in problems:
            print("  - {}".format(problem), file=sys.stderr)
        print(file=sys.stderr)
        print(
            "Fix: python3 scripts/prepare_release_bump.py <version>\n"
            "     writes pubspec, app_info, the Fastlane changelog, the "
            "F-Droid\n"
            "     metadata and the AppStream release entry. Add "
            "--keep-changelog when\n"
            "     the release notes are already written: without it the script\n"
            "     refuses rather than touch them, and the rest of the metadata\n"
            "     stays unfixed.",
            file=sys.stderr,
        )
        return 1

    print("OK: every release surface names the same version.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
