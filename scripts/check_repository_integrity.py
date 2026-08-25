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
import fnmatch
import html
import re
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    path: str
    reason: str


PROTECTED_IGNORE_ENTRIES = (".idea/", ".vscode/")

# Files that must be able to hold literal attack strings, because they are the
# fixtures this guard is tested against. Only lines carrying the explicit marker
# below are exempted, and only inside these exact paths.
SELF_TEST_FIXTURE_PATHS = frozenset({"test/tooling/check_repository_integrity_test.py"})

FIXTURE_EXEMPTION_MARKER = "integrity-guard-fixture"

_EXTERNAL_BLOCKED_PATHS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"^\.vscode/"), "VS Code workspace configuration is maintainer-controlled"),
    (re.compile(r"^\.idea/"), "IDE project configuration is maintainer-controlled"),
    (re.compile(r"(?:^|/).*\.code-workspace$", re.I), "VS Code workspace file is maintainer-controlled"),
    (re.compile(r"^\.github/workflows/"), "GitHub Actions workflows are maintainer-controlled"),
    (re.compile(r"^\.github/actions/"), "GitHub composite actions are maintainer-controlled"),
    (re.compile(r"^(?:scripts|tool|tools)/"), "repository automation scripts are maintainer-controlled"),
    (re.compile(r"(?:^|/)CODEOWNERS$"), "code-ownership policy is maintainer-controlled"),
    (re.compile(r"^\.github/dependabot\.ya?ml$"), "dependency-update policy is maintainer-controlled"),
    (re.compile(r"^\.gitattributes$"), "Git diff/attribute policy is maintainer-controlled"),
    (re.compile(r"^\.gitmodules$"), "Git submodule policy is maintainer-controlled"),
)

# The self-test paths are maintainer-controlled by construction: an external PR
# cannot add (or mark) a line that the fixture exemption would then skip.
EXTERNAL_BLOCKED_PATHS: tuple[tuple[re.Pattern[str], str], ...] = _EXTERNAL_BLOCKED_PATHS + tuple(
    (
        re.compile(rf"^{re.escape(path)}$"),
        "repository-integrity self-test fixtures are maintainer-controlled",
    )
    for path in sorted(SELF_TEST_FIXTURE_PATHS)
)

def _u16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 2], "big")


def _u32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 4], "big")


# A magic prefix alone is worthless here: `wOF2` followed by JavaScript is still
# four valid bytes. Each validator below checks a self-describing structural
# field — a declared length that must equal the real file size, or a redundant
# field derived from another — so appended or substituted script breaks it.


def _valid_woff(data: bytes, signature: bytes, header_size: int) -> bool:
    """WOFF/WOFF2 declare their own total length and a zeroed reserved field."""
    if len(data) < header_size or not data.startswith(signature):
        return False
    if _u32(data, 8) != len(data):
        return False
    return _u16(data, 12) != 0 and _u16(data, 14) == 0


def _valid_sfnt(data: bytes) -> bool:
    """TrueType/OpenType: searchRange and friends are derived from numTables."""
    if len(data) < 12 or data[:4] not in (b"\x00\x01\x00\x00", b"true", b"typ1", b"OTTO"):
        return False
    num_tables = _u16(data, 4)
    if num_tables == 0 or len(data) < 12 + 16 * num_tables:
        return False
    entry_selector = num_tables.bit_length() - 1
    search_range = (1 << entry_selector) * 16
    return (
        _u16(data, 6) == search_range
        and _u16(data, 8) == entry_selector
        and _u16(data, 10) == num_tables * 16 - search_range
    )


def _valid_png(data: bytes) -> bool:
    """The 8-byte signature must be followed by a well-formed 13-byte IHDR."""
    if len(data) < 33 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return False
    return _u32(data, 8) == 13 and data[12:16] == b"IHDR"


_JPEG_MARKERS = frozenset(range(0xC0, 0xFF)) - {0xD8, 0xD9}


def _valid_jpeg(data: bytes) -> bool:
    if len(data) < 4 or not data.startswith(b"\xff\xd8\xff"):
        return False
    return data[3] in _JPEG_MARKERS and b"\xff\xd9" in data


