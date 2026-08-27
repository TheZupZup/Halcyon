#!/usr/bin/env python3
"""Validate a scanner artifact and render the one sticky PR comment.

This program runs only from the trusted default branch. Report fields are data:
they are strictly bounded, escaped, and never evaluated as shell or program text.

The PR this report may address is decided by resolve_repository_integrity_pr.py,
which binds the artifact to the triggering run and to the live pull request. The
resulting binding is what this program validates against, so the two programs
cannot disagree about which PR a report belongs to.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

MARKER = "<!-- linthra-repository-integrity-v1 -->"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SEVERITIES = {"blocked", "review_required"}
FIELDS = ("path", "rule", "reason", "remediation")
MAX_FINDINGS = 100
MAX_FIELD_LENGTH = 2000
# GitHub rejects an issue comment body above this length. The per-field and
# per-count limits are independent and do not bound the total, so a report that
# satisfies both can still render past it; the API call would then fail and
# leave the previous sticky result standing. Findings are rendered against this
# budget and the remainder is disclosed as withheld.
MAX_COMMENT_CHARS = 65_536
_TAIL_RESERVE = 512


def safe_text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > MAX_FIELD_LENGTH:
        raise ValueError(f"invalid {field}")
    # Numeric entities prevent Markdown, raw HTML, mentions, and links while
    # preserving an exact, readable representation of repository data.
    return "".join(ch if ch.isalnum() or ch in " .,_/-:" else f"&#{ord(ch)};" for ch in value)


def validate(payload: object, binding: object) -> tuple[list[dict[str, str | None]], int]:
    """Validate the report against the binding resolve_repository_integrity_pr.py
    established. That program is the sole authority on which PR this report may
    address; this one refuses to render anything that disagrees with it."""
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ValueError("unsupported report schema")
    if not isinstance(binding, dict):
        raise ValueError("invalid report binding")
    expected_pr = binding.get("pr_number")
    expected_sha = binding.get("head_sha")
    expected_repo = binding.get("head_repository")
    if not isinstance(expected_sha, str) or not SHA_RE.fullmatch(expected_sha):
        raise ValueError("invalid head SHA")
    if not isinstance(expected_pr, int) or isinstance(expected_pr, bool) or expected_pr < 1:
        raise ValueError("invalid bound PR number")
    if not isinstance(expected_repo, str) or not expected_repo:
        raise ValueError("invalid bound head repository")
    if payload.get("pr_number") != expected_pr or payload.get("head_sha") != expected_sha or payload.get("head_repository") != expected_repo:
        raise ValueError("report does not match the triggering PR")
    findings = payload.get("findings")
    if not isinstance(findings, list) or len(findings) > MAX_FINDINGS:
        raise ValueError("invalid findings list")
    truncated = payload.get("truncated", 0)
    if not isinstance(truncated, int) or isinstance(truncated, bool) or truncated < 0:
        raise ValueError("invalid truncated count")
    validated: list[dict[str, str | None]] = []
    for raw in findings:
        if not isinstance(raw, dict) or set(raw) != {"severity", "commit", *FIELDS}:
            raise ValueError("invalid finding shape")
        if raw["severity"] not in SEVERITIES:
            raise ValueError("invalid severity")
        commit = raw["commit"]
        if commit is not None and (not isinstance(commit, str) or not SHA_RE.fullmatch(commit)):
            raise ValueError("invalid commit SHA")
        item = {field: safe_text(raw[field], field) for field in FIELDS}
        item.update(severity=raw["severity"], commit=commit)
        validated.append(item)
    return validated, truncated


def render(findings: list[dict[str, str | None]], truncated: int = 0) -> str:
    lines = [MARKER, "## Repository integrity review", ""]
    if not findings:
        return "\n".join(lines + ["**CLEAN**", "", "Previously reported repository-integrity findings are resolved."])
    blocked = any(item["severity"] == "blocked" for item in findings)
    lines += [f"**{'BLOCKED' if blocked else 'REVIEW REQUIRED'}**", "", "Repository integrity blocked this PR." if blocked else "Repository integrity requires explicit maintainer review.", ""]
    budget = MAX_COMMENT_CHARS - _TAIL_RESERVE
    used = sum(len(line) + 1 for line in lines)
    rendered = 0
    for number, item in enumerate(findings, 1):
        block = [f"### Finding {number}"]
        if item["commit"]:
            block.append(f"- **Commit:** `{item['commit']}`")
        block += [
            f"- **Path:** `{item['path']}`",
            f"- **Rule:** `{item['rule']}`",
            f"- **Explanation:** {item['reason']}",
            f"- **How to fix:** {item['remediation']}", "",
        ]
        size = sum(len(line) + 1 for line in block)
        if used + size > budget:
            break
        lines += block
        used += size
        rendered += 1
    truncated += len(findings) - rendered
    if truncated > 0:
        lines.append(f"{truncated} further finding(s) were withheld from this comment. "
                     "The check output lists every finding; all of them block this PR.")
        lines.append("")
    lines.append("This report describes observable repository state and history; it does not infer contributor intent.")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--binding", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.report.stat().st_size > 1_000_000:
        raise ValueError("report exceeds size limit")
    if args.binding.stat().st_size > 4_096:
        raise ValueError("binding exceeds size limit")
    payload = json.loads(args.report.read_text(encoding="utf-8"))
    binding = json.loads(args.binding.read_text(encoding="utf-8"))
    findings, truncated = validate(payload, binding)
    args.output.write_text(render(findings, truncated), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
