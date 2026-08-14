#!/usr/bin/env python3
"""check_flutter_sdk_update.py — is a newer Flutter stable SDK available?

This is the detection half of the Flutter SDK updater (issue #362). It answers
one question and stops there:

    Is the SDK pinned in .flutter-version still the newest stable Flutter, and
    if not, is the gap a patch, a minor or a major?

It changes nothing. It writes no file in the repository, creates no commit and
talks to no part of GitHub. Publishing is
.github/workflows/flutter-sdk-updates.yml's job; this script only classifies,
so the classification can be tested offline against fixtures
(test/tooling/flutter_sdk_update_guardrails_test.dart) instead of being buried
in YAML.

Where the release data comes from
---------------------------------

The official Flutter release manifest:

    https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json

That is the same `flutter_infra_release` bucket the archive page publishes and
the same one scripts/setup_flutter.sh downloads the pinned SDK from, so the
version this script proposes is by construction a version the setup path can
actually install. No third-party API, no scraped page, no HTML.

The manifest looks like:

    {
      "base_url": "...",
      "current_release": {"stable": "<hash>", "beta": "...", "dev": "..."},
      "releases": [
        {"hash": "...", "channel": "stable", "version": "...",
         "archive": "stable/linux/flutter_linux_<version>-stable.tar.xz", ...},
        ...
      ]
    }

Which release counts as "the newest stable"
-------------------------------------------

A release is a candidate only if all three hold:

  1. `channel` is exactly "stable" — beta, dev and master are ignored, and so
     are the `-0.N.pre` pre-release builds that ride the beta channel;
  2. `version` is a bare `MAJOR.MINOR.PATCH` — this drops the historical
     `v1.12.13+hotfix.9` / `v1.5.4-hotfix.2` style entries, which are the only
     stable rows that are not plain triples and are all far below any version
     this repo could be pinned to;
  3. `archive`, when present, lives under `stable/`.

The newest candidate is the one with the highest (major, minor, patch). The
manifest's own `current_release.stable` hash is resolved too and reported as
`pointer_version`, purely as a cross-check: if it disagrees with the highest
candidate the disagreement is printed, and the highest version still wins, so
the answer never depends on how the array happens to be ordered.

Classification
--------------

    CURRENT == LATEST                       -> up-to-date
    same major, same minor, higher patch    -> patch
    same major, higher minor                -> minor
    higher major                            -> major

Anything else is an error, not a guess. A malformed pin, a malformed manifest,
a manifest with no usable stable release, or a LATEST that is *older* than
CURRENT all exit 2 with a message. In particular the updater must never
propose a downgrade, so "the newest stable is behind our pin" is a hard
failure rather than a silent no-op.

Usage
-----

    # The scheduled check: read .flutter-version, fetch the official manifest.
    python3 scripts/check_flutter_sdk_update.py

    # Offline, against a saved manifest, for a specific pin:
    python3 scripts/check_flutter_sdk_update.py \\
        --current 1.2.3 --releases-file /path/to/releases_linux.json

    # Classify two versions directly, with no manifest at all. The workflow
    # uses this to compare the version already on its update branch against
    # the version it is about to propose.
    python3 scripts/check_flutter_sdk_update.py --current 1.2.3 --latest 1.2.4

    # Machine-readable output for the workflow.
    python3 scripts/check_flutter_sdk_update.py --github-output "$GITHUB_OUTPUT"
    python3 scripts/check_flutter_sdk_update.py --json

Exit status: 0 when a classification was produced (including "up-to-date"),
2 when the input could not be trusted.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# The official manifest. Linux is the right list for CI and for
# scripts/setup_flutter.sh's default platform; the version/channel data in the
# macOS and Windows manifests is the same set of releases.
DEFAULT_RELEASES_URL = (
    "https://storage.googleapis.com/flutter_infra_release/releases/"
    "releases_linux.json"
)

# A stable Flutter version is a bare triple. Nothing else is accepted, from the
# manifest or from .flutter-version — test/tooling/toolchain_pins_test.dart
# already enforces the same shape on the pin file.
_VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")

_STABLE_CHANNEL = "stable"
_ARCHIVE_PREFIX = "stable/"

_FETCH_TIMEOUT_SECONDS = 30

STATUS_UP_TO_DATE = "up-to-date"
STATUS_PATCH = "patch"
STATUS_MINOR = "minor"
STATUS_MAJOR = "major"


class CheckError(Exception):
    """Input that cannot be trusted. Always fatal — never worked around."""


Version = Tuple[int, int, int]


def parse_version(text: Any, what: str) -> Version:
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


def format_version(version: Version) -> str:
    return "{}.{}.{}".format(*version)


def classify(current: Version, latest: Version) -> str:
    """Classify the gap between the pinned and the newest stable version.

    Raises CheckError when `latest` is older than `current`: an automatic
    update must never propose a downgrade, and a manifest that says the newest
    stable is behind our pin is data we do not understand.
    """
    if latest == current:
        return STATUS_UP_TO_DATE
    if latest < current:
        raise CheckError(
            "the newest stable release ({}) is older than the pinned version "
            "({}). Refusing to propose a downgrade — check "
            ".flutter-version and the release manifest.".format(
                format_version(latest), format_version(current)
            )
        )
    if latest[0] > current[0]:
        return STATUS_MAJOR
    if latest[1] > current[1]:
        return STATUS_MINOR
    return STATUS_PATCH


def read_pin(repo_root: Path) -> str:
    """Read the Flutter pin, the repository's source of truth."""
    pin_file = repo_root / ".flutter-version"
    if not pin_file.is_file():
        raise CheckError(f"missing {pin_file} (the pinned Flutter version)")
    return pin_file.read_text(encoding="utf-8").strip()


