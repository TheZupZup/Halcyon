#!/usr/bin/env python3
"""Build a short, human Reddit announcement from a GitHub Release payload."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

STABLE_TAG_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
BULLET_RE = re.compile(r"^\s*[-*]\s+(.+?)\s*$")
HEADING_RE = re.compile(r"^\s*(#{1,6})\s+(.+?)\s*$")
MARKDOWN_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]+\)")
INLINE_CODE_RE = re.compile(r"`([^`]+)`")
BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
ITALIC_RE = re.compile(r"(?<!\*)\*([^*]+)\*(?!\*)")
MAX_TITLE_CHARS = 300
MAX_BODY_CHARS = 10_000

DEFAULT_VOICE = {
    "subreddit": "Linthra",
    "max_bullets": 5,
    "patch_intro": (
        "Small update this time, but there are a few things in here "
        "I'm really happy with."
    ),
    "feature_intro": (
        "New Linthra update is out, and there are a few things in this one "
        "I'm really happy with."
    ),
    "bullet_lead": "I focused mostly on:",
    "empty_release_note": (
        "I kept this one simple — the full details are in the GitHub release."
    ),
    "closing": (
        "Thanks to everyone testing Linthra and reporting the weird little bugs 😅"
    ),
    "fdroid": "F-Droid will follow once the new build makes its way through their side.",
}


class AnnouncementError(ValueError):
    """Raised when a release cannot safely produce an announcement."""


def load_voice(path: Path | None) -> dict[str, Any]:
    voice = dict(DEFAULT_VOICE)
    if path is None:
        return voice
    with path.open(encoding="utf-8") as handle:
        custom = json.load(handle)
    if not isinstance(custom, dict):
        raise AnnouncementError("voice config must be a JSON object")
    voice.update(custom)
    max_bullets = voice.get("max_bullets")
    if not isinstance(max_bullets, int) or not 1 <= max_bullets <= 10:
        raise AnnouncementError(
            "voice config max_bullets must be an integer from 1 to 10"
        )
    return voice


def parse_stable_version(tag: str) -> tuple[int, int, int]:
    match = STABLE_TAG_RE.fullmatch(tag.strip())
    if match is None:
        raise AnnouncementError(
            f"release tag {tag!r} is not a stable MAJOR.MINOR.PATCH tag"
        )
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def release_is_announceable(release: dict[str, Any]) -> bool:
    if release.get("draft") is True or release.get("prerelease") is True:
        return False
    if not release.get("published_at"):
        return False
    tag = release.get("tag_name")
    return isinstance(tag, str) and STABLE_TAG_RE.fullmatch(tag.strip()) is not None


def clean_markdown(text: str) -> str:
    value = text.strip()
    value = MARKDOWN_LINK_RE.sub(r"\1", value)
    value = INLINE_CODE_RE.sub(r"\1", value)
    value = BOLD_RE.sub(r"\1", value)
    value = ITALIC_RE.sub(r"\1", value)
    value = value.replace("\\_", "_")
    return re.sub(r"\s+", " ", value).strip()


def preferred_section(body: str) -> tuple[list[str], bool]:
    """Return the What's new/Highlights section when one exists."""
    lines = body.splitlines()
    start: int | None = None
    start_level: int | None = None

    for index, raw in enumerate(lines):
        match = HEADING_RE.match(raw)
        if match is None:
            continue
        title = clean_markdown(match.group(2)).lower().replace("’", "'")
        if title in {"what's new", "whats new", "highlights", "what is new"}:
            start = index + 1
            start_level = len(match.group(1))
            break

    if start is None:
        return lines, False

    selected: list[str] = []
    for raw in lines[start:]:
        match = HEADING_RE.match(raw)
        if match is not None and len(match.group(1)) <= (start_level or 6):
            break
        selected.append(raw)
    return selected, True


