#!/usr/bin/env python3
"""Regression tests for the fork-pull-request binding in the trusted reporter.

Every case here answers one question: given an artifact that claims to describe
a pull request, may the reporter write a comment, and on which pull request.
The claim is never the answer on its own.
"""
from __future__ import annotations

import copy
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "resolve_repository_integrity_pr.py"
spec = importlib.util.spec_from_file_location("binder", SCRIPT)
binder = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = binder
spec.loader.exec_module(binder)

REPOSITORY = "TheZupZup/Linthra"
FORK = "Borhan2004/Linthra"
# The real head of PR #513, the incident this recovery path was built for.
HEAD_SHA = "a9ecac5b6a94159c590ccb51e09f5a00ac14f796"
NEWER_SHA = "b" * 40
RUN_ID = 32887057547
PR_NUMBER = 513


def event(*, pull_requests: list[dict] | None = None, **overrides) -> dict:
    run = {
        "id": RUN_ID,
        "name": "Repository integrity",
        "path": ".github/workflows/repository-integrity.yml",
        "event": "pull_request",
        "head_sha": HEAD_SHA,
        "head_repository": {"full_name": FORK},
        "repository": {"full_name": REPOSITORY},
        # GitHub delivers this empty for every fork-originated run.
        "pull_requests": [] if pull_requests is None else pull_requests,
    }
    run.update(overrides)
    return {"workflow_run": run, "repository": {"full_name": REPOSITORY}}


def report(**overrides) -> dict:
    payload = {
        "schema_version": 1,
        "pr_number": PR_NUMBER,
        "head_sha": HEAD_SHA,
        "head_repository": FORK,
        "truncated": 0,
        "findings": [],
    }
    payload.update(overrides)
    return payload


def pull_request(*, number: int = PR_NUMBER, head_sha: str = HEAD_SHA,
                 head_repository: str | None = FORK,
                 base_repository: str = REPOSITORY) -> dict:
    head_repo = {"full_name": head_repository} if head_repository is not None else None
    return {
        "number": number,
        "head": {"sha": head_sha, "repo": head_repo},
        "base": {"repo": {"full_name": base_repository}},
    }


class Api:
    """Records every path requested so URL construction can be asserted on."""

    def __init__(self, *, pulls: dict | None = None, associated: list | None = None) -> None:
        self.pulls = pulls if pulls is not None else pull_request()
        self.associated = associated if associated is not None else [pull_request()]
        self.paths: list[str] = []

    def __call__(self, path: str) -> object:
        self.paths.append(path)
        if path.endswith("/pulls"):
            return self.associated
        return self.pulls


def decide(event_payload: dict, report_payload: dict, api: Api | None = None):
    api = api or Api()
    return binder.decide(event_payload, report_payload, REPOSITORY, api), api