def load_manifest(
    releases_file: Optional[str], releases_url: str
) -> Dict[str, Any]:
    """Load the release manifest from a file or the official URL."""
    if releases_file is not None:
        path = Path(releases_file)
        if not path.is_file():
            raise CheckError(f"release manifest not found: {path}")
        raw = path.read_text(encoding="utf-8")
        origin = str(path)
    else:
        if not releases_url.startswith("https://"):
            raise CheckError(
                f"refusing to fetch the release manifest over {releases_url!r}"
                " — https is required"
            )
        try:
            with urllib.request.urlopen(
                releases_url, timeout=_FETCH_TIMEOUT_SECONDS
            ) as response:
                raw = response.read().decode("utf-8")
        except Exception as error:  # network, TLS, HTTP status, decoding
            raise CheckError(
                f"could not fetch the Flutter release manifest from "
                f"{releases_url}: {error}"
            ) from error
        origin = releases_url

    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as error:
        raise CheckError(f"{origin} is not valid JSON: {error}") from error
    if not isinstance(manifest, dict):
        raise CheckError(f"{origin} is not a JSON object")
    manifest["_origin"] = origin
    return manifest


class StableSet:
    """The stable releases a manifest offers, and what was left out of them."""

    def __init__(
        self,
        candidates: List[Tuple[Version, Dict[str, Any]]],
        skipped: List[str],
        notes: List[str],
    ) -> None:
        self.candidates = candidates
        # Entries correctly left out by the channel/shape filter. Routine —
        # every manifest has some — so they are counted, not shouted about.
        self.skipped = skipped
        # Things that were *not* expected and a human may want to look at.
        self.notes = notes


def stable_releases(manifest: Dict[str, Any]) -> StableSet:
    """Return the usable stable releases.

    Filtering entries out is normal: every beta/dev build, and the handful of
    legacy `+hotfix.N` stable tags that are not comparable triples. A
    *structurally* wrong manifest is not normal, and raises instead.
    """
    origin = manifest.get("_origin", "the release manifest")
    releases = manifest.get("releases")
    if not isinstance(releases, list):
        raise CheckError(f"{origin} has no `releases` array")
    if not releases:
        raise CheckError(f"{origin} lists no releases at all")

    candidates: List[Tuple[Version, Dict[str, Any]]] = []
    skipped: List[str] = []
    notes: List[str] = []
    for index, release in enumerate(releases):
        if not isinstance(release, dict):
            raise CheckError(
                f"{origin} entry #{index} is not an object: {release!r}"
            )
        channel = release.get("channel")
        version_text = release.get("version")
        if channel != _STABLE_CHANNEL:
            continue
        try:
            version = parse_version(version_text, f"entry #{index}")
        except CheckError as error:
            skipped.append(str(error))
            continue
        archive = release.get("archive")
        if isinstance(archive, str) and not archive.startswith(_ARCHIVE_PREFIX):
            # A stable row whose archive is not under stable/ contradicts
            # itself. Never a candidate, and worth surfacing.
            notes.append(
                f"entry #{index} claims channel {_STABLE_CHANNEL} but its "
                f"archive is not under {_ARCHIVE_PREFIX}: {archive!r}"
            )
            continue
        candidates.append((version, release))

    if not candidates:
        raise CheckError(
            f"{origin} contains no usable `{_STABLE_CHANNEL}` release "
            "(nothing matched channel + MAJOR.MINOR.PATCH + stable archive)"
        )
    return StableSet(candidates, skipped, notes)


def newest_stable(
    stable: StableSet, manifest: Dict[str, Any]
) -> Tuple[Version, Dict[str, Any], str]:
    """The highest-versioned stable release.

    Returns `(version, release, pointer_version)`, where `pointer_version` is
    the version `current_release.stable` resolves to, or `""` when it resolves
    to nothing. Any disagreement is appended to `stable.notes`.
    """
    # max() on the (major, minor, patch) tuple; ties keep the first entry, so
    # the result never depends on the array's order.
    version, release = max(stable.candidates, key=lambda item: item[0])

    # Cross-check against the manifest's own stable pointer. It is advisory:
    # the highest version wins either way, but a disagreement is worth seeing.
    current_release = manifest.get("current_release")
    pointer_version = ""
    if isinstance(current_release, dict):
        pointer_hash = current_release.get(_STABLE_CHANNEL)
        if isinstance(pointer_hash, str) and pointer_hash:
            for candidate_version, candidate in stable.candidates:
                if candidate.get("hash") == pointer_hash:
                    pointer_version = format_version(candidate_version)
                    break
            if not pointer_version:
                stable.notes.append(
                    "current_release.stable points at hash "
                    f"{pointer_hash}, which is not a usable stable release"
                )
            elif pointer_version != format_version(version):
                stable.notes.append(
                    f"current_release.stable points at {pointer_version} but "
                    f"{format_version(version)} is the highest stable version; "
                    "using the highest version"
                )
    return version, release, pointer_version


