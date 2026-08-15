#!/usr/bin/env python3
"""check_android_toolchain_update.py — are newer Gradle / AGP / Kotlin releases
available than the ones Linthra pins?

This is the detection half of the Android toolchain updater (issue #362, the
fifth and last phase). It answers one question per tool and stops there:

    Is the version pinned in the repository still the newest stable release in
    its own major line — and, separately, has a newer major line appeared?

It changes nothing. It writes no file in the repository, creates no commit and
talks to no part of GitHub. Publishing is
.github/workflows/android-toolchain-updates.yml's job; this script only
classifies, so the classification can be tested offline against fixtures
(test/tooling/android_toolchain_update_guardrails_test.dart and
test/tooling/android_toolchain_update_test.py) instead of being buried in YAML.

The two answers are deliberately independent
--------------------------------------------

For each tool the script reports *both*:

  * `latest_in_current_major` — the newest stable release that still shares the
    pinned major. This is the only version an automatic PR may ever propose.
  * `latest` — the newest stable release overall, and `major_status` when that
    release is on a newer major than the pin.

Keeping them apart is the point. If the pin is on 8.x and upstream has both a
newer 8.x and a 9.0.0, the newer 8.x still deserves its ordinary draft PR, and
the 9.0.0 independently deserves its own migration issue. Collapsing the two
into a single "how far behind are we" number is what would make a new major
silently swallow every later patch on the line we actually ship.

Where the release data comes from
---------------------------------

Official, machine-readable, first-party. No HTML is fetched or scraped, and no
third-party version API is consulted.

  gradle   https://services.gradle.org/versions/all

           Gradle's own release index, served by the same services.gradle.org
           that android/gradle/wrapper/gradle-wrapper.properties downloads the
           distribution from. Each entry carries explicit `final`, `snapshot`,
           `nightly`, `releaseNightly`, `activeRc`, `rcFor`, `milestoneFor` and
           `broken` flags, so "is this a finished release" is upstream's own
           statement rather than something inferred from a version string.

  agp      https://dl.google.com/dl/android/maven2/
             com/android/tools/build/gradle/maven-metadata.xml

           Maven metadata for the Android Gradle Plugin on Google's Maven
           repository. That is the artifact the `com.android.application`
           plugin id resolves to, served by the `google()` repository already
           declared in android/settings.gradle's pluginManagement block.

  kotlin   https://repo1.maven.org/maven2/
             org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml

           Maven metadata for the Kotlin Gradle plugin on Maven Central — the
           artifact the `org.jetbrains.kotlin.android` plugin id resolves to,
           served by the `mavenCentral()` repository in the same block.

So in each case the index consulted here is the index Gradle itself would
resolve the pin from, which is what makes a proposed version installable by
construction rather than by hope.

Which releases count
--------------------

A release is a candidate only if it is a bare `MAJOR.MINOR.PATCH`. That is the
shape test/tooling/toolchain_pins_test.dart requires of all three pin files, so
it is the only shape an automatic update may write into one. It also does the
prerelease filtering structurally: `8.13.0-alpha01`, `2.4.20-RC`,
`2.2.20-Beta1`, `9.0.0-milestone-1`, `-rc-1`, `-SNAPSHOT` and every other
non-final build carries a suffix and is therefore not a triple. Gradle's
historical two-component tags are excluded by the same rule — a pin file may
not hold one.

On top of that, Gradle entries must be `final`, not `broken`, not a snapshot /
nightly / release-nightly / active RC / milestone, and must download from
`https://services.gradle.org/distributions/`. Maven metadata must actually
declare the group and artifact that was asked for.

Failing safe
------------

Anything that cannot be trusted is an error, not a guess, and an error stops
the whole run rather than letting two tools publish while a third is broken:

  * a pin that is not a bare triple;
  * an index that is not valid JSON / XML, or is not the document it should be;
  * an index with no usable stable release at all;
  * an index whose newest release is *older* than the pin — an automatic update
    must never propose a downgrade, so that is a hard failure, not a no-op;
  * an index that lists no release at all on the pinned major line, which means
    it is not describing the tool we think it is.

Classification, per tool, against the newest release in the pinned major:

    CURRENT == LATEST-IN-MAJOR                 -> up-to-date
    same major, same minor, higher patch       -> patch
    same major, higher minor                   -> minor

and separately, `major_status` is `available` when the newest release overall
is on a higher major. A major never produces a pin change here or anywhere
downstream.

Usage
-----

    # The scheduled check: read all three pins, fetch all three indexes.
    python3 scripts/check_android_toolchain_update.py

    # One tool, offline, against saved index data:
    python3 scripts/check_android_toolchain_update.py --tool gradle \\
        --current 1.2.3 --versions-file /path/to/versions.json

    # All three, offline (repeatable, TOOL=PATH form):
    python3 scripts/check_android_toolchain_update.py \\
        --versions-file gradle=/tmp/g.json --versions-file agp=/tmp/a.xml \\
        --versions-file kotlin=/tmp/k.xml

    # Classify two versions directly, consulting no index at all. The workflow
    # uses this to compare the version already on an update branch against the
    # version it is about to propose.
    python3 scripts/check_android_toolchain_update.py --tool agp \\
        --current 1.2.3 --latest 1.2.4

    # Machine-readable output for the workflow.
    python3 scripts/check_android_toolchain_update.py --github-output "$GITHUB_OUTPUT"
    python3 scripts/check_android_toolchain_update.py --json

Exit status: 0 when every requested tool was classified (including
"up-to-date"), 2 when any input could not be trusted.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
import xml.etree.ElementTree as ElementTree
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from toolchain_pins import (
    TOOL_NAMES,
    CheckError,
    Version,
    format_version,
    looks_like_prerelease,
    parse_version,
    read_pin,
    tool,
    try_version,
)

_FETCH_TIMEOUT_SECONDS = 30

# An index this size is already far past anything upstream publishes; refusing
# to read further is cheaper than trusting a body that grew unexpectedly.
_MAX_INDEX_BYTES = 16 * 1024 * 1024

STATUS_UP_TO_DATE = "up-to-date"
STATUS_PATCH = "patch"
STATUS_MINOR = "minor"
STATUS_MAJOR = "major"

MAJOR_NONE = "none"
MAJOR_AVAILABLE = "available"

_GRADLE_DISTRIBUTION_PREFIX = "https://services.gradle.org/distributions/"

# The upstream index for each tool. `format` selects the parser below.
SOURCES: Dict[str, Dict[str, str]] = {
    "gradle": {
        "url": "https://services.gradle.org/versions/all",
        "format": "gradle-versions",
    },
    "agp": {
        "url": (
            "https://dl.google.com/dl/android/maven2/"
            "com/android/tools/build/gradle/maven-metadata.xml"
        ),
        "format": "maven-metadata",
        "group_id": "com.android.tools.build",
        "artifact_id": "gradle",
    },
    "kotlin": {
        "url": (
            "https://repo1.maven.org/maven2/"
            "org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml"
        ),
        "format": "maven-metadata",
        "group_id": "org.jetbrains.kotlin",
        "artifact_id": "kotlin-gradle-plugin",
    },
}


class Candidates:
    """The stable releases an index offers, and what was left out of them."""

    def __init__(self) -> None:
        self.versions: List[Version] = []
        # Rejected because they are recognisably prereleases. Routine — every
        # index is full of them — so they are counted, not shouted about.
        self.prereleases = 0
        # Rejected for any other reason: a legacy two-component tag, a build
        # marked broken, a distribution served from somewhere unexpected.
        self.malformed = 0
        # Things that were *not* expected and a human may want to look at.
        self.notes: List[str] = []


# -----------------------------------------------------------------------------
# Fetching
# -----------------------------------------------------------------------------


def load_index(url: str, path: Optional[str]) -> Tuple[str, str]:
    """Return `(raw_text, origin)` for an index, from a file or over https."""
    if path is not None:
        file = Path(path)
        if not file.is_file():
            raise CheckError(f"release index not found: {file}")
        return file.read_text(encoding="utf-8"), str(file)

    if not url.startswith("https://"):
        raise CheckError(
            f"refusing to fetch a release index over {url!r} — https is required"
        )
    try:
        with urllib.request.urlopen(url, timeout=_FETCH_TIMEOUT_SECONDS) as response:
            raw = response.read(_MAX_INDEX_BYTES + 1)
    except Exception as error:  # network, TLS, HTTP status
        raise CheckError(f"could not fetch the release index from {url}: {error}") from error
    if len(raw) > _MAX_INDEX_BYTES:
        raise CheckError(
            f"{url} returned more than {_MAX_INDEX_BYTES} bytes; refusing to parse it"
        )
    try:
        return raw.decode("utf-8"), url
    except UnicodeDecodeError as error:
        raise CheckError(f"{url} is not valid UTF-8: {error}") from error


# -----------------------------------------------------------------------------
# Parsers
# -----------------------------------------------------------------------------


def parse_gradle_versions(raw: str, origin: str) -> Candidates:
    """Candidates from Gradle's own release index.

    Upstream states outright whether a build is finished, so that statement is
    what gets trusted: `final` must be exactly true, and every "this is not a
    release" flag must be clear. The version shape is checked as well, which is
    what drops the historical two-component tags (`8.14`) — a pin file may only
    hold a bare triple.
    """
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        raise CheckError(f"{origin} is not valid JSON: {error}") from error
    if not isinstance(payload, list):
        raise CheckError(f"{origin} is not a JSON array of releases")
    if not payload:
        raise CheckError(f"{origin} lists no releases at all")

    found = Candidates()
    for index, entry in enumerate(payload):
        if not isinstance(entry, dict):
            raise CheckError(f"{origin} entry #{index} is not an object: {entry!r}")

        version_text = entry.get("version")

        # Upstream's own verdict first. Everything that is not a finished
        # release — snapshots, nightlies, RCs, milestones — says so here.
        #
        # Which bucket a skipped row lands in is reporting only, and for Gradle
        # the flags are a better witness than the version string: a
        # release-nightly's version is a bare timestamp with no marker in it,
        # but the row itself says plainly what it is.
        if entry.get("final") is not True:
            flagged = any(
                entry.get(flag)
                for flag in (
                    "snapshot",
                    "nightly",
                    "releaseNightly",
                    "activeRc",
                    "rcFor",
                    "milestoneFor",
                )
            )
            if flagged or looks_like_prerelease(version_text):
                found.prereleases += 1
            else:
                found.malformed += 1
            continue

        # `final` is claimed. Every other flag has to agree with it; one that
        # does not means the row contradicts itself, and a self-contradictory
        # row is not something to propose a pin change from.
        contradiction = next(
            (
                flag
                for flag in (
                    "snapshot",
                    "nightly",
                    "releaseNightly",
                    "activeRc",
                    "broken",
                    "rcFor",
                    "milestoneFor",
                )
                if entry.get(flag)
            ),
            None,
        )
        if contradiction is not None:
            found.notes.append(
                f"entry #{index} ({version_text!r}) claims final but "
                f"{contradiction} is set"
            )
            found.malformed += 1
            continue

        version = try_version(version_text)
        if version is None:
            if looks_like_prerelease(version_text):
                found.prereleases += 1
            else:
                found.malformed += 1
            continue

        download = entry.get("downloadUrl")
        if not isinstance(download, str) or not download.startswith(
            _GRADLE_DISTRIBUTION_PREFIX
        ):
            # A final release must be downloadable from the distribution host
            # the wrapper points at. A row that is not names nothing this
            # repository could install, so it is not a version to propose — and
            # it contradicts the `final` claim, so say so rather than counting
            # it quietly.
            found.notes.append(
                f"entry #{index} ({version_text!r}) claims final but its "
                f"downloadUrl is not under {_GRADLE_DISTRIBUTION_PREFIX}: "
                f"{download!r}"
            )
            found.malformed += 1
            continue

        found.versions.append(version)

    return found


def parse_maven_metadata(
    raw: str, origin: str, group_id: str, artifact_id: str
) -> Candidates:
    """Candidates from a Maven `maven-metadata.xml`.

    `<latest>` and `<release>` are deliberately ignored: both routinely name a
    prerelease (Kotlin's `<release>` has pointed at an `-RC` build), so the
    version list is filtered here instead of trusting a pointer.
    """
    # ElementTree resolves entities, so a document declaring any is refused
    # before it is parsed rather than being handed to the parser to expand.
    lowered = raw.lower()
    for hostile in ("<!doctype", "<!entity"):
        if hostile in lowered:
            raise CheckError(
                f"{origin} contains a {hostile[2:]} declaration; refusing to parse it"
            )

    try:
        root = ElementTree.fromstring(raw)
    except ElementTree.ParseError as error:
        raise CheckError(f"{origin} is not valid XML: {error}") from error
    if root.tag != "metadata":
        raise CheckError(f"{origin} is not Maven metadata (root is <{root.tag}>)")

    for field, expected in (("groupId", group_id), ("artifactId", artifact_id)):
        node = root.find(field)
        actual = None if node is None else (node.text or "").strip()
        if actual != expected:
            raise CheckError(
                f"{origin} describes {field} {actual!r}, not {expected!r}; "
                "refusing to read versions out of the wrong artifact"
            )

    versions_node = root.find("versioning/versions")
    if versions_node is None:
        raise CheckError(f"{origin} has no <versioning><versions> element")

    entries = list(versions_node.findall("version"))
    if not entries:
        raise CheckError(f"{origin} lists no versions at all")

    found = Candidates()
    for entry in entries:
        text = (entry.text or "").strip()
        version = try_version(text)
        if version is None:
            if looks_like_prerelease(text):
                found.prereleases += 1
            else:
                found.malformed += 1
            continue
        found.versions.append(version)
    return found


def candidates_for(name: str, raw: str, origin: str) -> Candidates:
    source = SOURCES[name]
    if source["format"] == "gradle-versions":
        found = parse_gradle_versions(raw, origin)
    else:
        found = parse_maven_metadata(
            raw, origin, source["group_id"], source["artifact_id"]
        )
    if not found.versions:
        raise CheckError(
            f"{origin} contains no usable stable release for {tool(name).label} "
            "(nothing matched a bare MAJOR.MINOR.PATCH release)"
        )
    return found


# -----------------------------------------------------------------------------
# Classification
# -----------------------------------------------------------------------------


def classify(current: Version, latest: Version) -> str:
    """Classify the gap between a pinned and a candidate version.

    Raises CheckError when `latest` is older than `current`: an automatic
    update must never propose a downgrade, and an index that says the newest
    release is behind our pin is data we do not understand.
    """
    if latest == current:
        return STATUS_UP_TO_DATE
    if latest < current:
        raise CheckError(
            "the newest stable release ({}) is older than the pinned version "
            "({}). Refusing to propose a downgrade — check the pin and the "
            "upstream release index.".format(
                format_version(latest), format_version(current)
            )
        )
    if latest[0] > current[0]:
        return STATUS_MAJOR
    if latest[1] > current[1]:
        return STATUS_MINOR
    return STATUS_PATCH


def evaluate(name: str, current: Version, found: Candidates, origin: str) -> Dict[str, str]:
    """Everything the workflow needs to know about one tool."""
    t = tool(name)

    latest = max(found.versions)
    if latest < current:
        raise CheckError(
            "{}: the newest stable release ({}) is older than the pinned "
            "version ({}). Refusing to propose a downgrade.".format(
                t.label, format_version(latest), format_version(current)
            )
        )

    in_major = [v for v in found.versions if v[0] == current[0]]
    if not in_major:
        # Our own major line is missing from the index entirely. That is not a
        # tool that dropped a line — it is an index that is not describing the
        # tool we think it is, and acting on it would be acting on data we
        # cannot read.
        raise CheckError(
            "{}: {} lists no stable release on the pinned major line ({}.x). "
            "Refusing to act on an index that does not describe the pinned "
            "tool.".format(t.label, origin, current[0])
        )

    newest_in_major = max(in_major)
    status = classify(current, newest_in_major)

    notes = list(found.notes)
    if current not in found.versions:
        # Advisory: the pin still classifies fine against its own major line,
        # but an index that has never heard of the version we ship is worth a
        # human's eye.
        notes.append(
            f"the pinned version {format_version(current)} is not listed in "
            f"{origin}"
        )

    major_available = latest[0] > current[0]
    return {
        "tool": name,
        "label": t.label,
        "pin_file": t.pin_file,
        "source": origin,
        "current": format_version(current),
        "status": status,
        "latest_in_current_major": format_version(newest_in_major),
        "latest": format_version(latest),
        "major_status": MAJOR_AVAILABLE if major_available else MAJOR_NONE,
        "major_latest": format_version(latest) if major_available else "",
        # The target came out of the stable filter above, so reaching here *is*
        # the confirmation that it is a published final release.
        "stable_confirmed": "true",
        "releases_considered": str(len(found.versions)),
        "prereleases_skipped": str(found.prereleases),
        "malformed_skipped": str(found.malformed),
        "notes": " | ".join(notes),
    }


# -----------------------------------------------------------------------------
# Driving it
# -----------------------------------------------------------------------------


def parse_versions_files(values: List[str], tools: List[str]) -> Dict[str, str]:
    """Resolve `--versions-file` arguments to `{tool: path}`."""
    mapping: Dict[str, str] = {}
    for value in values:
        name, separator, path = value.partition("=")
        if not separator:
            if len(tools) != 1:
                raise CheckError(
                    "--versions-file needs the TOOL=PATH form unless exactly "
                    "one --tool was given"
                )
            mapping[tools[0]] = value
            continue
        if name not in SOURCES:
            raise CheckError(
                f"--versions-file names unknown tool {name!r} "
                f"(expected one of {', '.join(TOOL_NAMES)})"
            )
        mapping[name] = path
    return mapping


def build_results(args: argparse.Namespace, repo_root: Path) -> Dict[str, Dict[str, str]]:
    tools: List[str] = [args.tool] if args.tool else list(TOOL_NAMES)

    if args.current is not None and len(tools) != 1:
        raise CheckError("--current applies to a single --tool")
    if args.latest is not None and len(tools) != 1:
        raise CheckError("--latest applies to a single --tool")

    files = parse_versions_files(args.versions_file, tools)

    results: Dict[str, Dict[str, str]] = {}
    for name in tools:
        t = tool(name)
        current_text = args.current if args.current is not None else read_pin(repo_root, name)
        current = parse_version(
            current_text,
            "--current" if args.current is not None else t.pin_file,
        )

        if args.latest is not None:
            # Classification only: no index is consulted, so nothing here may
            # claim the target was confirmed to be a published release.
            latest = parse_version(args.latest, "--latest")
            status = classify(current, latest)
            results[name] = {
                "tool": name,
                "label": t.label,
                "pin_file": t.pin_file,
                "source": "--latest",
                "current": format_version(current),
                "status": status,
                "latest_in_current_major": (
                    format_version(latest) if latest[0] == current[0] else ""
                ),
                "latest": format_version(latest),
                "major_status": (
                    MAJOR_AVAILABLE if latest[0] > current[0] else MAJOR_NONE
                ),
                "major_latest": (
                    format_version(latest) if latest[0] > current[0] else ""
                ),
                "stable_confirmed": "false",
                "releases_considered": "0",
                "prereleases_skipped": "0",
                "malformed_skipped": "0",
                "notes": "",
            }
            continue

        raw, origin = load_index(SOURCES[name]["url"], files.get(name))
        found = candidates_for(name, raw, origin)
        results[name] = evaluate(name, current, found, origin)

    return results


def needs_pr(result: Dict[str, str]) -> bool:
    return result["status"] in (STATUS_PATCH, STATUS_MINOR)


def needs_issue(result: Dict[str, str]) -> bool:
    return result["major_status"] == MAJOR_AVAILABLE


def report(results: Dict[str, Dict[str, str]]) -> None:
    for result in results.values():
        label = result["label"]
        if result["status"] == STATUS_UP_TO_DATE:
            print(
                f"{label}: up to date on {result['current']} — the newest "
                f"release in the current major line."
            )
        else:
            print(
                f"{label}: a {result['status']} update is available: "
                f"{result['current']} -> {result['latest_in_current_major']}"
            )
        if result["major_status"] == MAJOR_AVAILABLE:
            print(
                f"  a newer major exists: {result['major_latest']} — issue "
                "only, never an automatic pin change"
            )
        if result["releases_considered"] != "0":
            print(
                f"  considered {result['releases_considered']} stable "
                f"release(s) from {result['source']}"
            )
            print(
                f"  skipped {result['prereleases_skipped']} prerelease(s) and "
                f"{result['malformed_skipped']} unusable version string(s)"
            )
        if result["notes"]:
            for note in result["notes"].split(" | "):
                print(f"  note: {note}")


def write_github_output(path: str, results: Dict[str, Dict[str, str]]) -> None:
    compact = json.dumps(results, separators=(",", ":"), sort_keys=True)
    pr_tools = json.dumps(
        [name for name, r in results.items() if needs_pr(r)], separators=(",", ":")
    )
    issue_tools = json.dumps(
        [name for name, r in results.items() if needs_issue(r)], separators=(",", ":")
    )
    for value in (compact, pr_tools, issue_tools):
        if "\n" in value:
            raise CheckError(f"output contains a newline: {value!r}")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"results={compact}\n")
        handle.write(f"pr_tools={pr_tools}\n")
        handle.write(f"issue_tools={issue_tools}\n")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Detect newer stable Gradle / AGP / Kotlin releases than the "
            "pinned ones."
        ),
    )
    parser.add_argument(
        "--tool",
        choices=TOOL_NAMES,
        help="Check only this tool (default: all three).",
    )
    parser.add_argument(
        "--current",
        help="Version to compare against (default: read the pin file).",
    )
    parser.add_argument(
        "--latest",
        help="Classify against this version directly, consulting no index.",
    )
    parser.add_argument(
        "--versions-file",
        action="append",
        default=[],
        metavar="[TOOL=]PATH",
        help="Read a release index from this file instead of the network.",
    )
    parser.add_argument(
        "--repo-root",
        help="Repository root holding the pin files (default: this checkout).",
    )
    parser.add_argument(
        "--github-output",
        help="Append key=value lines for GitHub Actions to this file.",
    )
    parser.add_argument("--json", action="store_true", help="Print JSON.")
    parser.add_argument(
        "--quiet", action="store_true", help="Suppress the human-readable report."
    )
    args = parser.parse_args(argv)

    if args.latest is not None and args.versions_file:
        parser.error("--latest and --versions-file are mutually exclusive")

    repo_root = (
        Path(args.repo_root)
        if args.repo_root
        else Path(__file__).resolve().parent.parent
    )

    try:
        results = build_results(args, repo_root)
        if args.github_output:
            write_github_output(args.github_output, results)
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    elif not args.quiet:
        report(results)
    return 0


if __name__ == "__main__":
    sys.exit(main())