class ForkRecoveryTest(unittest.TestCase):
    def test_empty_pull_requests_resolves_the_external_fork_pr(self) -> None:
        """The reported incident: a fork run GitHub gives no pull request for."""
        (binding, may_write), api = decide(event(), report())
        self.assertEqual(binding.pr_number, PR_NUMBER)
        self.assertEqual(binding.pr_source, "artifact")
        self.assertEqual(binding.head_repository, FORK)
        self.assertTrue(may_write)
        self.assertEqual(api.paths, [
            f"/repos/{REPOSITORY}/commits/{HEAD_SHA}/pulls",
            f"/repos/{REPOSITORY}/pulls/{PR_NUMBER}",
        ])

    def test_same_repository_run_still_binds_to_the_named_pr(self) -> None:
        """The pre-existing path must keep working, and keep winning."""
        (binding, may_write), _ = decide(
            event(pull_requests=[{"number": PR_NUMBER}]), report())
        self.assertEqual(binding.pr_source, "workflow_run")
        self.assertTrue(may_write)
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(pull_requests=[{"number": PR_NUMBER}]),
                           report(pr_number=PR_NUMBER + 1), REPOSITORY)

    def test_forged_pr_number_is_rejected(self) -> None:
        """An artifact naming somebody else's PR must not reach that PR."""
        victim = 999
        api = Api(pulls=pull_request(number=victim, head_repository="victim/Linthra"),
                  associated=[pull_request()])
        with self.assertRaises(binder.BindingError):
            decide(event(), report(pr_number=victim), api)

    def test_republished_head_commit_cannot_address_the_victim_pr(self) -> None:
        """Pushing another contributor's head into your own fork collides on SHA.

        The head *repository* does not collide, so narrowing by it leaves only
        the attacker's own pull request and the forged number is refused.
        """
        victim = 999
        api = Api(
            pulls=pull_request(number=victim, head_repository="victim/Linthra"),
            associated=[pull_request(number=PR_NUMBER),
                        pull_request(number=victim, head_repository="victim/Linthra")],
        )
        with self.assertRaises(binder.BindingError):
            decide(event(), report(pr_number=victim), api)
        # The attacker's own pull request is still resolvable, which is harmless.
        (binding, _), _ = decide(event(), report(), Api(
            pulls=pull_request(),
            associated=list(api.associated),
        ))
        self.assertEqual(binding.pr_number, PR_NUMBER)

    def test_head_sha_mismatch_is_rejected(self) -> None:
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(), report(head_sha=NEWER_SHA), REPOSITORY)

    def test_head_repository_mismatch_is_rejected(self) -> None:
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(), report(head_repository="attacker/Linthra"), REPOSITORY)
        # ...including when only the live pull request disagrees.
        api = Api(pulls=pull_request(head_repository="someone-else/Linthra"))
        with self.assertRaises(binder.BindingError):
            decide(event(), report(), api)

    def test_artifact_from_another_workflow_run_is_rejected(self) -> None:
        """A report from a different run cannot match this run's head identity."""
        other = report(pr_number=42, head_sha=NEWER_SHA, head_repository="other/Linthra")
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(), other, REPOSITORY)

    def test_unexpected_scanner_workflow_path_is_rejected(self) -> None:
        for field, value in (
            ("path", ".github/workflows/contributor-supplied.yml"),
            ("name", "Repository integrity reporter"),
            ("event", "push"),
            ("repository", {"full_name": "attacker/Linthra"}),
        ):
            with self.subTest(field=field):
                with self.assertRaises(binder.BindingError):
                    binder.resolve(event(**{field: value}), report(), REPOSITORY)
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(), report(), "attacker/Linthra")

    def test_stale_head_after_synchronize_does_not_overwrite(self) -> None:
        """A superseded report is not an error; it just must not be written."""
        # The association query reports the PR at its *current* head, so the
        # candidate filter must not depend on the scanned SHA or a superseded
        # report would become a hard failure instead of a quiet skip.
        api = Api(pulls=pull_request(head_sha=NEWER_SHA),
                  associated=[pull_request(head_sha=NEWER_SHA)])
        (binding, may_write), _ = decide(event(), report(), api)
        self.assertEqual(binding.pr_number, PR_NUMBER)
        self.assertFalse(may_write)

    def test_more_than_one_plausible_pr_is_refused(self) -> None:
        for label, associated in (
            ("two from the same fork", [pull_request(number=PR_NUMBER),
                                        pull_request(number=PR_NUMBER + 1)]),
            ("none", []),
            ("only foreign forks", [pull_request(head_repository="other/Linthra")]),
            ("only foreign bases", [pull_request(base_repository="other/Linthra")]),
        ):
            with self.subTest(label):
                with self.assertRaises(binder.BindingError):
                    decide(event(), report(), Api(associated=associated))
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(pull_requests=[{"number": 1}, {"number": 2}]),
                           report(), REPOSITORY)

    def test_malicious_strings_cannot_reach_an_api_path(self) -> None:
        """Identity fields are re-derived, so hostile text never forms a URL."""
        hostile = (
            "../../../../repos/attacker/Linthra/pulls/1",
            "a" * 39 + "\n",
            "TheZupZup/Linthra?x=1",
            "$(id)",
            "'; echo owned; '",
            "",
        )
        for value in hostile:
            with self.subTest(value=value[:24]):
                with self.assertRaises(binder.BindingError):
                    binder.resolve(event(), report(head_sha=value), REPOSITORY)
                with self.assertRaises(binder.BindingError):
                    binder.resolve(event(), report(head_repository=value), REPOSITORY)
                with self.assertRaises(binder.BindingError):
                    binder.resolve(event(), report(pr_number=value), REPOSITORY)
        api = Api()
        decide(event(), report(), api)
        for path in api.paths:
            self.assertTrue(path.startswith(f"/repos/{REPOSITORY}/"), path)
            self.assertNotIn("..", path)
            self.assertNotIn("?", path)

    def test_non_integer_and_out_of_range_identifiers_are_rejected(self) -> None:
        for bad in (0, -1, True, 1.5, None, 10**9):
            with self.subTest(bad=bad):
                with self.assertRaises(binder.BindingError):
                    binder.resolve(event(), report(pr_number=bad), REPOSITORY)
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(), report(schema_version=2), REPOSITORY)
        with self.assertRaises(binder.BindingError):
            binder.resolve(event(), "not a report", REPOSITORY)
        with self.assertRaises(binder.BindingError):
            binder.resolve({"workflow_run": None, "repository": {"full_name": REPOSITORY}},
                           report(), REPOSITORY)

    def test_pull_request_from_a_deleted_fork_is_refused(self) -> None:
        api = Api(pulls=pull_request(head_repository=None))
        with self.assertRaises(binder.BindingError):
            decide(event(), report(), api)

    def test_api_returning_a_different_pr_is_refused(self) -> None:
        api = Api(pulls=pull_request(number=PR_NUMBER + 1))
        with self.assertRaises(binder.BindingError):
            decide(event(), report(), api)

    def test_event_payload_is_not_mutated(self) -> None:
        payload = event()
        original = copy.deepcopy(payload)
        binder.resolve(payload, report(), REPOSITORY)
        self.assertEqual(payload, original)