def _skip_gif_sub_blocks(data: bytes, pos: int) -> int:
    """Walk a chain of length-prefixed sub-blocks; -1 if it runs off the end."""
    while pos < len(data):
        size = data[pos]
        pos += 1
        if size == 0:
            return pos
        pos += size
    return -1


def _valid_gif(data: bytes) -> bool:
    """Walk the whole block structure through to the trailer.

    A header check is not enough: `GIF89a=0;` parses as a header with non-zero
    canvas dimensions *and* as JavaScript. Requiring the block chain to resolve
    exactly onto the trailer leaves no room for a trailing script.
    """
    if len(data) < 14 or data[:6] not in (b"GIF87a", b"GIF89a"):
        return False
    if int.from_bytes(data[6:8], "little") == 0 or int.from_bytes(data[8:10], "little") == 0:
        return False

    flags = data[10]
    pos = 13
    if flags & 0x80:
        pos += 3 * (1 << ((flags & 0x07) + 1))

    while 0 <= pos < len(data):
        block = data[pos]
        pos += 1
        if block == 0x3B:
            return pos == len(data)
        if block == 0x21:
            if pos >= len(data):
                return False
            pos = _skip_gif_sub_blocks(data, pos + 1)
        elif block == 0x2C:
            if pos + 9 > len(data):
                return False
            local = data[pos + 8]
            pos += 9
            if local & 0x80:
                pos += 3 * (1 << ((local & 0x07) + 1))
            if pos >= len(data):
                return False
            pos = _skip_gif_sub_blocks(data, pos + 1)
        else:
            return False
    return False


def _valid_webp(data: bytes) -> bool:
    """Declared RIFF length plus a chunk chain that lands exactly on the end.

    Checking only the fourcc is not enough: the required bytes can be parked
    inside a JavaScript comment (`RIFF/*xxWEBPVP8 */=0;...`). Requiring the
    declared length to match and the chunk walk to consume the file exactly
    removes the space such a payload needs.
    """
    if len(data) < 16 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return False
    if int.from_bytes(data[4:8], "little") != len(data) - 8:
        return False

    pos = 12
    saw_image = False
    while pos + 8 <= len(data):
        fourcc = data[pos : pos + 4]
        if not all(0x20 <= byte <= 0x7E for byte in fourcc):
            return False
        size = int.from_bytes(data[pos + 4 : pos + 8], "little")
        pos += 8 + size + (size & 1)
        if pos > len(data):
            return False
        if fourcc in (b"VP8 ", b"VP8L", b"VP8X"):
            saw_image = True
    return saw_image and pos == len(data)


