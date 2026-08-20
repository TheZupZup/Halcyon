#!/usr/bin/env python3
"""Classify security-sensitive PR diffs and block a few high-risk additions.

This is intentionally conservative: ordinary UI/tests/docs PRs should pass
without maintainer involvement, while changes that touch trust boundaries are
surfaced for an explicit second review.

Every ambiguity is resolved in the fail-closed direction. If git metadata is
missing, if a diff header cannot be parsed, or if the scanner cannot complete,
it exits non-zero rather than reporting an ordinary-risk diff.
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


# Attributed to added lines whose file header could not be decoded. Scanning
# still happens; the unresolved path itself is reported as sensitive so that a
# parser failure can never downgrade a diff to "ordinary risk".
UNKNOWN_PATH = "<unresolved diff path>"


SENSITIVE_PATH_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"^\.github/(workflows|actions)/"), "CI / GitHub Actions"),
    (re.compile(r"^scripts/"), "repository automation script"),
    (re.compile(r"^(pubspec\.ya?ml|pubspec\.lock)$"), "dependency manifest / lockfile"),
    (re.compile(r"^android/.*(AndroidManifest\.xml|\.gradle(?:\.kts)?|gradle\.properties)$"), "Android permissions / build configuration"),
    (re.compile(r"^linux/.*(CMakeLists\.txt|\.cc|\.cpp|\.c|\.h|\.hpp)$"), "native Linux code / build configuration"),
    (re.compile(r"^lib/.*(?:auth|credential|token|session|secure|secret)", re.I), "authentication / credential handling"),
    (re.compile(r"^lib/.*(?:network|http|client|socket|provider|source)", re.I), "network / provider boundary"),
    (re.compile(r"^lib/.*(?:database|repository|store|storage|persistence|cache)", re.I), "persistent storage"),
    # `.gitattributes` can change how git renders a diff (for example marking a
    # path `-diff`), which is a direct attack on this scanner's input.
    (re.compile(r"(?:^|/)\.gitattributes$"), "git diff / attribute behavior"),
    (re.compile(r"(?:^|/)CODEOWNERS$"), "code ownership / review routing"),
    (re.compile(r"^(?:\.gitmodules|\.github/dependabot\.ya?ml)$"), "supply-chain configuration"),
)

SENSITIVE_ADDITION_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\b(?:HttpClient|WebSocket|Socket)\b|package:http/|\bhttp\.(?:get|post|put|delete|patch)\b"), "new network-capable code"),
    (re.compile(r"\b(?:SharedPreferences|FlutterSecureStorage|File|Directory|RandomAccessFile)\s*\("), "new local persistence / filesystem access"),
    (re.compile(r"\b(?:writeAsString|writeAsBytes|openWrite|setString|setStringList)\s*\("), "new write-to-disk behavior"),
    (re.compile(r"\b(?:MethodChannel|EventChannel)\s*\("), "new platform channel"),
    (re.compile(r"\b(?:authorization|bearer|access[_-]?token|api[_-]?key|password|credential)\b", re.I), "credential-sensitive logic"),
    (re.compile(r"\b(?:schemaVersion|MigrationStrategy|createIndex|alterTable)\b"), "database schema / migration"),
)


def _split_literal(*fragments: str) -> str:
    """Join the fragments of a literal this file must not contain contiguously.

    Blocked rules are matched against every added line of every changed file —
    including the lines of this file and of its tests. Spelling a blocked
    literal out here would make the guard reject any PR that edits its own
    source, so the handful that would otherwise self-match are assembled at
    import time. The compiled pattern is exactly the intended literal;
    `check_pr_security_surface_test.py` asserts both that the assembly is
    complete and that the guard's own sources stay clean.
    """

    return "".join(fragments)


_FFI = _split_literal("f", "fi")
_PR_TARGET_TRIGGER = _split_literal("pull_request", "_target")

# These are matched as *references*, not only as direct call syntax: binding one
# of these APIs to a local and calling it through that name grants exactly the
# same runtime capability as calling it inline, so requiring a following `(`
# would leave a trivial bypass.
BLOCKED_ADDITION_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bProcess\s*\.\s*(?:run|runSync|start|startSync|killPid)\b"), "runtime process execution"),
    (re.compile(rf"""\b{_split_literal("runIn", "Shell")}\b"""), "runtime shell execution"),
    (
        re.compile(
            rf"""['"]dart:{_FFI}['"]"""
            rf"""|package:{_FFI}/"""
            rf"""|\b{_split_literal("Dynamic", "Library")}\b"""
            rf"""|\b{_split_literal("Native", "Api")}\b"""
        ),
        "runtime FFI / dynamic library loading",
    ),
    (re.compile(rf"\b{_PR_TARGET_TRIGGER}\b"), f"{_PR_TARGET_TRIGGER} workflow trigger"),
    (
        re.compile(
            r"""\bpermissions\s*:\s*['"]?write-all\b|^[ \t]*['"]?write-all['"]?[ \t]*$""",
            re.MULTILINE,
        ),
        "GitHub Actions write-all permissions",
    ),
    (
        re.compile(
            r"(?:curl|wget)[^\n|]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|dash|ksh|python3?|perl|ruby|node)\b"
            r"|\b(?:sh|bash|zsh)\s+<\(\s*(?:curl|wget)\b"
            r"|\b(?:sh|bash|zsh)\s+-c\s+['\"]?\$\(\s*(?:curl|wget)\b"
            r"|\beval\s+.*\$\(\s*(?:curl|wget)\b"
        ),
        "download-and-execute shell pattern",
    ),
)


