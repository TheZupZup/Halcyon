#!/usr/bin/env python3
"""Classify security-sensitive PR diffs and block a few high-risk additions.

This is intentionally conservative: ordinary UI/tests/docs PRs should pass
without maintainer involvement, while changes that touch trust boundaries are
surfaced for an explicit second review.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    path: str
    reason: str


SENSITIVE_PATH_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"^\.github/(workflows|actions)/"), "CI / GitHub Actions"),
    (re.compile(r"^scripts/"), "repository automation script"),
    (re.compile(r"^(pubspec\.ya?ml|pubspec\.lock)$"), "dependency manifest / lockfile"),
    (re.compile(r"^android/.*(AndroidManifest\.xml|\.gradle(?:\.kts)?|gradle\.properties)$"), "Android permissions / build configuration"),
    (re.compile(r"^linux/.*(CMakeLists\.txt|\.cc|\.cpp|\.c|\.h|\.hpp)$"), "native Linux code / build configuration"),
    (re.compile(r"^lib/.*(?:auth|credential|token|session|secure|secret)", re.I), "authentication / credential handling"),
    (re.compile(r"^lib/.*(?:network|http|client|socket|provider|source)", re.I), "network / provider boundary"),
    (re.compile(r"^lib/.*(?:database|repository|store|storage|persistence|cache)", re.I), "persistent storage"),
)

SENSITIVE_ADDITION_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\b(?:HttpClient|WebSocket|Socket)\b|package:http/|\bhttp\.(?:get|post|put|delete|patch)\b"), "new network-capable code"),
    (re.compile(r"\b(?:SharedPreferences|FlutterSecureStorage|File|Directory|RandomAccessFile)\s*\("), "new local persistence / filesystem access"),
    (re.compile(r"\b(?:writeAsString|writeAsBytes|openWrite|setString|setStringList)\s*\("), "new write-to-disk behavior"),
    (re.compile(r"\b(?:MethodChannel|EventChannel)\s*\("), "new platform channel"),
    (re.compile(r"\b(?:authorization|bearer|access[_-]?token|api[_-]?key|password|credential)\b", re.I), "credential-sensitive logic"),
    (re.compile(r"\b(?:schemaVersion|MigrationStrategy|createIndex|alterTable)\b"), "database schema / migration"),
)

BLOCKED_ADDITION_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bProcess\.(?:run|runSync|start|startSync)\s*\("), "runtime process execution"),
    (re.compile(r"\brunInShell\s*:\s*true\b"), "runtime shell execution"),
    (re.compile(r"(?:import\s+['\"]dart:ffi['\"]|\bDynamicLibrary\.open\s*\()"), "runtime FFI / dynamic library loading"),
    (re.compile(r"\bpull_request_target\s*:"), "pull_request_target workflow trigger"),
    (re.compile(r"\bpermissions\s*:\s*write-all\b"), "GitHub Actions write-all permissions"),
    (re.compile(r"(?:curl|wget)[^\n|]*\|\s*(?:sh|bash)\b|\bbash\s+<\(\s*curl\b|\beval\s+.*\$\(\s*(?:curl|wget)\b"), "download-and-execute shell pattern"),
)


def run_git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def changed_files(base: str, head: str) -> list[str]:
    output = run_git("diff", "--name-only", f"{base}...{head}", "--")
    return [line for line in output.splitlines() if line]


def added_lines(base: str, head: str) -> list[tuple[str, str]]:
    diff = run_git("diff", "--unified=0", "--no-ext-diff", f"{base}...{head}", "--")
    current_path = ""
    additions: list[tuple[str, str]] = []
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_path = line[6:]
            continue
        if line.startswith("+") and not line.startswith("+++") and current_path:
            additions.append((current_path, line[1:]))
    return additions


def dedupe(findings: list[Finding]) -> list[Finding]:
    seen: set[tuple[str, str]] = set()
    result: list[Finding] = []
    for finding in findings:
        key = (finding.path, finding.reason)
        if key not in seen:
            seen.add(key)
            result.append(finding)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args()

    files = changed_files(args.base, args.head)
    additions = added_lines(args.base, args.head)

    sensitive: list[Finding] = []
    blocked: list[Finding] = []

    for path in files:
        for pattern, reason in SENSITIVE_PATH_RULES:
            if pattern.search(path):
                sensitive.append(Finding(path, reason))

    for path, line in additions:
        for pattern, reason in SENSITIVE_ADDITION_RULES:
            if pattern.search(line):
                sensitive.append(Finding(path, reason))
        for pattern, reason in BLOCKED_ADDITION_RULES:
            if pattern.search(line):
                blocked.append(Finding(path, reason))

    sensitive = dedupe(sensitive)
    blocked = dedupe(blocked)

    report_path = Path(args.report)
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
