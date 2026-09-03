#!/usr/bin/env python3
"""Validate the committed inputs that make Linthra's Flatpak build offline."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_RE = re.compile(r"^  ([A-Za-z0-9_]+):$")


def _read(root: Path, path: str) -> str:
    return (root / path).read_text(encoding="utf-8")


def hosted_packages(lockfile: str) -> dict[str, str]:
    """Return hosted package versions from pubspec.lock without a YAML dependency."""
    result: dict[str, str] = {}
    current: str | None = None
    version: str | None = None
    hosted = False
    in_packages = False

    def flush() -> None:
        if current is not None and hosted and version is not None:
            result[current] = version

    for line in lockfile.splitlines():
        if not in_packages:
            if line == "packages:":
                in_packages = True
            continue

        if line and not line.startswith(" "):
            break

        match = PACKAGE_RE.fullmatch(line)
        if match:
            flush()
            current = match.group(1)
            version = None
            hosted = False
            continue

        if current is None:
            continue

        stripped = line.strip()
        if stripped == "source: hosted":
            hosted = True
        elif stripped.startswith("version:"):
            version = stripped.split(":", 1)[1].strip().strip("\"'")

    flush()
    return result


def check(root: Path) -> list[str]:
    problems: list[str] = []

    template = _read(root, "flatpak/flatpak-flutter.yml")
    manifest = _read(root, "flatpak/io.github.thezupzup.linthra.yml")
    cmake = _read(root, "linux/CMakeLists.txt")
    lockfile = _read(root, "pubspec.lock")

    if "flutter pub get --enforce-lockfile" not in template:
        problems.append(
            "flatpak template no longer resolves the committed lockfile with "
            "--enforce-lockfile"
        )
    if "flutter build linux --release --no-pub" not in template:
        problems.append("flatpak template Linux build is missing --no-pub")

    if "      - setup-flutter.sh" not in manifest:
        problems.append("generated Flatpak manifest no longer runs setup-flutter.sh")
    if "      - flutter build linux --release --no-pub" not in manifest:
        problems.append("generated Flatpak Linux build is missing --no-pub")

    try:
        linthra_module = manifest.split("  - name: linthra\n", 1)[1]
        build_options = linthra_module.split("    build-commands:\n", 1)[0]
    except IndexError:
        problems.append("generated Flatpak manifest has no parseable linthra module")
    else:
        if "--share=network" in build_options:
            problems.append(
                "linthra Flatpak build-options grants network access; runtime "
                "--share=network must not leak into the build sandbox"
            )

    sdk_modules = sorted((root / "flatpak/generated/modules").glob("flutter-sdk-*.json"))
    if len(sdk_modules) != 1:
        problems.append(
            "expected exactly one generated Flutter SDK module, found "
            f"{len(sdk_modules)}"
        )
    else:
        sdk = json.loads(sdk_modules[0].read_text(encoding="utf-8"))
        setup_sources = [
            source
            for source in sdk.get("sources", [])
            if source.get("dest-filename") == "setup-flutter.sh"
        ]
        if len(setup_sources) != 1:
            problems.append(
                "generated Flutter SDK module must declare exactly one "
                "setup-flutter.sh source"
            )
        elif "flutter pub get --offline $@" not in setup_sources[0].get(
            "commands", []
        ):
            problems.append("setup-flutter.sh no longer runs flutter pub get --offline")

    pub_sources_path = root / "flatpak/generated/sources/pubspec.json"
    pub_sources = json.loads(pub_sources_path.read_text(encoding="utf-8"))
    destinations = {
        source["dest"]
        for source in pub_sources
        if isinstance(source, dict) and isinstance(source.get("dest"), str)
    }
    hash_files = {
        source["dest-filename"]
        for source in pub_sources
        if isinstance(source, dict)
        and isinstance(source.get("dest-filename"), str)
    }

    for source in pub_sources:
        if not isinstance(source, dict) or source.get("type") != "archive":
            continue
        digest = source.get("sha256")
        if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
            problems.append(
                "generated pub source archive is missing a valid sha256: "
                f"{source.get('url', '<no url>')}"
            )

    for package, version in hosted_packages(lockfile).items():
        basename = f"{package}-{version}"
        destination = f".pub-cache/hosted/pub.dev/{basename}"
        if destination not in destinations:
            problems.append(
                f"hosted lockfile package {basename} is not predeclared in "
                "flatpak/generated/sources/pubspec.json"
            )
        if f"{basename}.sha256" not in hash_files:
            problems.append(
                f"hosted lockfile package {basename} has no generated hosted hash"
            )

    if "FETCHCONTENT_SOURCE_DIR_SQLITE3" not in cmake:
        problems.append("Linux CMake lost the pre-fetched SQLite FetchContent seam")
    if "MIMALLOC_USE_STATIC_LIBS OFF" not in cmake:
        problems.append("Linux CMake no longer disables media_kit's mimalloc fetch")

    pub_sources_text = pub_sources_path.read_text(encoding="utf-8")
    if "sqlite-autoconf-" not in pub_sources_text:
        problems.append("generated Flatpak sources no longer predeclare SQLite")
    if "mimalloc-" not in pub_sources_text:
        problems.append("generated Flatpak sources no longer carry the mimalloc input")

    lines = manifest.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "- type: archive":
            continue
        block = lines[index : min(index + 8, len(lines))]
        if not any(item.strip().startswith("sha256:") for item in block):
            problems.append(
                "generated Flatpak archive source near line "
                f"{index + 1} has no nearby sha256"
            )

    return problems


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    problems = check(root)
    if problems:
        print("Flatpak offline-source check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("Flatpak offline-source check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
