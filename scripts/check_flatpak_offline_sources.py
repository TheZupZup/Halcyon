#!/usr/bin/env python3
"""Validate the committed inputs that make Linthra's Flatpak build offline."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_RE = re.compile(r"^  ([A-Za-z0-9_]+):$")
REMOTE_DIGEST_TYPES = {"archive", "file"}
NETWORK_GRANT = "--share=network"


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


def _is_remote_url(value: object) -> bool:
    return isinstance(value, str) and value.startswith(("https://", "http://"))


def remote_source_hash_problems(
    sources: object,
    context: str,
) -> list[str]:
    """Require a valid SHA-256 on remote archive/file source mappings."""
    problems: list[str] = []
    if not isinstance(sources, list):
        return [f"{context} sources is not a list"]

    for index, source in enumerate(sources, start=1):
        if not isinstance(source, dict):
            continue
        source_type = source.get("type")
        url = source.get("url")
        if source_type not in REMOTE_DIGEST_TYPES or not _is_remote_url(url):
            continue

        digest = source.get("sha256")
        if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
            problems.append(
                f"{context} remote {source_type} source #{index} is missing a "
                f"valid sha256: {url}"
            )

    return problems


def manifest_network_grant_problems(manifest: str) -> list[str]:
    """Reject build-time network grants while allowing the runtime finish arg."""
    problems: list[str] = []
    in_finish_args = False

    for line_number, line in enumerate(manifest.splitlines(), start=1):
        if line.startswith("finish-args:"):
            in_finish_args = True
            continue
        if in_finish_args and line and not line.startswith(" "):
            in_finish_args = False

        if NETWORK_GRANT in line and not in_finish_args:
            problems.append(
                "generated Flatpak manifest grants build-time network access "
                f"near line {line_number}; {NETWORK_GRANT} is allowed only in "
                "the top-level runtime finish-args"
            )

    return problems


def _yaml_scalar(block: list[str], key: str) -> str | None:
    prefix = f"{key}:"
    for line in block:
        stripped = line.strip()
        if not stripped.startswith(prefix):
            continue
        value = stripped[len(prefix) :].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        return value
    return None


def manifest_remote_source_hash_problems(manifest: str) -> list[str]:
    """Associate every remote YAML archive/file source with its own SHA-256."""
    problems: list[str] = []
    lines = manifest.splitlines()

    for index, line in enumerate(lines):
        stripped = line.strip()
        match = re.fullmatch(r"- type:\s*['\"]?(archive|file)['\"]?", stripped)
        if match is None:
            continue

        source_type = match.group(1)
        indent = len(line) - len(line.lstrip())
        block = [line]

        for peer in lines[index + 1 :]:
            peer_stripped = peer.strip()
            if not peer_stripped:
                block.append(peer)
                continue

            peer_indent = len(peer) - len(peer.lstrip())
            if peer_indent < indent:
                break
            if peer_indent == indent and peer.lstrip().startswith("- "):
                break
            block.append(peer)

        url = _yaml_scalar(block, "url")
        if not _is_remote_url(url):
            continue

        digest = _yaml_scalar(block, "sha256")
        if digest is None or SHA256_RE.fullmatch(digest) is None:
            problems.append(
                "generated Flatpak remote "
                f"{source_type} source near line {index + 1} is missing its own "
                f"valid sha256: {url}"
            )

    return problems


def _json_contains_network_grant(value: Any) -> bool:
    if isinstance(value, str):
        return NETWORK_GRANT in value
    if isinstance(value, list):
        return any(_json_contains_network_grant(item) for item in value)
    if isinstance(value, dict):
        return any(_json_contains_network_grant(item) for item in value.values())
    return False


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

    problems.extend(manifest_network_grant_problems(manifest))
    problems.extend(manifest_remote_source_hash_problems(manifest))

    sdk_modules = sorted((root / "flatpak/generated/modules").glob("flutter-sdk-*.json"))
    if len(sdk_modules) != 1:
        problems.append(
            "expected exactly one generated Flutter SDK module, found "
            f"{len(sdk_modules)}"
        )
    else:
        sdk_path = sdk_modules[0]
        sdk = json.loads(sdk_path.read_text(encoding="utf-8"))
        sdk_sources = sdk.get("sources", [])
        problems.extend(remote_source_hash_problems(sdk_sources, str(sdk_path)))

        if _json_contains_network_grant(sdk):
            problems.append(
                f"{sdk_path} grants build-time network access; generated Flatpak "
                "modules must build without a network grant"
            )

        setup_sources = [
            source
            for source in sdk_sources
            if isinstance(source, dict)
            and source.get("dest-filename") == "setup-flutter.sh"
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

    for module_path in sorted((root / "flatpak/generated/modules").glob("*.json")):
        if sdk_modules and module_path == sdk_modules[0]:
            continue
        module = json.loads(module_path.read_text(encoding="utf-8"))
        if _json_contains_network_grant(module):
            problems.append(
                f"{module_path} grants build-time network access; generated "
                "Flatpak modules must build without a network grant"
            )
        problems.extend(
            remote_source_hash_problems(
                module.get("sources", []) if isinstance(module, dict) else [],
                str(module_path),
            )
        )

    pub_sources_path = root / "flatpak/generated/sources/pubspec.json"
    pub_sources = json.loads(pub_sources_path.read_text(encoding="utf-8"))
    problems.extend(remote_source_hash_problems(pub_sources, str(pub_sources_path)))

    destinations = {
        source["dest"]
        for source in pub_sources
        if isinstance(source, dict) and isinstance(source.get("dest"), str)
    }
    hash_files = {
        source["dest-filename"]
        for source in pub_sources
        if isinstance(source, dict) and isinstance(source.get("dest-filename"), str)
    }

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
