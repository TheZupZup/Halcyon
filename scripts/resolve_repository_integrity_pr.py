#!/usr/bin/env python3
"""Bind a scanner findings artifact to the pull request it actually describes.

This program runs only from the trusted default branch, inside the `workflow_run`
reporter. It answers one question: may the reporter write a comment on a pull
request, and which one.

Why it exists: for a pull request opened from a fork, GitHub delivers
`workflow_run.pull_requests` as an empty array, so the reporter had no PR to
comment on and skipped. The findings artifact does carry a `pr_number`, but the
scanner workflow file is contributor-controlled at the merge ref, so that number
is a *claim*, never an authority. Every claim in the artifact is therefore
re-derived from fields only GitHub can set:

  * `workflow_run.head_sha` and `workflow_run.head_repository.full_name` are set
    by GitHub from the pull request that started the run. A contributor cannot
    forge them from inside the run.
  * The artifact is downloaded with `run-id` pinned to this exact run, so it
    provably came from the run those two fields describe.
  * The claimed PR is then fetched from the API and must independently agree:
    it must live in this repository, its head SHA must be the run's head SHA,
    and its head repository must be the run's head repository.

An attacker who republishes somebody else's head commit into their own fork can
match the SHA, but not the head repository, so they can still only ever address
their own pull request.

Every unresolved, ambiguous, or mismatched case exits non-zero and no comment is
written. There is no best-effort path.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable

# The scanner's immutable identity. `workflows:` on the reporter's trigger
# matches display name only, which a contributor can copy onto an unrelated
# workflow; the file path is what actually pins the producer.
SCANNER_WORKFLOW_PATH = ".github/workflows/repository-integrity.yml"
SCANNER_WORKFLOW_NAME = "Repository integrity"
SCANNER_EVENT = "pull_request"

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$")
# GitHub caps a branch name at 255 bytes. Nothing narrower is imposed: see
# _branch below for why this value is bounded but not otherwise constrained.
MAX_BRANCH_LENGTH = 255
# GitHub logins: alphanumeric and hyphens, 39 characters maximum.
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
MAX_PR_NUMBER = 1_000_000
# A commit realistically has one associated pull request. The bound exists so a
# pathological or hostile response cannot be read unbounded; exceeding it fails
# closed rather than selecting from a set that was silently cut short.
MAX_CANDIDATES = 100
_PAGE_SIZE = 100
_MAX_PAGES = 4
MAX_REPORT_BYTES = 1_000_000
MAX_EVENT_BYTES = 5_000_000
API_ROOT = "https://api.github.com"


class BindingError(Exception):
    """The reporter may not write. Raised for every unresolved case."""


@dataclass(frozen=True)
class RunFacts:
    """Fields of the triggering run that only GitHub can set."""

    run_id: int
    head_sha: str
    head_repository: str
    head_branch: str | None
    repository: str
    pull_requests: tuple[int, ...]


@dataclass(frozen=True)
class Binding:
    pr_number: int
    head_sha: str
    head_repository: str
    # GitHub-set branch name of the run's head, when the event carries one. One
    # more immutable identity dimension the live PR has to agree with.
    head_branch: str | None
    repository: str
    run_id: int
    # "workflow_run" when GitHub named the PR itself; "artifact" when the PR was
    # recovered from the report and must be confirmed against the API.
    pr_source: str
    # Filled in from the live pull request, never from the artifact. These are
    # what the trusted reporter re-derives the findings from, so they must come
    # from GitHub rather than from anything the scanner run wrote.
    base_sha: str | None = None
    pr_author: str | None = None

    def as_dict(self) -> dict[str, object]:
        return {
            "pr_number": self.pr_number,
            "head_sha": self.head_sha,
            "head_repository": self.head_repository,
            "head_branch": self.head_branch,
            "repository": self.repository,
            "run_id": self.run_id,
            "pr_source": self.pr_source,
            "base_sha": self.base_sha,
            "pr_author": self.pr_author,
        }


def _mapping(value: object, field: str) -> dict:
    if not isinstance(value, dict):
        raise BindingError(f"invalid {field}")
    return value


def _exact(value: object, expected: str, field: str) -> str:
    if not isinstance(value, str) or value != expected:
        raise BindingError(f"unexpected {field}")
    return value


def _sha(value: object, field: str) -> str:
    if not isinstance(value, str) or not SHA_RE.fullmatch(value):
        raise BindingError(f"invalid {field}")
    return value


def _repository(value: object, field: str) -> str:
    if not isinstance(value, str) or not REPO_RE.fullmatch(value):
        raise BindingError(f"invalid {field}")
    return value


def _branch(value: object, field: str) -> str | None:
    """Branch names are optional, and are opaque equality-only data.

    Deliberately no character allowlist. Git accepts far more than an obvious
    one admits -- `feature+test`, `feature@2`, and non-ASCII names all pass
    `git check-ref-format --branch` -- and rejecting a legitimate branch here
    would leave the reporter red with no findings comment on that pull request,
    which is the very failure this program exists to end. Reimplementing git's
    real ref grammar would buy nothing either: this value is only ever compared
    against the live pull request's own `head.ref`. It never forms a URL, a
    command, or a log line, so no character in it can mean anything.

    What is enforced is what a comparand needs: a string, a length bound, and no
    ASCII control characters -- which git forbids in a ref anyway, and which are
    the only class that could matter if this value were ever printed.
    """
    if value is None or value == "":
        return None
    if not isinstance(value, str) or len(value) > MAX_BRANCH_LENGTH:
        raise BindingError(f"invalid {field}")
    if any(ch < " " or ch == "\x7f" for ch in value):
        raise BindingError(f"invalid {field}")
    return value


def _login(value: object, field: str) -> str:
    if not isinstance(value, str) or not LOGIN_RE.fullmatch(value):
        raise BindingError(f"invalid {field}")
    return value


def _identifier(value: object, field: str, maximum: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= maximum:
        raise BindingError(f"invalid {field}")
    return value


def trusted_run(event: object, repository: str) -> RunFacts:
    """Establish that this event is the scanner's own run in this repository."""
    payload = _mapping(event, "workflow event")
    run = _mapping(payload.get("workflow_run"), "workflow run")
    _exact(_mapping(payload.get("repository"), "event repository").get("full_name"),
           repository, "event repository")
    _exact(_mapping(run.get("repository"), "run repository").get("full_name"),
           repository, "run repository")
    _exact(run.get("event"), SCANNER_EVENT, "triggering event")
    _exact(run.get("path"), SCANNER_WORKFLOW_PATH, "scanner workflow path")
    _exact(run.get("name"), SCANNER_WORKFLOW_NAME, "scanner workflow name")

    pull_requests = run.get("pull_requests")
    if not isinstance(pull_requests, list):
        raise BindingError("invalid pull request list")
    numbers = tuple(
        _identifier(_mapping(entry, "pull request").get("number"), "pull request number",
                    MAX_PR_NUMBER)
        for entry in pull_requests
    )
    return RunFacts(
        run_id=_identifier(run.get("id"), "run id", 2**53 - 1),
        head_sha=_sha(run.get("head_sha"), "run head SHA"),
        head_repository=_repository(
            _mapping(run.get("head_repository"), "run head repository").get("full_name"),
            "run head repository"),
        head_branch=_branch(run.get("head_branch"), "run head branch"),
        repository=repository,
        pull_requests=numbers,
    )