ASSET_VALIDATORS: dict[str, tuple[str, "Callable[[bytes], bool]"]] = {
    ".woff2": ("WOFF2", lambda data: _valid_woff(data, b"wOF2", 48)),
    ".woff": ("WOFF", lambda data: _valid_woff(data, b"wOFF", 44)),
    ".ttf": ("TrueType", _valid_sfnt),
    ".otf": ("OpenType", _valid_sfnt),
    ".png": ("PNG", _valid_png),
    ".jpg": ("JPEG", _valid_jpeg),
    ".jpeg": ("JPEG", _valid_jpeg),
    ".gif": ("GIF", _valid_gif),
    ".webp": ("WEBP", _valid_webp),
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
    |\bon[a-z][a-z0-9_:-]*\s*=
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


def _ignore_rules(text: str) -> list[str]:
    rules: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rules.append(line[1:] if line.startswith("\\") else line)
    return rules


def _negation_reenables(pattern: str, name: str) -> bool:
    """Whether a `!` rule re-enables `name`, using Git's matching semantics.

    Python's fnmatch has no notion of `**/`, so `!**/.vscode/` — which Git
    applies at every depth including the root — would otherwise slip through.
    """
    pattern = pattern.strip().strip("/")
    if not pattern:
        return False
    candidates = {pattern}
    while pattern.startswith("**/"):
        pattern = pattern[3:]
        candidates.add(pattern)
    return any(fnmatch.fnmatch(name, candidate) for candidate in candidates)


def _ignore_state(rules: list[str], entry: str) -> tuple[bool, str | None]:
    """Resolve whether `entry` ends up ignored, the way Git resolves it.

    Git applies the *last* matching rule, so a later `!.vscode/` re-enables a
    directory an earlier `.vscode/` ignored. Checking only for the presence of
    the positive entry misses that. Negations are matched as globs, since
    `!.vs*` re-enables the directory just as surely as `!.vscode/`.
    """
    name = entry.strip("/")
    ignored = False
    negated_by: str | None = None
    for rule in rules:
        if rule.startswith("!"):
            if _negation_reenables(rule[1:], name):
                ignored = False
                negated_by = rule
        elif rule.strip("/") == name:
            ignored = True
            negated_by = None
    return ignored, negated_by


def check_ignore_policy(head: str) -> list[Finding]:
    text = blob_text(head, ".gitignore")
    if text is None:
        return [Finding(".gitignore", "required repository .gitignore is missing")]
    rules = _ignore_rules(text)

    findings: list[Finding] = []
    for entry in PROTECTED_IGNORE_ENTRIES:
        ignored, negated_by = _ignore_state(rules, entry)
        if ignored:
            continue
        if negated_by is not None:
            findings.append(
                Finding(
                    ".gitignore",
                    f"required ignore entry `{entry}` is re-enabled by `{negated_by}`",
                )
            )
        else:
            findings.append(
                Finding(".gitignore", f"required ignore entry `{entry}` was removed")
            )
    return findings


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
        entry = ASSET_VALIDATORS.get(Path(path).suffix.lower())
        if entry is None:
            continue
        label, is_valid = entry
        data = blob_bytes(head, path)
        if data is None:
            continue
        if data and b"\x00" not in data:
            # Every real asset in these formats carries binary content. A file
            # that is pure text is a polyglot candidate regardless of how well
            # it fakes a header, so reject it before the format check.
            findings.append(
                Finding(path, f"file extension claims {label} but the file is entirely text")
            )
            continue
        if not is_valid(data):
            findings.append(
                Finding(path, f"file extension claims {label} but the file is not a valid {label}")
            )
    return findings


def svg_is_active(text: str) -> bool:
    """Match active content on the raw source and on its decoded form.

    An XML parser resolves character references before acting on an attribute,
    so `java&#x73;cript:` becomes `javascript:` at the point it matters. Scanning
    only raw bytes misses that; scanning both catches the encoded form without
    losing anything the raw scan already caught.
    """
    if ACTIVE_SVG_RE.search(text):
        return True
    decoded = html.unescape(text)
    return decoded != text and bool(ACTIVE_SVG_RE.search(decoded))


def check_active_svg(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        if Path(path).suffix.lower() != ".svg":
            continue
        text = blob_text(head, path)
        if text is not None and svg_is_active(text):
            findings.append(Finding(path, "SVG contains active/external executable content"))
    return findings


def is_exempt_fixture_line(path: str, line: str) -> bool:
    """Report whether a single line opts out of the asset-execution text scan.

    The exemption exists so the guard's own test module can hold the literal
    attack strings it asserts against. It is deliberately narrow: it applies
    only inside `SELF_TEST_FIXTURE_PATHS`, only to individual lines that carry
    the marker, and only to this one check. Every other line of those files is
    scanned normally, and external PRs cannot modify them at all.
    """
    return path in SELF_TEST_FIXTURE_PATHS and FIXTURE_EXEMPTION_MARKER in line


def asset_execution_finding(path: str, text: str) -> Finding | None:
    """Return a finding when `text` invokes or marks an asset as executable.

    Scanning happens line by line on exactly the line separators the pattern
    itself refuses to cross, so this sees what a whole-file search would.
    """
    for line in re.split(r"[\r\n]", text):
        if is_exempt_fixture_line(path, line):
            continue
        if _EXECUTABLE_ASSET_RE.search(line):
            return Finding(path, "text invokes or marks an asset file as executable")
    return None


def check_asset_execution(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        data = blob_bytes(head, path)
        if data is None or b"\x00" in data:
            continue
        finding = asset_execution_finding(path, data.decode("utf-8", "surrogateescape"))
        if finding is not None:
            findings.append(finding)
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
