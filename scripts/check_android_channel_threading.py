#!/usr/bin/env python3
"""check_android_channel_threading.py — keep the SAF scan off the main thread.

Flutter calls a `MethodChannel` handler on Android's platform (main) thread, and
`MethodChannel.Result` has to be answered there too. That pairing makes it very
easy to write a handler that quietly blocks the UI: the code reads like ordinary
straight-line Kotlin, it compiles, and on the developer's twelve-track test
folder it returns instantly. It only hurts on a real library, on a slow
provider, or on an SD card — where it becomes an ANR (#346).

Nothing in the build catches that. Lint has no opinion about how long a channel
handler runs, and a regression would look like a simplification: delete the
worker, call `walk()` directly, tests still pass. So the boundary is asserted
here instead.

Three things have to hold, and each is checked against the sources rather than
duplicated:

    the worker exists          <- PlatformChannelWorker.kt runs work on an
                                  Executor and posts replies to the main looper
    the scan uses it           <- SafDocumentScanner.listAudioDocuments submits
                                  the walk instead of running it inline
    nothing answers inline     <- listAudioDocuments contains no direct
                                  result.success(walk(...)) call

The last one is the shape the bug had before the fix, so it is worth naming
explicitly rather than inferring from the other two.

This is deliberately a text check, not a parse: it has to run anywhere (no
Android SDK, no Gradle, no network), the same way check_linux_runner.py does for
the desktop runner. It is not a substitute for reading the code — it is a
tripwire for the specific silent regression.

    python3 scripts/check_android_channel_threading.py

Exits 0 when every claim holds, 1 with the failures listed otherwise.
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

# The channel method whose work is heavy enough to matter, and the private
# function that does that work.
SCAN_METHOD = "listAudioDocuments"
SCAN_WORK = "walk"


def read(directory: Path, name: str, failures: list[str]) -> str:
    """Returns the text of ``directory/name``, or "" (recording why) if absent."""
    path = directory / name
    if not path.is_file():
        failures.append(f"{name}: missing (expected at {path})")
        return ""
    return path.read_text(encoding="utf-8")


def strip_comments(source: str) -> str:
    """Drops // and /* */ comments so a mention in prose is never a match.

    Every claim below is about code that runs. KDoc on these files talks about
    `walk`, `result.success` and the main thread by name, so checking the raw
    text would pass on a file whose comments still describe a fix its code no
    longer has.
    """
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def function_body(source: str, name: str) -> str | None:
    """Returns the brace-balanced body of ``fun name(...)``, or None.

    Tolerates a type-parameter list (``fun <T> submit(``), which the worker has.
    """
    match = re.search(rf"\bfun\s+(?:<[^>]*>\s*)?{re.escape(name)}\s*\(", source)
    if match is None:
        return None
    opening = source.find("{", match.end())
    if opening == -1:
        return None
    depth = 0
    for index in range(opening, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    return None


def check_worker(directory: Path, failures: list[str]) -> None:
    """The worker really moves work off the caller and back to the main looper."""
    source = strip_comments(read(directory, WORKER_FILE, failures))
    if not source:
        return

    if "java.util.concurrent.Executor" not in source:
        failures.append(
            f"{WORKER_FILE}: no Executor import — work has to leave the caller's "
            "thread on something"
        )
    if "Looper.getMainLooper()" not in source or "handler.post(" not in source:
        failures.append(
            f"{WORKER_FILE}: replies are not posted to the main looper "
            "(Handler(Looper.getMainLooper()) + post), which Flutter requires "
            "for MethodChannel.Result"
        )

    body = function_body(source, "submit")
    if body is None:
        failures.append(f"{WORKER_FILE}: no submit() to hand work to")
        return
    if "background.execute" not in body:
        failures.append(
            f"{WORKER_FILE}: submit() does not run its work on the background executor"
        )
    if "platform.execute" not in body:
        failures.append(
            f"{WORKER_FILE}: submit() does not deliver its callbacks on the "
            "platform executor"
        )


def check_scanner(directory: Path, failures: list[str]) -> None:
    """The scan is submitted to the worker, and never answered inline."""
    source = strip_comments(read(directory, SCANNER_FILE, failures))
    if not source:
        return

    if "PlatformChannelWorker" not in source:
        failures.append(
            f"{SCANNER_FILE}: does not use PlatformChannelWorker, so the walk "
            "runs on whichever thread calls it"
        )

    body = function_body(source, SCAN_METHOD)
    if body is None:
        failures.append(f"{SCANNER_FILE}: no {SCAN_METHOD}() to check")
        return

    if "worker.submit(" not in body:
        failures.append(
            f"{SCANNER_FILE}: {SCAN_METHOD}() does not submit its work to the "
            "worker — the walk is back on the platform thread (#346)"
        )

    # The pre-fix shape: the whole walk evaluated as the argument to a reply,
    # i.e. on the caller's thread. Whitespace-tolerant so reformatting the call
    # does not hide it.
    inline = re.compile(
        rf"result\s*\.\s*success\s*\(\s*{re.escape(SCAN_WORK)}\s*\(",
        re.DOTALL,
    )
    if inline.search(body):
        failures.append(
            f"{SCANNER_FILE}: {SCAN_METHOD}() answers with {SCAN_WORK}() inline, "
            "which runs the whole library walk on the platform thread (#346)"
        )


def check(directory: Path) -> list[str]:
    """Runs every claim against the Kotlin in [directory]. Empty list = passing."""
    failures: list[str] = []
    check_worker(directory, failures)
    check_scanner(directory, failures)
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