def artifact_identity(payload: object) -> tuple[int, str, str]:
    """Read the identity fields out of the artifact, after schema validation.

    Nothing here is trusted yet. These are the values `resolve` must reconcile
    against the run, and `verify_pull_request` against the API.
    """
    report = _mapping(payload, "report")
    if report.get("schema_version") != 1:
        raise BindingError("unsupported report schema")
    return (
        _identifier(report.get("pr_number"), "report PR number", MAX_PR_NUMBER),
        _sha(report.get("head_sha"), "report head SHA"),
        _repository(report.get("head_repository"), "report head repository"),
    )


def resolve(event: object, payload: object, repository: str) -> Binding:
    """Bind the artifact to the triggering run, or refuse."""
    run = trusted_run(event, repository)
    pr_number, head_sha, head_repository = artifact_identity(payload)

    # The artifact must describe the exact head this run scanned. An artifact
    # produced by any other run cannot satisfy both of these.
    #
    # `workflow_run.head_sha` on a `pull_request` run is the raw PR head commit,
    # which is what the scanner writes into the artifact from
    # `github.event.pull_request.head.sha`, so these are the same value.
    # Confirmed on this repository's own runs: run 32902865997 reports
    # 68c58bc2f6c396858923356e144acf0c6d648cfe with that commit's own subject as
    # its head_commit.message, and run 32887057547 reports
    # a9ecac5b6a94159c590ccb51e09f5a00ac14f796, exactly PR #513's head.sha.
    #
    # Not to be confused with `github.sha` / GITHUB_SHA -- what checkout resolves
    # by default -- which IS the synthetic merge revision on `pull_request`. The
    # scanner does not rely on it: it pins `ref: ...pull_request.head.sha`.
    if head_sha != run.head_sha:
        raise BindingError("report head SHA does not match the triggering run")
    if head_repository != run.head_repository:
        raise BindingError("report head repository does not match the triggering run")

    if len(run.pull_requests) == 1:
        # GitHub named the PR. Its number wins; the artifact must agree with it.
        if pr_number != run.pull_requests[0]:
            raise BindingError("report PR number does not match the triggering run")
        source = "workflow_run"
    elif not run.pull_requests:
        # Fork-originated run: GitHub sends an empty array. The artifact's claim
        # is carried forward as a candidate only, to be confirmed against the API.
        source = "artifact"
    else:
        raise BindingError("workflow run identifies more than one PR")

    return Binding(pr_number=pr_number, head_sha=head_sha, head_repository=head_repository,
                   head_branch=run.head_branch, repository=repository, run_id=run.run_id,
                   pr_source=source)


