#!/usr/bin/env python3
"""Re-derive repository-integrity findings inside the trusted reporter.

Why this exists: for a ``pull_request`` event GitHub runs the scanner workflow
definition from the merge ref, which a fork contributor controls. They can keep
the scanner's name/path, drop its trusted-checker step, and upload a
``repository-integrity-findings`` artifact whose GitHub-provided identity fields
are genuine while its findings list is forged empty. Identity binding proves
*which* pull request an artifact describes; it cannot prove the verdict is
honest.

The artifact's findings are therefore never published. The reporter re-derives
the verdict with the same checker-selection policy as the scanner:

* normally the checker blob comes from the bound base commit;
* only for a repository-owner, same-repository pull request may the bootstrap
  path use the checker blob from the bound PR head when the base checker is
  missing or predates the ``--json-report`` interface.

That bootstrap exception mirrors ``repository-integrity.yml`` exactly. External
and fork pull-request code is never executed. For the owner bootstrap case the
head checker is maintainer-controlled code, selected by a GitHub-bound head SHA,
and is read as a git blob without checking out the PR tree. The checker itself
analyses git objects only; the working tree remains on the trusted default
branch throughout.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$")
MAX_LOGIN_LENGTH = 64
MAX_PR_NUMBER = 1_000_000
CHECKER_PATH = "scripts/check_repository_integrity.py"
CHECKER_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
# The checker exits 1 when it has findings; that is a verdict, not a failure.
CLEAN, BLOCKED = 0, 1


class RecomputeError(Exception):
    """The verdict could not be re-derived. The reporter must not comment."""


def _checker_blob(commit_sha: str, checker_path: str, *, run=subprocess.run):
    """Return ``git show <sha>:<path>`` without touching the working tree."""
    return run(
        ["git", "show", f"{commit_sha}:{checker_path}"],
        capture_output=True,
    )


def _structured_checker(content: bytes) -> bool:
    """Mirror the scanner's bootstrap feature test (``grep -- --json-report``)."""
    return b"--json-report" in content


def load_checker(
    base_sha: str,
    checker_path: str,
    destination: Path,
    *,
    head_sha: str | None = None,
    pr_author: str | None = None,
    repo_owner: str | None = None,
    head_repository: str | None = None,
    repository: str | None = None,
    run=subprocess.run,
) -> Path:
    """Select the same trusted checker revision the scanner selected.

    The normal path reads the checker from ``base_sha``. If that checker is
    absent or predates the structured-report interface, the scanner has one
    deliberate bootstrap exception: a PR authored by the repository owner and
    coming from the same repository may use the PR-head checker. The reporter
    must mirror that selection or a scan that legitimately bootstrapped can
    never receive its sticky comment.

    The head fallback is *never* available to a fork/external PR. The fallback
    blob is read from the already-bound ``head_sha`` with ``git show``; no PR
    tree is checked out and no contributor-controlled ref is trusted by name.
    """
    if not CHECKER_PATH_RE.fullmatch(checker_path) or ".." in checker_path:
        raise RecomputeError("invalid checker path")

    base = _checker_blob(base_sha, checker_path, run=run)
    if base.returncode == 0 and _structured_checker(base.stdout):
        destination.write_bytes(base.stdout)
        return destination

    bootstrap_allowed = (
        isinstance(head_sha, str)
        and SHA_RE.fullmatch(head_sha) is not None
        and isinstance(pr_author, str)
        and isinstance(repo_owner, str)
        and pr_author == repo_owner
        and isinstance(head_repository, str)
        and isinstance(repository, str)
        and head_repository == repository
    )

    if bootstrap_allowed:
        head = _checker_blob(head_sha, checker_path, run=run)
        if head.returncode != 0:
            detail = head.stderr.decode("utf-8", "replace").strip()[:200]
            raise RecomputeError(
                "the repository-owner bootstrap checker is not present at "
                f"bound head commit {head_sha}: {detail}"
            )
        if not _structured_checker(head.stdout):
            raise RecomputeError(
                "the repository-owner bootstrap checker does not support the "
                "structured report interface"
            )
        destination.write_bytes(head.stdout)
        return destination

    if base.returncode != 0:
        detail = base.stderr.decode("utf-8", "replace").strip()[:200]
        raise RecomputeError(
            f"the trusted checker is not present at base commit {base_sha}: {detail}"
        )
    raise RecomputeError(
        "the trusted base checker does not support the structured report "
        "interface; refusing to execute pull-request checker code"
    )


def valid_login(value: object) -> bool:
    """A GitHub account login, held only to what a comparand in an argv needs.

    Deliberately no character allowlist. Bot accounts are named ``name[bot]``
    and an obvious login pattern rejects the brackets. The value is used for a
    casefolded comparison in the checker and is passed as one argv element, not
    through a shell.
    """
    if not isinstance(value, str) or not 1 <= len(value) <= MAX_LOGIN_LENGTH:
        return False
    return not value.startswith("-") and not any(
        ch < " " or ch == "\x7f" for ch in value
    )