class ScannerError(RuntimeError):
    """Raised when the diff cannot be inspected and the scan must fail closed."""


def run_git(*args: str) -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            check=True,
            # `--text` renders binary blobs inline, so git's output is not
            # guaranteed to be valid UTF-8. Replace undecodable bytes instead of
            # raising: an added image must not crash the scan.
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as error:  # pragma: no cover - environment failure
        raise ScannerError("git executable is not available") from error
    except subprocess.CalledProcessError as error:
        raise ScannerError(
            f"git {' '.join(args)} failed ({error.returncode}): {error.stderr.strip()}"
        ) from error
    return result.stdout


# `git diff` renders the *content* of a diff according to the checked-out
# `.gitattributes`, and quotes unusual pathnames. Both are contributor
# controlled, so pin the rendering explicitly:
#   core.quotePath=false  keep non-ASCII paths literal
#   --text                a `-diff` attribute cannot hide added lines
#   --no-textconv         no attribute-selected content transformation
#   --no-ext-diff         no external diff driver
#   --no-renames          a rename shows both paths and re-adds the content
#   --src-prefix/--dst-prefix   header prefixes are never config dependent
DIFF_FLAGS: tuple[str, ...] = (
    "--no-ext-diff",
    "--no-textconv",
    "--no-renames",
    "--text",
    "--src-prefix=a/",
    "--dst-prefix=b/",
)

GIT_CONFIG_FLAGS: tuple[str, ...] = ("-c", "core.quotePath=false")


_C_ESCAPES = {
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    '"': '"',
    "\\": "\\",
}


def unquote_git_path(value: str) -> str:
    """Decode a C-quoted pathname as emitted by git.

    `core.quotePath=false` stops git escaping non-ASCII bytes, but a path that
    contains a quote, backslash, tab or other control character is still
    wrapped and escaped. Decoding it is what keeps an anchored path rule such
    as `^scripts/` from silently failing to match.
    """

    if len(value) < 2 or not value.startswith('"') or not value.endswith('"'):
        return value

    body = value[1:-1]
    decoded = bytearray()
    index = 0
    while index < len(body):
        char = body[index]
        if char != "\\":
            decoded.extend(char.encode("utf-8"))
            index += 1
            continue
        index += 1
        if index >= len(body):
            break
        escape = body[index]
        if escape in _C_ESCAPES:
            decoded.extend(_C_ESCAPES[escape].encode("utf-8"))
            index += 1
        elif escape in "01234567" and len(body) - index >= 3:
            decoded.append(int(body[index : index + 3], 8) & 0xFF)
            index += 3
        else:
            decoded.extend(escape.encode("utf-8"))
            index += 1
    return decoded.decode("utf-8", "replace")


def changed_files(base: str, head: str) -> list[str]:
    output = run_git(
        *GIT_CONFIG_FLAGS,
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        f"{base}...{head}",
        "--",
    )
    # -z keeps pathnames raw, so no unquoting is needed here.
    return [path for path in output.split("\0") if path]


def _header_path(rest: str) -> str | None:
    """Resolve the destination path from a `+++ ` diff header."""

    path = unquote_git_path(rest.strip())
    if path == "/dev/null":
        return None
    if path.startswith("b/"):
        return path[2:]
    return None


def added_lines(base: str, head: str) -> list[tuple[str, str]]:
    diff = run_git(
        *GIT_CONFIG_FLAGS,
        "diff",
        "--unified=0",
        *DIFF_FLAGS,
        f"{base}...{head}",
        "--",
    )

    current_path: str | None = None
    in_hunk = False
    additions: list[tuple[str, str]] = []

    # Split on "\n" only. `str.splitlines()` also breaks on \x0b, \x0c and
    # \u2028, which Dart accepts as whitespace *inside* an expression, so a
    # contributor could otherwise split a blocked pattern across two "lines"
    # that neither half matches.
    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            current_path = None
            in_hunk = False
            continue
        if line.startswith("@@"):
            # Everything after the first hunk header belongs to file content,
            # so an added line that itself begins with "++ " is never mistaken
            # for a `+++ ` file header.
            in_hunk = True
            continue
        if not in_hunk:
            if line.startswith("+++ "):
                current_path = _header_path(line[4:])
            continue
        if line.startswith("+"):
            additions.append((current_path or UNKNOWN_PATH, line[1:]))

    return additions