class TrustBoundaryTest(unittest.TestCase):
    """Properties of the workflows themselves that the binder relies on."""

    scanner = (ROOT / ".github/workflows/repository-integrity.yml").read_text()
    reporter = (ROOT / ".github/workflows/repository-integrity-reporter.yml").read_text()

    def test_no_high_risk_trigger_anywhere_in_workflows(self) -> None:
        # Assembled at runtime so this assertion is not itself a literal
        # high-risk trigger in a file the PR security surface scanner reads.
        blocked_trigger = "pull_request" + "_target"
        for workflow in sorted((ROOT / ".github/workflows").glob("*.yml")):
            with self.subTest(workflow.name):
                self.assertNotIn(blocked_trigger, workflow.read_text())

    def test_scanner_has_no_write_token(self) -> None:
        self.assertIn("permissions:\n  contents: read", self.scanner)
        for grant in ("pull-requests: write", "issues: write", "contents: write",
                      "actions: write", "write-all"):
            self.assertNotIn(grant, self.scanner)
        self.assertIn("persist-credentials: false", self.scanner)

    def test_reporter_never_checks_out_pr_head(self) -> None:
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", self.reporter)
        self.assertNotIn("github.event.workflow_run.head_branch", self.reporter)
        self.assertNotIn("ref: ${{ github.event.workflow_run.head_sha }}", self.reporter)
        # The only checkout in the reporter is the trusted default branch one.
        self.assertEqual(self.reporter.count("uses: actions/checkout"), 1)
        self.assertEqual(self.reporter.count("ref: "), 1)

    def test_reporter_reaches_the_binder_on_fork_runs(self) -> None:
        """The job condition must not skip before the artifact is inspected."""
        self.assertNotIn("pull_requests[0]", self.reporter)
        self.assertIn("github.event.workflow_run.event == 'pull_request'", self.reporter)
        self.assertIn(
            "github.event.workflow_run.path == '.github/workflows/repository-integrity.yml'",
            self.reporter)
        self.assertIn("github.event.workflow_run.name == 'Repository integrity'",
                      self.reporter)
        self.assertIn("github.event.workflow_run.repository.full_name == github.repository",
                      self.reporter)

    def test_only_a_genuinely_absent_artifact_is_suppressed(self) -> None:
        """Draft pull requests skip the guard job, so no artifact is uploaded.

        Tolerating a failed download instead would swallow every other reason
        the report can be missing -- a transport error, an expired artifact, a
        scan that died before uploading -- and finish green, leaving an earlier
        sticky verdict standing over a scan that was never rendered. Absence is
        therefore established from the Actions API, before downloading.
        """
        self.assertIn("listWorkflowRunArtifacts", self.reporter)
        self.assertIn("a.name === 'repository-integrity-findings'", self.reporter)
        self.assertIn("steps.artifact.outputs.present == 'true'", self.reporter)
        # Nothing in the reporter may swallow a failure. Matched per line so a
        # comment mentioning the key cannot satisfy or defeat the assertion.
        self.assertEqual(
            [line for line in self.reporter.splitlines()
             if line.strip().startswith("continue-on-error")], [])
        # The check must precede the download it guards.
        self.assertLess(self.reporter.index("listWorkflowRunArtifacts"),
                        self.reporter.index("uses: actions/download-artifact"))

    def test_reporter_downloads_only_this_run_and_binds_before_writing(self) -> None:
        self.assertIn("run-id: ${{ github.event.workflow_run.id }}", self.reporter)
        self.assertIn("scripts/resolve_repository_integrity_pr.py", self.reporter)
        self.assertIn("PR_NUMBER: ${{ steps.bind.outputs.pr_number }}", self.reporter)
        bind = self.reporter.index("scripts/resolve_repository_integrity_pr.py")
        for write in ("updateComment", "createComment"):
            self.assertLess(bind, self.reporter.index(write))

    def test_binder_pins_the_scanner_workflow_identity(self) -> None:
        self.assertTrue((ROOT / binder.SCANNER_WORKFLOW_PATH).is_file())
        self.assertIn(f"name: {binder.SCANNER_WORKFLOW_NAME}\n", self.scanner)
        self.assertIn(f"workflows: [{binder.SCANNER_WORKFLOW_NAME}]", self.reporter)
        self.assertIn(f"'{binder.SCANNER_WORKFLOW_PATH}'", self.reporter)
        self.assertEqual(binder.SCANNER_EVENT, "pull_request")
        self.assertIn(f"'{binder.SCANNER_EVENT}'", self.reporter)


if __name__ == "__main__":
    unittest.main()