def _head_repository_of(pull_request: dict) -> str | None:
    head = pull_request.get("head")
    if not isinstance(head, dict):
        return None
    repo = head.get("repo")
    return repo.get("full_name") if isinstance(repo, dict) else None


def association_path(binding: Binding) -> str:
    """The commit-to-PR association endpoint for this run's head commit.

    The query must go to the HEAD repository, not the base. A fork's head commit
    is not in the base repository's own commit list, so
    `/repos/{base}/commits/{fork_sha}/pulls` answers `[]` for exactly the fork
    pull requests this recovery path exists to resolve -- verified against the
    live API with PR #513's head. `/repos/{fork}/commits/{sha}/pulls` returns it.

    Querying a contributor-controlled repository grants nothing: the repository
    is `workflow_run.head_repository.full_name`, which GitHub sets, and every
    candidate it returns is still constrained by `select_candidate` below to a
    pull request into this repository, from that same fork, at that same head.
    """
    repository = urllib.parse.quote(binding.head_repository, safe="/")
    return f"/repos/{repository}/commits/{binding.head_sha}/pulls"


def select_candidate(candidates: object, binding: Binding) -> int:
    """Pick the single PR this run's head can belong to, or refuse.

    Republishing another contributor's head commit into your own fork makes the
    SHA collide, so the SHA alone can name two pull requests. Narrowing by head
    repository leaves only pull requests opened from the fork this run actually
    ran for, and more than one survivor is ambiguous rather than best-effort.
    """
    if not isinstance(candidates, list) or len(candidates) > MAX_CANDIDATES:
        raise BindingError("invalid associated pull request list")
    numbers = set()
    for entry in candidates:
        pull_request = _mapping(entry, "associated pull request")
        base = pull_request.get("base")
        base_repo = base.get("repo") if isinstance(base, dict) else None
        if not isinstance(base_repo, dict) or base_repo.get("full_name") != binding.repository:
            continue
        if _head_repository_of(pull_request) != binding.head_repository:
            continue
        numbers.add(_identifier(pull_request.get("number"), "associated PR number",
                                MAX_PR_NUMBER))
    if len(numbers) != 1:
        raise BindingError(
            f"{len(numbers)} pull requests match this run's head; refusing to guess")
    resolved = numbers.pop()
    if resolved != binding.pr_number:
        raise BindingError("report PR number is not the PR this run's head belongs to")
    return resolved


def verify_pull_request(pull_request: object, binding: Binding) -> tuple[bool, Binding]:
    """Confirm the live PR is the one the artifact claims, and take from it the
    scan inputs the trusted reporter re-derives its own findings from.

    Returns (may_write, binding). A false first element means superseded.
    """
    live = _mapping(pull_request, "pull request")
    if _identifier(live.get("number"), "PR number", MAX_PR_NUMBER) != binding.pr_number:
        raise BindingError("API returned a different pull request")
    base = _mapping(live.get("base"), "PR base")
    if _mapping(base.get("repo"), "PR base repository").get("full_name") != binding.repository:
        raise BindingError("pull request does not belong to this repository")
    if _head_repository_of(live) != binding.head_repository:
        raise BindingError("pull request head repository does not match the scanned head")
    head = _mapping(live.get("head"), "PR head")
    if binding.head_branch is not None:
        if _branch(head.get("ref"), "PR head branch") != binding.head_branch:
            raise BindingError("pull request head branch does not match the scanned head")
    head_sha = _sha(head.get("sha"), "PR head SHA")
    # Both are read from the live pull request, so the re-derivation the reporter
    # performs cannot be steered by anything the scanner run wrote.
    bound = replace(
        binding,
        base_sha=_sha(base.get("sha"), "PR base SHA"),
        pr_author=_login(_mapping(live.get("user"), "PR author").get("login"), "PR author"),
    )
    # Out-of-order synchronize runs must never restore an older verdict over a
    # newer one. A moved head is not an error, it is a superseded report.
    return head_sha == binding.head_sha, bound


# Swappable so the pagination below can be exercised without a network.
_OPENER = urllib.request.urlopen

