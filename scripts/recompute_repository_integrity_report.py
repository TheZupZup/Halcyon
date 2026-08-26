#!/usr/bin/env python3
"""Re-derive the repository-integrity findings inside the trusted reporter.

Why this exists: for a `pull_request` event GitHub runs the workflow definition
from the merge ref, which a fork contributor controls. They can keep the
scanner's name and path, drop its "load the trusted checker" step entirely, and
upload a `repository-integrity-findings` artifact whose identity fields are the
genuine GitHub-provided ones but whose `findings` list is empty. Identity
binding cannot catch that: every field it checks is honest. The forged part is
the verdict, and the trusted reporter would publish it as a CLEAN comment under
`github-actions[bot]`, lending contributor-authored content the authority of the
maintainer-controlled reporter.

So the artifact's `findings` are not trusted for anything. The verdict rendered
into the sticky comment is computed here, by the checker on the trusted default
branch, over the same commit range -- and from inputs (base SHA, head SHA, PR
author) that come from the live pull request rather than from the artifact.

No pull-request code is executed and no pull-request tree is checked out. The
checker reads git objects only -- `show`, `ls-tree`, `rev-list`, `merge-base`,
`diff` -- so the objects are fetched into the trusted checkout and analysed as
data. The working tree stays on the default branch throughout.
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
# The scanner loads its checker from the pull request's base commit. The
# re-derivation must use that same revision: see load_checker.
CHECKER_PATH = "scripts/check_repository_integrity.py"
CHECKER_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
# The checker exits 1 when it has findings; that is a verdict, not a failure.
CLEAN, BLOCKED = 0, 1


class RecomputeError(Exception):
    """The verdict could not be re-derived. The reporter must not comment."""


def load_checker(base_sha: str, checker_path: str, destination: Path,
                 *, run=subprocess.run) -> Path:
    """Read the checker out of the bound base commit, as the scanner does.

    The scanner runs `git show "$BASE_SHA:scripts/check_repository_integrity.py"`,
    so the policy it applied is the one committed on the pull request's base
    branch. Running the reporter's own default-branch copy instead would apply a
    different revision whenever the base is not the default branch, or whenever
    the checker changed on the default branch between the scan and the report.
    The two revisions can enforce different rules, so the comment could report
    CLEAN while the guard is red, or BLOCKED while it passed -- the check and
    the comment explaining it must never disagree.

    Both revisions are maintainer-controlled, so this is a consistency
    requirement rather than a trust one; the base commit is the branch a
    maintainer chose to merge into, which is what the scanner already treats as
    authoritative. A base commit whose checker is missing or unusable fails
    closed, exactly like any other input this program cannot verify.
    """
    if not CHECKER_PATH_RE.fullmatch(checker_path) or ".." in checker_path:
        raise RecomputeError("invalid checker path")
    result = run(["git", "show", f"{base_sha}:{checker_path}"],
                 capture_output=True)
    if result.returncode != 0:
        raise RecomputeError(
            f"the trusted checker is not present at base commit {base_sha}: "
            f"{result.stderr.decode('utf-8', 'replace').strip()[:200]}")
    destination.write_bytes(result.stdout)
    return destination


def valid_login(value: object) -> bool:
    """A GitHub account login, held only to what a comparand in an argv needs.

    Deliberately no character allowlist. Bot accounts are named `name[bot]` --
    `dependabot[bot]`, `github-actions[bot]` -- and an obvious login pattern
    rejects the brackets, which would leave every Dependabot pull request with a
    red reporter and no findings comment. The value is used for one casefolded
    comparison in the checker's `is_external`, and is passed as an argument
    vector element rather than through a shell, so no character in it can mean
    anything.

    What is enforced is what that use needs: a string, a length bound, no ASCII
    control characters, and no leading hyphen, so it can never be mistaken for
    an option by the program it is passed to.
    """
    if not isinstance(value, str) or not 1 <= len(value) <= MAX_LOGIN_LENGTH:
        return False
    return not value.startswith("-") and not any(
        ch < " " or ch == "\x7f" for ch in value)


def load_binding(path: Path) -> dict[str, object]:
    """Read the binding, re-validating every field this program will use.

    The binder wrote it moments ago, but it is read back off disk, so it is
    validated again rather than assumed.
    """
    if path.stat().st_size > 4_096:
        raise RecomputeError("binding exceeds size limit")
    binding = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(binding, dict):
        raise RecomputeError("invalid binding")
    for field, pattern in (("head_sha", SHA_RE), ("base_sha", SHA_RE),
                           ("head_repository", REPO_RE)):
        value = binding.get(field)
        if not isinstance(value, str) or not pattern.fullmatch(value):
            raise RecomputeError(f"invalid {field} in binding")
    if not valid_login(binding.get("pr_author")):
        raise RecomputeError("invalid pr_author in binding")
    number = binding.get("pr_number")
    if not isinstance(number, int) or isinstance(number, bool) or not 1 <= number <= MAX_PR_NUMBER:
        raise RecomputeError("invalid pr_number in binding")
    return binding


def fetch_objects(binding: dict[str, object], *, remote: str = "origin",
                  run=subprocess.run) -> None:
    """Bring the PR's objects into the trusted checkout, without checking out.

    Fork commits are reachable in this repository through `refs/pull/N/head`, so
    nothing is fetched from the contributor's own remote. `--no-tags` keeps the
    fetch to exactly the refs named.
    """
    number = binding["pr_number"]
    for refspec in (f"refs/pull/{number}/head", str(binding["base_sha"])):
        result = run(["git", "fetch", "--no-tags", "--quiet", remote, refspec],
                     capture_output=True, text=True)
        if result.returncode != 0:
            raise RecomputeError(
                f"could not fetch {refspec}: {result.stderr.strip()[:200]}")


def checker_command(checker: Path, binding: dict[str, object], report: Path,
                    summary: Path, repo_owner: str) -> list[str]:
    """Build the checker invocation.

    Assembled as an argument vector and never as a shell string, so none of
    these values is ever parsed by a shell. They are all validated above in any
    case, and all of them originate with GitHub rather than with the artifact.
    """
    return [
        sys.executable, str(checker),
        "--base", str(binding["base_sha"]),
        "--head", str(binding["head_sha"]),
        "--pr-author", str(binding["pr_author"]),
        "--repo-owner", repo_owner,
        "--report", str(summary),
        "--json-report", str(report),
        "--pr-number", str(binding["pr_number"]),
        "--head-repository", str(binding["head_repository"]),
    ]


def recompute(checker: Path, binding: dict[str, object], report: Path, summary: Path,
              repo_owner: str, *, run=subprocess.run) -> int:
    """Run the trusted checker. Returns its verdict; raises if it could not run."""
    command = checker_command(checker, binding, report, summary, repo_owner)
    result = run(command, capture_output=True, text=True)
    if result.returncode not in (CLEAN, BLOCKED):
        raise RecomputeError(
            f"trusted checker could not evaluate the pull request "
            f"(exit {result.returncode}): {result.stderr.strip()[:500]}")
    if not report.is_file():
        raise RecomputeError("trusted checker produced no report")
    return result.returncode


def divergence(claimed: Path, recomputed: Path) -> str | None:
    """Describe how the uploaded artifact differs from the re-derived verdict.

    Purely diagnostic. A divergence is reported and the re-derived verdict is
    the one that gets published: refusing to comment on a mismatch would let a
    forged artifact suppress the very finding it was forged to hide.
    """
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
    return (f"the uploaded artifact reported {uploaded} finding(s) but the trusted "
            f"checker re-derived {derived}; the re-derived result is authoritative")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binding", required=True, type=Path)
    parser.add_argument("--checker-path", default=CHECKER_PATH,
                        help="repository-relative path read from the bound base commit")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--repo-owner", required=True)
    parser.add_argument("--claimed", type=Path)
    parser.add_argument("--no-fetch", action="store_true",
                        help="objects are already present (used by the tests)")
    args = parser.parse_args(argv)

    try:
        if not valid_login(args.repo_owner):
            raise RecomputeError("invalid repository owner")
        binding = load_binding(args.binding)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if not args.no_fetch:
            fetch_objects(binding)
        checker = load_checker(str(binding["base_sha"]), args.checker_path,
                               args.output.parent / "trusted-checker.py")
        verdict = recompute(checker, binding, args.output, args.summary,
                            args.repo_owner)
    except (RecomputeError, ValueError, OSError) as exc:
        print(f"::error::Repository integrity reporter could not re-derive the "
              f"findings, so it will not comment: {exc}", file=sys.stderr)
        return 1

    if args.claimed is not None:
        difference = divergence(args.claimed, args.output)
        if difference is not None:
            print(f"::warning::The scanner run's artifact does not match the trusted "
                  f"re-derivation: {difference}. This is expected when the scanner "
                  f"workflow was modified in the pull request.")
    print("Re-derived the repository-integrity verdict from trusted checker code: "
          f"{'findings present' if verdict == BLOCKED else 'clean'}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