def _collect_bullets(lines: list[str], max_bullets: int) -> list[str]:
    bullets: list[str] = []
    skip_prefixes = (
        "version:",
        "versionname",
        "versioncode",
        "platform:",
        "application id:",
        "license:",
    )
    for raw in lines:
        match = BULLET_RE.match(raw)
        if match is None:
            continue
        item = clean_markdown(match.group(1))
        if not item or item.lower().startswith(skip_prefixes):
            continue
        if len(item) > 180:
            item = item[:177].rstrip(" ,.;:-") + "…"
        if item not in bullets:
            bullets.append(item)
        if len(bullets) >= max_bullets:
            break
    return bullets


def extract_bullets(body: str, max_bullets: int) -> list[str]:
    section, found_preferred = preferred_section(body)
    bullets = _collect_bullets(section, max_bullets)
    if bullets or found_preferred:
        return bullets
    return _collect_bullets(body.splitlines(), max_bullets)


def _normalise_tag(tag: str) -> str:
    tag = tag.strip()
    return tag if tag.startswith("v") else f"v{tag}"


def build_announcement(
    release: dict[str, Any], voice: dict[str, Any]
) -> dict[str, str]:
    if not release_is_announceable(release):
        raise AnnouncementError(
            "release is a draft, prerelease, unpublished, or unstable tag"
        )

    raw_tag = str(release["tag_name"])
    _, _, patch = parse_stable_version(raw_tag)
    tag = _normalise_tag(raw_tag)

    release_url = release.get("html_url")
    if not isinstance(release_url, str) or not release_url.startswith("https://"):
        raise AnnouncementError("release html_url is missing or invalid")

    title = f"Linthra {tag} is out 🎵"
    if len(title) > MAX_TITLE_CHARS:
        raise AnnouncementError("generated Reddit title exceeds the safe title limit")

    body_text = release.get("body")
    if not isinstance(body_text, str):
        body_text = ""

    bullets = extract_bullets(body_text, int(voice["max_bullets"]))
    intro_key = "patch_intro" if patch > 0 else "feature_intro"

    parts = [str(voice[intro_key]).strip()]
    if bullets:
        parts.extend(
            [
                str(voice["bullet_lead"]).strip(),
                "\n".join(f"- {item}" for item in bullets),
            ]
        )
    else:
        parts.append(str(voice["empty_release_note"]).strip())

    parts.extend(
        [
            str(voice["closing"]).strip(),
            f"GitHub release:\n{release_url}",
            str(voice["fdroid"]).strip(),
        ]
    )
    body = "\n\n".join(part for part in parts if part)

    if len(body) > MAX_BODY_CHARS:
        raise AnnouncementError(
            f"generated Reddit body exceeds the conservative "
            f"{MAX_BODY_CHARS}-character limit"
        )

    return {
        "tag": tag,
        "title": title,
        "body": body,
        "release_url": release_url,
        "subreddit": str(voice["subreddit"]),
    }


def write_outputs(announcement: dict[str, str], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "title.txt").write_text(
        announcement["title"] + "\n", encoding="utf-8"
    )
    (output_dir / "body.md").write_text(announcement["body"] + "\n", encoding="utf-8")
    (output_dir / "announcement.json").write_text(
        json.dumps(announcement, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-json", type=Path, required=True)
    parser.add_argument("--voice-config", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--json", action="store_true", help="print JSON to stdout")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        with args.release_json.open(encoding="utf-8") as handle:
            release = json.load(handle)
        if not isinstance(release, dict):
            raise AnnouncementError("release payload must be a JSON object")
        voice = load_voice(args.voice_config)
        announcement = build_announcement(release, voice)
        if args.output_dir:
            write_outputs(announcement, args.output_dir)
        if args.json:
            print(json.dumps(announcement, ensure_ascii=False))
        return 0
    except (OSError, json.JSONDecodeError, AnnouncementError) as exc:
        print(f"reddit announcement: {exc}", file=sys.stderr)
        if isinstance(exc, AnnouncementError) and str(exc).startswith(
            "release is a draft"
        ):
            return 3
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