def load_binding(path: Path) -> dict[str, object]:
    """Read the binding, re-validating every field this program will use."""
    if path.stat().st_size > 4_096:
        raise RecomputeError("binding exceeds size limit")
    binding = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(binding, dict):
        raise RecomputeError("invalid binding")
    for field, pattern in (
        ("head_sha", SHA_RE),
        ("base_sha", SHA_RE),
        ("head_repository", REPO_RE),
        ("repository", REPO_RE),
    ):
        value = binding.get(field)
        if not isinstance(value, str) or not pattern.fullmatch(value):
            raise RecomputeError(f"invalid {field} in binding")
    if not valid_login(binding.get("pr_author")):
        raise RecomputeError("invalid pr_author in binding")
    number = binding.get("pr_number")
    if (
        not isinstance(number, int)
        or isinstance(number, bool)
        or not 1 <= number <= MAX_PR_NUMBER
    ):
        raise RecomputeError("invalid pr_number in binding")
    return binding


def fetch_objects(
    binding: dict[str, object],
    *,
    remote: str = "origin",
    run=subprocess.run,
) -> None:
    """Bring PR/base objects into the trusted checkout, without checking out."""
    number = binding["pr_number"]
    for refspec in (f"refs/pull/{number}/head", str(binding["base_sha"])):
        result = run(
            ["git", "fetch", "--no-tags", "--quiet", remote, refspec],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RecomputeError(
                f"could not fetch {refspec}: {result.stderr.strip()[:200]}"
            )


def checker_command(
    checker: Path,
    binding: dict[str, object],
    report: Path,
    summary: Path,
    repo_owner: str,
) -> list[str]:
    """Build the checker invocation as an argument vector, never a shell string."""
    return [
        sys.executable,
        str(checker),
        "--base",
        str(binding["base_sha"]),
        "--head",
        str(binding["head_sha"]),
        "--pr-author",
        str(binding["pr_author"]),
        "--repo-owner",
        repo_owner,
        "--report",
        str(summary),
        "--json-report",
        str(report),
        "--pr-number",
        str(binding["pr_number"]),
        "--head-repository",
        str(binding["head_repository"]),
    ]


def recompute(
    checker: Path,
    binding: dict[str, object],
    report: Path,
    summary: Path,
    repo_owner: str,
    *,
    run=subprocess.run,
) -> int:
    """Run the selected trusted checker. Return verdict; raise on inability."""
    command = checker_command(checker, binding, report, summary, repo_owner)
    result = run(command, capture_output=True, text=True)
    if result.returncode not in (CLEAN, BLOCKED):
        raise RecomputeError(
            "trusted checker could not evaluate the pull request "
            f"(exit {result.returncode}): {result.stderr.strip()[:500]}"
        )
    if not report.is_file():
        raise RecomputeError("trusted checker produced no report")
    return result.returncode


def divergence(claimed: Path, recomputed: Path) -> str | None:
    """Describe how the uploaded artifact differs from the re-derived verdict."""

    def count(path: Path) -> int | None:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        findings = payload.get("findings") if isinstance(payload, dict) else None
        return len(findings) if isinstance(findings, list) else None

    uploaded, derived = count(claimed), count(recomputed)
    if uploaded is None:
        return "the uploaded artifact could not be read for comparison"
    if uploaded == derived:
        return None
    return (
        f"the uploaded artifact reported {uploaded} finding(s) but the trusted "
        f"checker re-derived {derived}; the re-derived result is authoritative"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binding", required=True, type=Path)
    parser.add_argument(
        "--checker-path",
        default=CHECKER_PATH,
        help="repository-relative checker path selected by scanner policy",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--repo-owner", required=True)
    parser.add_argument("--claimed", type=Path)
    parser.add_argument(
        "--no-fetch",
        action="store_true",
        help="objects are already present (used by the tests)",
    )
    args = parser.parse_args(argv)

    try:
        if not valid_login(args.repo_owner):
            raise RecomputeError("invalid repository owner")
        binding = load_binding(args.binding)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if not args.no_fetch:
            fetch_objects(binding)
        checker = load_checker(
            str(binding["base_sha"]),
            args.checker_path,
            args.output.parent / "trusted-checker.py",
            head_sha=str(binding["head_sha"]),
            pr_author=str(binding["pr_author"]),
            repo_owner=args.repo_owner,
            head_repository=str(binding["head_repository"]),
            repository=str(binding["repository"]),
        )
        verdict = recompute(
            checker,
            binding,
            args.output,
            args.summary,
            args.repo_owner,
        )
    except (RecomputeError, ValueError, OSError) as exc:
        print(
            "::error::Repository integrity reporter could not re-derive the "
            f"findings, so it will not comment: {exc}",
            file=sys.stderr,
        )
        return 1

    if args.claimed is not None:
        difference = divergence(args.claimed, args.output)
        if difference is not None:
            print(
                "::warning::The scanner run's artifact does not match the trusted "
                f"re-derivation: {difference}. This is expected when the scanner "
                "workflow was modified in the pull request."
            )
    print(
        "Re-derived the repository-integrity verdict from trusted checker code: "
        f"{'findings present' if verdict == BLOCKED else 'clean'}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