_SHELL_LINE_CONTINUATION = re.compile(r"\\\n[ \t]*")
_SHELL_PIPE_CONTINUATION = re.compile(r"\|[ \t]*\n[ \t]*")


def fold_continuations(text: str) -> str:
    """Rejoin shell line continuations inside a block of added lines.

    A trailing backslash, or a trailing pipe, carries one shell command onto the
    next line. The download-and-execute rule deliberately refuses to match
    across a newline — otherwise an unrelated interpreter invocation far below a
    download would trip it — so a genuine continuation has to be folded away
    before that rule runs.
    """

    text = _SHELL_LINE_CONTINUATION.sub(" ", text)
    return _SHELL_PIPE_CONTINUATION.sub("| ", text)


def group_additions(additions: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Collapse a file's added lines into one block of text to scan.

    Rules are applied to the block rather than to each line on its own, because
    the constructs they describe do not have to sit on one physical line. Dart
    accepts a newline anywhere between tokens, so `Process` and `.run(...)` can
    be split across two added lines — and, with `--unified=0`, across two hunks
    with an untouched blank line or comment between them. Joining every added
    line of a file leaves nowhere for a blocked construct to hide.
    """

    blocks: dict[str, list[str]] = {}
    for path, line in additions:
        blocks.setdefault(path, []).append(line)
    return [(path, fold_continuations("\n".join(lines))) for path, lines in blocks.items()]


def dedupe(findings: list[Finding]) -> list[Finding]:
    seen: set[tuple[str, str]] = set()
    result: list[Finding] = []
    for finding in findings:
        key = (finding.path, finding.reason)
        if key not in seen:
            seen.add(key)
            result.append(finding)
    return result


def classify(files: list[str], additions: list[tuple[str, str]]) -> tuple[list[Finding], list[Finding]]:
    sensitive: list[Finding] = []
    blocked: list[Finding] = []

    for path in files:
        for pattern, reason in SENSITIVE_PATH_RULES:
            if pattern.search(path):
                sensitive.append(Finding(path, reason))

    for path, block in group_additions(additions):
        if path == UNKNOWN_PATH:
            sensitive.append(
                Finding(UNKNOWN_PATH, "diff header could not be decoded; review manually")
            )
        for pattern, reason in SENSITIVE_ADDITION_RULES:
            if pattern.search(block):
                sensitive.append(Finding(path, reason))
        for pattern, reason in BLOCKED_ADDITION_RULES:
            if pattern.search(block):
                blocked.append(Finding(path, reason))

    return dedupe(sensitive), dedupe(blocked)


def write_report(report_path: Path, files: list[str], sensitive: list[Finding], blocked: list[Finding]) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open("w", encoding="utf-8") as report:
        report.write("## PR security surface scan\n\n")
        report.write(f"Changed files: **{len(files)}**\n\n")
        if blocked:
            report.write("### Blocked high-risk additions\n\n")
            for finding in blocked:
                report.write(f"- `{finding.path}` — {finding.reason}\n")
            report.write("\nThese patterns require redesign or a separate maintainer-controlled implementation; an approval does not bypass them.\n\n")
        if sensitive:
            report.write("### Sensitive surfaces requiring maintainer review\n\n")
            for finding in sensitive:
                report.write(f"- `{finding.path}` — {finding.reason}\n")
        else:
            report.write("No security-sensitive trust boundary was detected in this diff.\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)

    try:
        files = changed_files(args.base, args.head)
        additions = added_lines(args.base, args.head)
    except ScannerError as error:
        print(f"::error::PR security surface scan could not inspect the diff: {error}", file=sys.stderr)
        return 2

    sensitive, blocked = classify(files, additions)

    write_report(Path(args.report), files, sensitive, blocked)

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            output.write(f"sensitive={'true' if sensitive else 'false'}\n")
            output.write(f"blocked={'true' if blocked else 'false'}\n")

    if blocked:
        print("PR security scan blocked high-risk additions:")
        for finding in blocked:
            print(f"  {finding.path}: {finding.reason}")
        return 1

    if sensitive:
        print("Security-sensitive PR surface detected; maintainer review required.")
    else:
        print("PR security surface scan passed: ordinary-risk diff.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
