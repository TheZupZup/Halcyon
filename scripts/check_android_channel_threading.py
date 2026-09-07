#!/usr/bin/env python3
"""Guard the SAF method-channel threading boundary (#346).

This is a narrow, offline source tripwire, not a Kotlin compiler or a proof of
thread safety. It checks that the expensive walk is evaluated inside the work
lambda submitted to the real background worker, that result encoding stays on
that worker, and that superseding a queued scan keeps working. A token appearing
somewhere in the same method is not enough.

    python3 scripts/check_android_channel_threading.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KOTLIN = (
    ROOT
    / "android"
    / "app"
    / "src"
    / "main"
    / "kotlin"
    / "io"
    / "github"
    / "thezupzup"
    / "linthra"
)
WORKER_FILE = "PlatformChannelWorker.kt"
SCANNER_FILE = "SafDocumentScanner.kt"
SCAN_METHOD = "listAudioDocuments"
SCAN_WORK = "walk"


def read(directory: Path, name: str, failures: list[str]) -> str:
    path = directory / name
    if not path.is_file():
        failures.append(f"{name}: missing (expected at {path})")
        return ""
    return path.read_text(encoding="utf-8")


def code_only(source: str) -> str:
    """Mask comments and Kotlin string/char literals, retaining offsets.

    Braces, parentheses and fake calls inside prose must not affect nesting.
    Kotlin block comments can nest, and triple-quoted strings can contain both
    quotes and braces. This intentionally does not try to parse Kotlin syntax.
    """
    result = list(source)
    i = 0
    n = len(source)

    def mask(start: int, end: int) -> None:
        for j in range(start, end):
            if source[j] not in "\r\n":
                result[j] = " "

    while i < n:
        start = i
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
            mask(start, i)
        elif source.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            mask(start, i)
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            i = n if end < 0 else end + 3
            mask(start, i)
        elif source[i] in ('"', "'"):
            quote = source[i]
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                elif source[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            i = min(i, n)
            mask(start, i)
        else:
            i += 1
    return "".join(result)


def balanced_span(code: str, opening: int) -> tuple[int, int] | None:
    """Return the inside of one balanced pair, using masked source offsets."""
    pairs = {"{": "}", "(": ")"}
    if opening >= len(code) or code[opening] not in pairs:
        return None
    stack = [pairs[code[opening]]]
    for i in range(opening + 1, len(code)):
        char = code[i]
        if char in pairs:
            stack.append(pairs[char])
        elif stack and char == stack[-1]:
            stack.pop()
            if not stack:
                return opening + 1, i
    return None


def function_span(code: str, name: str) -> tuple[int, int] | None:
    match = re.search(rf"\bfun\s+(?:<[^>]*>\s*)?{re.escape(name)}\s*\(", code)
    if match is None:
        return None
    parameters = balanced_span(code, match.end() - 1)
    if parameters is None:
        return None
    opening = code.find("{", parameters[1] + 1)
    return balanced_span(code, opening) if opening >= 0 else None


def call_span(code: str, name: str) -> tuple[int, int] | None:
    pattern = re.escape(name).replace(r"\.", r"\s*\.\s*")
    match = re.search(rf"\b{pattern}\s*\(", code)
    if match is None:
        return None
    return balanced_span(code, match.end() - 1)


def lambda_span(code: str, name: str) -> tuple[int, int] | None:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*\{{", code)
    if match is None:
        return None
    return balanced_span(code, match.end() - 1)


def trailing_lambda_span(code: str, name: str) -> tuple[int, int] | None:
    pattern = re.escape(name).replace(r"\.", r"\s*\.\s*")
    match = re.search(rf"\b{pattern}\s*\{{", code)
    if match is None:
        return None
    return balanced_span(code, match.end() - 1)


def occurrences(code: str, pattern: str) -> list[int]:
    return [match.start() for match in re.finditer(pattern, code)]


def outside(positions: list[int], span: tuple[int, int]) -> bool:
    return any(not (span[0] <= position < span[1]) for position in positions)


def check_worker(directory: Path, failures: list[str]) -> None:
    source = code_only(read(directory, WORKER_FILE, failures))
    if not source:
        return
    if "java.util.concurrent.Executor" not in source:
        failures.append(f"{WORKER_FILE}: no Executor import")
    if not re.search(r"background\s*:\s*Executor\s*=\s*SHARED_BACKGROUND", source):
        failures.append(f"{WORKER_FILE}: production must use the background executor")
    if not re.search(r"Executors\s*\.\s*newSingleThreadExecutor\s*\{", source):
        failures.append(f"{WORKER_FILE}: no real background thread factory")
    span = function_span(source, "submit")
    if span is None:
        failures.append(f"{WORKER_FILE}: no submit() to hand work to")
        return
    body = source[span[0] : span[1]]
    task = trailing_lambda_span(body, "background.execute")
    if task is None:
        failures.append(
            f"{WORKER_FILE}: submit() does not run on the background executor"
        )
        return
    work_calls = occurrences(body, r"\bwork\s*\(\s*\)")
    if not work_calls or outside(work_calls, task):
        failures.append(
            f"{WORKER_FILE}: work() is evaluated outside the background executor"
        )
    for callback in ("onSuccess", "onFailure"):
        calls = occurrences(body, rf"\b{callback}\s*\(")
        if not calls or outside(calls, task):
            failures.append(
                f"{WORKER_FILE}: callbacks must stay inside the background executor "
                "so MethodChannel encoding cannot stall the platform thread"
            )
            break


def check_scanner(directory: Path, failures: list[str]) -> None:
    source = code_only(read(directory, SCANNER_FILE, failures))
    if not source:
        return
    if "PlatformChannelWorker" not in source:
        failures.append(f"{SCANNER_FILE}: does not use PlatformChannelWorker")
    span = function_span(source, SCAN_METHOD)
    if span is None:
        failures.append(f"{SCANNER_FILE}: no {SCAN_METHOD}() to check")
        return
    body = source[span[0] : span[1]]
    submit = call_span(body, "worker.submit")
    if submit is None:
        failures.append(
            f"{SCANNER_FILE}: {SCAN_METHOD}() does not submit its work to the worker"
        )
        return
    arguments = body[submit[0] : submit[1]]
    work = lambda_span(arguments, "work")
    if work is None:
        failures.append(
            f"{SCANNER_FILE}: submitted work must contain the scan invocation"
        )
        return
    work_in_body = (submit[0] + work[0], submit[0] + work[1])
    walk_calls = occurrences(body, rf"\b{re.escape(SCAN_WORK)}\s*\(")
    if not walk_calls or outside(walk_calls, work_in_body):
        failures.append(
            f"{SCANNER_FILE}: {SCAN_WORK}() must be evaluated inside the submitted "
            "work lambda, never eagerly on the platform thread (#346)"
        )
    # A second reply or another submission cannot hide an eager walk.
    if outside(occurrences(body, r"\bresult\s*\.\s*success\s*\("), submit):
        failures.append(f"{SCANNER_FILE}: result.success() must not answer inline")
    if len(occurrences(body, r"\bworker\s*\.\s*submit\s*\(")) != 1:
        failures.append(f"{SCANNER_FILE}: expected exactly one worker submission")


def companion_span(code: str) -> tuple[int, int] | None:
    match = re.search(r"\bcompanion\s+object\s*\{", code)
    if match is None:
        return None
    return balanced_span(code, match.end() - 1)


def check_cancellation(directory: Path, failures: list[str]) -> None:
    """Superseding a queued scan has to keep working, and it fails quietly.

    Two ways to break it that both compile, pass every test, and read like a
    tidy-up in review:

    1. Moving `currentScan` out of the companion object onto the instance. It
       looks like ordinary state, but the thread it frees is process-wide, so an
       instance flag stops cancelling the moment the activity is recreated
       mid-scan and the new scanner comes up holding nothing.
    2. Dropping the `ScanSuperseded` rethrow from the walk's per-folder catch.
       Cancellation is then counted as one unreadable subtree, the walk finishes
       and answers a partial success, and the replacement scan keeps waiting.

    Neither logs anything. The scan just takes as long as the one it replaced.
    """
    source = code_only(read(directory, SCANNER_FILE, failures))
    if not source:
        return

    flag = occurrences(source, r"\bval\s+currentScan\b")
    if not flag:
        failures.append(f"{SCANNER_FILE}: no currentScan flag to supersede a walk")
        return
    companion = companion_span(source)
    if companion is None or outside(flag, companion):
        failures.append(
            f"{SCANNER_FILE}: currentScan must live in the companion object, "
            "process-scoped like the worker thread it frees. An activity "
            "recreated mid-scan otherwise brings up a scanner with an empty flag "
            "and nothing to cancel (#346)"
        )

    walk = function_span(source, SCAN_WORK)
    if walk is None:
        failures.append(f"{SCANNER_FILE}: no {SCAN_WORK}() to check")
        return
    body = source[walk[0] : walk[1]]
    if not occurrences(body, r"\bthrow\s+ScanSuperseded\s*\("):
        failures.append(f"{SCANNER_FILE}: {SCAN_WORK}() never acts on cancellation")
        return

    # The rethrow has to come before the catch-all, or Kotlin never reaches it.
    superseded = re.search(r"\bcatch\s*\(\s*\w+\s*:\s*ScanSuperseded\s*\)", body)
    catch_all = re.search(r"\bcatch\s*\(\s*\w+\s*:\s*Exception\s*\)", body)
    if catch_all is not None and (
        superseded is None or superseded.start() > catch_all.start()
    ):
        failures.append(
            f"{SCANNER_FILE}: {SCAN_WORK}() must rethrow ScanSuperseded before its "
            "catch-all, or a superseded scan is counted as an unreadable subtree "
            "and answers a partial success instead (#346)"
        )


def check(directory: Path) -> list[str]:
    failures: list[str] = []
    check_worker(directory, failures)
    check_scanner(directory, failures)
    check_cancellation(directory, failures)
    return failures


def main() -> int:
    failures = check(KOTLIN)
    if failures:
        print("Android channel threading check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("Android channel threading check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