_NEXT_LINK = re.compile(r'<([^>]+)>\s*;\s*rel="next"')


def _next_page(link_header: str | None) -> str | None:
    """The `rel="next"` URL, required to stay on the API host.

    GitHub answers with an absolute URL under a different path shape than the
    one requested (`/repositories/{id}/...`), so it is followed as given rather
    than reconstructed -- but only ever after confirming the host, so a
    redirected or spoofed header cannot walk this request off api.github.com.
    """
    if not link_header:
        return None
    match = _NEXT_LINK.search(link_header)
    if not match:
        return None
    url = match.group(1)
    if not url.startswith(API_ROOT + "/"):
        raise BindingError("GitHub API pagination pointed off the API host")
    return url


def _read_page(url: str, token: str) -> tuple[object, str | None]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "linthra-repository-integrity-reporter",
            "Authorization": "Bearer " + token,
        },
    )
    with _OPENER(request, timeout=30) as response:  # noqa: S310 - fixed https root
        if response.status != 200:
            raise BindingError(f"GitHub API returned {response.status} for {url}")
        payload = json.loads(response.read(MAX_REPORT_BYTES).decode("utf-8"))
    return payload, _next_page(response.headers.get("Link"))


def api_get(path: str, token: str) -> object:
    """Fetch one API resource, following pagination when it is a collection.

    Collections must be read whole. The commit-to-PR association endpoint pages
    at 30 by default, so an unpaginated read could miss the pull request being
    resolved -- reporting zero matches on a PR that is present -- and could hide
    a second match from the ambiguity check, deciding "exactly one" against a
    set that was silently cut short. Accumulation is bounded, and exceeding the
    bound fails closed rather than selecting from a truncated set.
    """
    url = API_ROOT + path + ("&" if "?" in path else "?") + f"per_page={_PAGE_SIZE}"
    collected: list[object] | None = None
    for _ in range(_MAX_PAGES):
        payload, url = _read_page(url, token)
        if not isinstance(payload, list):
            return payload  # a single resource is never paginated
        collected = payload if collected is None else collected + payload
        if len(collected) > MAX_CANDIDATES:
            raise BindingError(
                f"GitHub returned more than {MAX_CANDIDATES} results for {path}; "
                "refusing to select from a set this large")
        if url is None:
            return collected
    raise BindingError(f"GitHub pagination for {path} did not terminate")


def _read_json(path: Path, limit: int, label: str) -> object:
    if path.stat().st_size > limit:
        raise BindingError(f"{label} exceeds size limit")
    return json.loads(path.read_text(encoding="utf-8"))


def decide(event: object, payload: object, repository: str,
           fetch: Callable[[str], object]) -> tuple[Binding, bool]:
    """Resolve, then confirm against the API. Returns (binding, may_write)."""
    binding = resolve(event, payload, repository)
    # Path segments are re-derived, never interpolated from report text: both
    # repositories match REPO_RE and equal values GitHub set, the SHA is 40 hex
    # characters, and the PR number is a bounded integer.
    owner_repo = urllib.parse.quote(binding.repository, safe="/")
    if binding.pr_source == "artifact":
        # Association is asked of the head repository; the pull request itself
        # is always read from this repository, which is what makes the answer
        # binding rather than merely suggestive.
        select_candidate(fetch(association_path(binding)), binding)
    may_write, binding = verify_pull_request(
        fetch(f"/repos/{owner_repo}/pulls/{binding.pr_number}"), binding)
    return binding, may_write


def _emit(name: str, value: str) -> None:
    destination = os.environ.get("GITHUB_OUTPUT")
    if destination:
        with open(destination, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN", "")
    try:
        if not token:
            raise BindingError("no API token available")
        repository = _repository(args.repository, "repository")
        event = _read_json(args.event, MAX_EVENT_BYTES, "workflow event")
        payload = _read_json(args.report, MAX_REPORT_BYTES, "report")
        binding, may_write = decide(event, payload, repository,
                                    lambda path: api_get(path, token))
    except (BindingError, ValueError, OSError, urllib.error.URLError) as exc:
        print(f"::error::Repository integrity reporter refused to comment: {exc}",
              file=sys.stderr)
        _emit("post", "false")
        return 1

    if not may_write:
        print(f"PR #{binding.pr_number} has moved past {binding.head_sha}; "
              "leaving the existing comment untouched.")
        _emit("post", "false")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(binding.as_dict(), sort_keys=True) + "\n",
                           encoding="utf-8")
    print(f"Bound report to PR #{binding.pr_number} at {binding.head_sha} "
          f"(resolved from {binding.pr_source}).")
    _emit("post", "true")
    _emit("pr_number", str(binding.pr_number))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