def newest_in_major(stable: StableSet, major: int) -> str:
    """Highest stable version sharing `major`, or "" — informational only."""
    same = [version for version, _ in stable.candidates if version[0] == major]
    return format_version(max(same)) if same else ""


def build_result(args: argparse.Namespace, repo_root: Path) -> Dict[str, str]:
    if args.current is not None:
        current = parse_version(args.current, "--current")
    else:
        current = parse_version(read_pin(repo_root), ".flutter-version")

    if args.latest is not None:
        # Classification only: no manifest is consulted, so nothing here can
        # claim the target was confirmed to exist on the stable channel.
        latest = parse_version(args.latest, "--latest")
        return {
            "status": classify(current, latest),
            "current": format_version(current),
            "latest": format_version(latest),
            "stable_confirmed": "false",
            "source": "--latest",
            "latest_hash": "",
            "latest_release_date": "",
            "latest_archive": "",
            "latest_in_current_major": "",
            "pointer_version": "",
            "stable_releases_considered": "0",
            "notes": "",
        }

    manifest = load_manifest(args.releases_file, args.releases_url)
    stable = stable_releases(manifest)
    latest, release, pointer = newest_stable(stable, manifest)
    status = classify(current, latest)
    return {
        "status": status,
        "current": format_version(current),
        "latest": format_version(latest),
        # The target came out of the stable-channel filter above, so reaching
        # here *is* the confirmation that it exists on Flutter stable.
        "stable_confirmed": "true",
        "source": str(manifest.get("_origin", "")),
        "latest_hash": str(release.get("hash") or ""),
        "latest_release_date": str(release.get("release_date") or ""),
        "latest_archive": str(release.get("archive") or ""),
        "latest_in_current_major": newest_in_major(stable, current[0]),
        "pointer_version": pointer,
        "stable_releases_considered": str(len(stable.candidates)),
        "notes": " | ".join(stable.notes),
    }


def report(result: Dict[str, str]) -> None:
    status = result["status"]
    if status == STATUS_UP_TO_DATE:
        print(
            f"Up to date: the pinned {result['current']} is the newest "
            "release on the stable channel."
        )
    else:
        print(
            f"A {status} stable SDK update is available: "
            f"{result['current']} -> {result['latest']}"
        )
        if result["latest_release_date"]:
            print(f"  released: {result['latest_release_date']}")
        if result["latest_archive"]:
            print(f"  archive:  {result['latest_archive']}")
    if result["stable_releases_considered"] != "0":
        print(
            f"  considered {result['stable_releases_considered']} stable "
            f"release(s) from {result['source']}"
        )
    if result["notes"]:
        for note in result["notes"].split(" | "):
            print(f"  note: {note}")


def write_github_output(path: str, result: Dict[str, str]) -> None:
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in result.items():
            if "\n" in value:
                raise CheckError(f"output {key} contains a newline: {value!r}")
            handle.write(f"{key}={value}\n")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Detect a newer Flutter stable SDK than the pinned one.",
    )
    parser.add_argument(
        "--current",
        help="Version to compare against (default: read .flutter-version).",
    )
    parser.add_argument(
        "--latest",
        help="Classify against this version directly, consulting no manifest.",
    )
    parser.add_argument(
        "--releases-file",
        help="Read the release manifest from this file instead of the network.",
    )
    parser.add_argument(
        "--releases-url",
        default=DEFAULT_RELEASES_URL,
        help="Official release manifest URL (default: %(default)s).",
    )
    parser.add_argument(
        "--repo-root",
        help="Repository root holding .flutter-version (default: this checkout).",
    )
    parser.add_argument(
        "--github-output",
        help="Append key=value lines for GitHub Actions to this file.",
    )
    parser.add_argument(
        "--json", action="store_true", help="Print the result as JSON."
    )
    parser.add_argument(
        "--quiet", action="store_true", help="Suppress the human-readable report."
    )
    args = parser.parse_args(argv)

    if args.latest is not None and args.releases_file is not None:
        parser.error("--latest and --releases-file are mutually exclusive")

    repo_root = (
        Path(args.repo_root)
        if args.repo_root
        else Path(__file__).resolve().parent.parent
    )

    try:
        result = build_result(args, repo_root)
        if args.github_output:
            write_github_output(args.github_output, result)
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif not args.quiet:
        report(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
