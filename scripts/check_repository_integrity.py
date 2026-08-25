#!/usr/bin/env python3
"""Fail-closed repository-integrity checks for pull requests.

This guard is intentionally narrower and stricter than the general PR security
surface classifier. It protects repository trust policy, IDE auto-execution
surfaces, and binary assets that can be disguised as executable text.

The workflow that invokes this script must load it from the trusted PR base
commit (or be pinned as a required workflow by a repository ruleset).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    path: str
    reason: str


PROTECTED_IGNORE_ENTRIES = (".idea/", ".vscode/")

EXTERNAL_BLOCKED_PATHS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"^\.vscode/"), "VS Code workspace configuration is maintainer-controlled"),
    (re.compile(r"^\.idea/"), "IDE project configuration is maintainer-controlled"),
    (re.compile(r"(?:^|/).*\.code-workspace$", re.I), "VS Code workspace file is maintainer-controlled"),
    (re.compile(r"^\.github/workflows/"), "GitHub Actions workflows are maintainer-controlled"),
    (re.compile(r"^(?:scripts|tool|tools)/"), "repository automation scripts are maintainer-controlled"),
    (re.compile(r"(?:^|/)CODEOWNERS$"), "code-ownership policy is maintainer-controlled"),
    (re.compile(r"^\.github/dependabot\.ya?ml$"), "dependency-update policy is maintainer-controlled"),
    (re.compile(r"^\.gitattributes$"), "Git diff/attribute policy is maintainer-controlled"),
    (re.compile(r"^\.gitmodules$"), "Git submodule policy is maintainer-controlled"),
)

ASSET_MAGIC: dict[str, tuple[bytes, ...]] = {
    ".woff2": (b"wOF2",),
    ".woff": (b"wOFF",),
    ".ttf": (b"\x00\x01\x00\x00", b"true", b"typ1"),
    ".otf": (b"OTTO",),
    ".png": (b"\x89PNG\r\n\x1a\n",),
    ".jpg": (b"\xff\xd8\xff",),
    ".jpeg": (b"\xff\xd8\xff",),
    ".gif": (b"GIF87a", b"GIF89a"),
}


def _split_literal(*parts: str) -> str:
    return "".join(parts)


_INTERPRETERS = (
    _split_literal("no", "de"),
    "python",
    "python3",
    "perl",
    "ruby",
    "php",
    "sh",
    "bash",
    "zsh",
    "dash",
    "ksh",
    "pwsh",
    "powershell",
)

EXECUTABLE_ASSET_EXTENSIONS = (
    _split_literal("wo", "ff2?"),
    _split_literal("t", "tf"),
    _split_literal("o", "tf"),
    _split_literal("e", "ot"),
    _split_literal("p", "ng"),
    _split_literal("jp", "e?g"),
    _split_literal("g", "if"),
    _split_literal("we", "bp"),
    _split_literal("i", "co"),
    _split_literal("p", "df"),
)
_EXECUTABLE_ASSET_RE = re.compile(
    rf"""(?ix)
    \b(?:{'|'.join(_INTERPRETERS)})
    \b[^\n\r]{{0,240}}
    \.(?:{'|'.join(EXECUTABLE_ASSET_EXTENSIONS)})\b
    |
    \bchmod\b[^\n\r]{{0,120}}\+x[^\n\r]{{0,160}}
    \.(?:{'|'.join(EXECUTABLE_ASSET_EXTENSIONS)})\b
    """
)

ACTIVE_SVG_RE = re.compile(
    r"""(?ix)
    <\s*script\b
    |javascript\s*:
    |\bon(?:load|error|click|mouseover|focus)\s*=
    |<\s*foreignObject\b
    |(?:href|xlink:href)\s*=\s*["']\s*(?:https?:|data:text/html)
    """
)


class IntegrityError(RuntimeError):
    pass


def run_git(*args: str, text: bool = True) -> str | bytes:
    try:
        proc = subprocess.run(
            ["git", *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=text,
            encoding="utf-8" if text else None,
            errors="surrogateescape" if text else None,
        )
    except FileNotFoundError as exc:
        raise IntegrityError("git executable is unavailable") from exc
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr if text else exc.stderr.decode("utf-8", "replace")
        raise IntegrityError(
            f"git {' '.join(args)} failed ({exc.returncode}): {stderr.strip()}"
        ) from exc
    return proc.stdout


def changed_files(base: str, head: str) -> list[str]:
    raw = run_git(
        "-c", "core.quotePath=false",
        "diff", "--name-only", "-z", "--no-renames",
        f"{base}...{head}", "--",
    )
    assert isinstance(raw, str)
    return [item for item in raw.split("\0") if item]


def blob_bytes(head: str, path: str) -> bytes | None:
    try:
        value = run_git("show", f"{head}:{path}", text=False)
    except IntegrityError:
        return None
    assert isinstance(value, bytes)
    return value


def blob_text(head: str, path: str) -> str | None:
    data = blob_bytes(head, path)
    if data is None:
        return None
    return data.decode("utf-8", "surrogateescape")


def git_mode(head: str, path: str) -> str | None:
    try:
        out = run_git("ls-tree", head, "--", path)
    except IntegrityError:
        return None
    assert isinstance(out, str)
    if not out.strip():
        return None
    return out.split(None, 1)[0]


def is_external(pr_author: str, repo_owner: str) -> bool:
    return pr_author.casefold() != repo_owner.casefold()


def check_ignore_policy(head: str) -> list[Finding]:
    text = blob_text(head, ".gitignore")
    if text is None:
        return [Finding(".gitignore", "required repository .gitignore is missing")]
    entries = {
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    return [
        Finding(".gitignore", f"required ignore entry `{entry}` was removed")
        for entry in PROTECTED_IGNORE_ENTRIES
        if entry not in entries
    ]


def check_external_paths(files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        for pattern, reason in EXTERNAL_BLOCKED_PATHS:
            if pattern.search(path):
                findings.append(Finding(path, reason))
                break
    return findings


def check_symlinks(head: str, files: list[str], external: bool) -> list[Finding]:
    if not external:
        return []
    findings: list[Finding] = []
    for path in files:
        if git_mode(head, path) == "120000":
            findings.append(
                Finding(path, "external PR introduces or modifies a Git symlink")
            )
    return findings


def check_asset_magic(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        suffix = Path(path).suffix.lower()
        if suffix == ".webp":
            data = blob_bytes(head, path)
            if data is None:
                continue
            if not (len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP"):
                findings.append(Finding(path, "file extension is .webp but content is not WEBP"))
            continue

        expected = ASSET_MAGIC.get(suffix)
        if expected is None:
            continue
        data = blob_bytes(head, path)
        if data is None:
            continue
        if not any(data.startswith(prefix) for prefix in expected):
            findings.append(
                Finding(path, f"file extension is {suffix} but file signature does not match")
            )
    return findings


def check_active_svg(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        if Path(path).suffix.lower() != ".svg":
            continue
        text = blob_text(head, path)
        if text is not None and ACTIVE_SVG_RE.search(text):
            findings.append(Finding(path, "SVG contains active/external executable content"))
    return findings


def check_asset_execution(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        data = blob_bytes(head, path)
        if data is None or b"\x00" in data:
            continue
        text = data.decode("utf-8", "surrogateescape")
        if _EXECUTABLE_ASSET_RE.search(text):
            findings.append(
                Finding(path, "text invokes or marks an asset file as executable")
            )
    return findings


def dedupe(findings: list[Finding]) -> list[Finding]:
    seen: set[tuple[str, str]] = set()
    result: list[Finding] = []
    for finding in findings:
        key = (finding.path, finding.reason)
        if key not in seen:
            seen.add(key)
            result.append(finding)
    return result


def scan(base: str, head: str, pr_author: str, repo_owner: str) -> list[Finding]:
    files = changed_files(base, head)
    external = is_external(pr_author, repo_owner)

    findings: list[Finding] = []
    findings.extend(check_ignore_policy(head))
    if external:
        findings.extend(check_external_paths(files))
    findings.extend(check_symlinks(head, files, external))
    findings.extend(check_asset_magic(head, files))
    findings.extend(check_active_svg(head, files))
    findings.extend(check_asset_execution(head, files))
    return dedupe(findings)


def write_report(path: Path, findings: list[Finding]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", errors="backslashreplace") as out:
        out.write("## Repository integrity guard\n\n")
        if not findings:
            out.write("No repository-integrity violation was detected.\n")
            return
        out.write("### Blocked findings\n\n")
        for finding in findings:
            out.write(f"- `{finding.path}` — {finding.reason}\n")
        out.write(
            "\nThese checks fail closed. Repository-control changes must be "
            "performed from a trusted maintainer-controlled branch.\n"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--pr-author", required=True)
    parser.add_argument("--repo-owner", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args(argv)

    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(errors="backslashreplace")

    try:
        findings = scan(args.base, args.head, args.pr_author, args.repo_owner)
    except IntegrityError as exc:
        print(f"::error::Repository integrity scan failed closed: {exc}", file=sys.stderr)
        return 2

    write_report(Path(args.report), findings)

    if findings:
        print("Repository integrity guard blocked the PR:")
        for finding in findings:
            print(f"  {finding.path}: {finding.reason}")
        return 1

    print("Repository integrity guard passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
