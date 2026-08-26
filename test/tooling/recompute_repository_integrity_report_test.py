#!/usr/bin/env python3
"""The trusted reporter must not publish a verdict it did not compute itself.

A ``pull_request`` workflow definition comes from the merge ref, so a fork
contributor can keep the scanner's name and path, drop the step that loads the
trusted checker, and upload a findings artifact whose identity fields are the
genuine GitHub-provided ones and whose ``findings`` list is empty. Identity
binding cannot catch that -- every field it checks is honest. These tests pin
that the verdict is re-derived from trusted code instead, including the
repository-owner/same-repository bootstrap checker path used by the scanner.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts" / "check_repository_integrity.py"


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


recompute = load("recompute", "recompute_repository_integrity_report.py")
renderer = load("renderer", "render_repository_integrity_comment.py")

FORK = "attacker/Linthra"
REPOSITORY = "TheZupZup/Linthra"
OWNER = "TheZupZup"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.strip()


class ForgedArtifactTest(unittest.TestCase):
    """A fork PR that replaces the scanner and uploads a forged CLEAN report."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.work = self.repo / ".integrity"
        self.work.mkdir()
        git(self.repo, "init", "-b", "main")
        git(self.repo, "config", "user.name", "Test")
        git(self.repo, "config", "user.email", "test@example.invalid")
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n", encoding="utf-8")
        (self.repo / "lib").mkdir()
        (self.repo / "lib" / "main.dart").write_text(
            "void main() {}\n", encoding="utf-8"
        )
        # Normal path: both scanner and reporter use the checker committed at
        # the PR base.
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts" / "check_repository_integrity.py").write_bytes(
            CHECKER.read_bytes()
        )
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def contaminate(self) -> tuple[str, str]:
        """A prohibited path introduced, then cleaned up: #513's shape."""
        git(self.repo, "switch", "-c", "pr")
        workspace = self.repo / ".vscode"
        workspace.mkdir()
        (self.repo / ".gitignore").write_text(".idea/\n", encoding="utf-8")
        (workspace / "tasks.json").write_text(
            '{"version":"2.0.0"}\n', encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "A: import IDE workspace")
        offender = git(self.repo, "rev-parse", "HEAD")
        (workspace / "tasks.json").unlink()
        workspace.rmdir()
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n", encoding="utf-8")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "B: revert")
        return offender, git(self.repo, "rev-parse", "HEAD")

    def binding(
        self,
        head: str,
        *,
        head_repository: str = FORK,
        pr_author: str = "attacker",
    ) -> Path:
        path = self.work / "binding.json"
        path.write_text(
            json.dumps({
                "pr_number": 513,
                "head_sha": head,
                "head_repository": head_repository,
                "head_branch": "feat/x",
                "repository": REPOSITORY,
                "run_id": 1,
                "pr_source": "artifact",
                "base_sha": self.base,
                "pr_author": pr_author,
            }),
            encoding="utf-8",
        )
        return path

    def forged_clean(self, head: str) -> Path:
        """Genuine identity, empty findings -- what a replaced scanner uploads."""
        path = self.work / "report.json"
        path.write_text(
            json.dumps({
                "schema_version": 1,
                "pr_number": 513,
                "head_sha": head,
                "head_repository": FORK,
                "truncated": 0,
                "findings": [],
            }),
            encoding="utf-8",
        )
        return path

    def run_recompute(
        self,
        head: str,
        claimed: Path | None,
        *,
        head_repository: str = FORK,
        pr_author: str = "attacker",
    ) -> tuple[int, Path]:
        output = self.work / "verified-report.json"
        output.unlink(missing_ok=True)
        binding = self.binding(
            head,
            head_repository=head_repository,
            pr_author=pr_author,
        )
        argv = [
            "--binding",
            str(binding),
            "--output",
            str(output),
            "--summary",
            str(self.work / "verified.md"),
            "--repo-owner",
            OWNER,
            "--no-fetch",
        ]
        if claimed is not None:
            argv += ["--claimed", str(claimed)]
        previous = Path.cwd()
        os.chdir(self.repo)
        try:
            return recompute.main(argv), output
        finally:
            os.chdir(previous)

    def test_forged_clean_artifact_does_not_become_a_clean_comment(self) -> None:
        offender, head = self.contaminate()
        claimed = self.forged_clean(head)
        binding = json.loads(self.binding(head).read_text())
        forged = json.loads(claimed.read_text())
        self.assertEqual(forged["pr_number"], binding["pr_number"])
        self.assertEqual(forged["head_sha"], binding["head_sha"])
        self.assertEqual(forged["head_repository"], binding["head_repository"])
        self.assertIn("**CLEAN**", renderer.render(*renderer.validate(forged, binding)))

        exit_code, verified = self.run_recompute(head, claimed)
        self.assertEqual(exit_code, 0)
        derived = json.loads(verified.read_text())
        self.assertTrue(derived["findings"], "trusted checker found nothing")
        body = renderer.render(*renderer.validate(derived, binding))
        self.assertIn("**BLOCKED**", body)
        self.assertNotIn("**CLEAN**", body)
        self.assertIn(offender, body)
        self.assertIn(".vscode/tasks.json", body)

    def test_the_divergence_is_reported(self) -> None:
        _, head = self.contaminate()
        claimed = self.forged_clean(head)
        _, verified = self.run_recompute(head, claimed)
        message = recompute.divergence(claimed, verified)
        self.assertIsNotNone(message)
        self.assertIn("re-derived result is authoritative", message)

    def test_an_honest_clean_pr_still_renders_clean(self) -> None:
        git(self.repo, "switch", "-c", "pr")
        (self.repo / "lib" / "feature.dart").write_text(
            "const f = 1;\n", encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "ordinary work")
        head = git(self.repo, "rev-parse", "HEAD")
        exit_code, verified = self.run_recompute(head, None)
        self.assertEqual(exit_code, 0)
        derived = json.loads(verified.read_text())
        self.assertEqual(derived["findings"], [])
        body = renderer.render(
            *renderer.validate(derived, json.loads(self.binding(head).read_text()))
        )
        self.assertIn("**CLEAN**", body)

    def test_the_base_commits_checker_revision_is_the_one_that_runs(self) -> None:
        stub = (
            "#!/usr/bin/env python3\n"
            "import argparse, json\n"
            "p = argparse.ArgumentParser()\n"
            "for f in ('--base','--head','--pr-author','--repo-owner','--report',\n"
            "          '--json-report','--pr-number','--head-repository'):\n"
            "    p.add_argument(f)\n"
            "a = p.parse_args()\n"
            "open(a.report, 'w').write('stub\\n')\n"
            "json.dump({'schema_version': 1, 'pr_number': int(a.pr_number),\n"
            "           'head_sha': a.head, 'head_repository': a.head_repository,\n"
            "           'truncated': 0,\n"
            "           'findings': [{'severity': 'blocked', 'commit': a.head,\n"
            "                         'path': 'BASE-REVISION-MARKER', 'rule': 'stub',\n"
            "                         'reason': 'from the base commit',\n"
            "                         'remediation': 'none'}]},\n"
            "          open(a.json_report, 'w'))\n"
            "raise SystemExit(1)\n"
        )
        (self.repo / "scripts" / "check_repository_integrity.py").write_text(
            stub, encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "base carries a distinct checker revision")
        self.base = git(self.repo, "rev-parse", "HEAD")

        git(self.repo, "switch", "-qc", "pr")
        (self.repo / "lib" / "feature.dart").write_text(
            "const f = 1;\n", encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "ordinary work")
        head = git(self.repo, "rev-parse", "HEAD")

        exit_code, verified = self.run_recompute(head, None)
        self.assertEqual(exit_code, 0)
        derived = json.loads(verified.read_text())
        self.assertEqual(
            [f["path"] for f in derived["findings"]],
            ["BASE-REVISION-MARKER"],
        )

    def test_external_pr_cannot_bootstrap_when_base_checker_is_missing(self) -> None:
        """A fork head checker is never executable, even if it is structured."""
        git(self.repo, "rm", "-q", "scripts/check_repository_integrity.py")
        git(self.repo, "commit", "-qm", "base without a checker")
        self.base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "switch", "-qc", "pr")
        (self.repo / "scripts" / "check_repository_integrity.py").write_bytes(
            CHECKER.read_bytes()
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "fork head supplies checker")
        head = git(self.repo, "rev-parse", "HEAD")
        exit_code, verified = self.run_recompute(head, None)
        self.assertEqual(exit_code, 1)
        self.assertFalse(verified.exists())

    def test_owner_same_repo_bootstraps_when_base_checker_is_missing(self) -> None:
        """Mirror scanner bootstrap: trusted owner head may supply the checker."""
        git(self.repo, "rm", "-q", "scripts/check_repository_integrity.py")
        git(self.repo, "commit", "-qm", "base without a checker")
        self.base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "switch", "-qc", "pr")
        (self.repo / "scripts" / "check_repository_integrity.py").write_bytes(
            CHECKER.read_bytes()
        )
        (self.repo / "lib" / "feature.dart").write_text(
            "const f = 1;\n", encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "owner bootstrap checker")
        head = git(self.repo, "rev-parse", "HEAD")
        exit_code, verified = self.run_recompute(
            head,
            None,
            head_repository=REPOSITORY,
            pr_author=OWNER,
        )
        self.assertEqual(exit_code, 0)
        self.assertTrue(verified.is_file())

    def test_owner_same_repo_bootstraps_when_base_checker_is_too_old(self) -> None:
        """The missing-interface branch of scanner bootstrap is mirrored too."""
        old = (
            "#!/usr/bin/env python3\n"
            "# Legacy checker intentionally has no structured-report option.\n"
            "raise SystemExit(0)\n"
        )
        (self.repo / "scripts" / "check_repository_integrity.py").write_text(
            old, encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "legacy base checker")
        self.base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "switch", "-qc", "pr")
        (self.repo / "scripts" / "check_repository_integrity.py").write_bytes(
            CHECKER.read_bytes()
        )
        (self.repo / "lib" / "feature.dart").write_text(
            "const f = 1;\n", encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "owner upgrades checker")
        head = git(self.repo, "rev-parse", "HEAD")
        exit_code, verified = self.run_recompute(
            head,
            None,
            head_repository=REPOSITORY,
            pr_author=OWNER,
        )
        self.assertEqual(exit_code, 0)
        self.assertTrue(verified.is_file())

    def test_external_pr_cannot_bootstrap_from_old_base_checker(self) -> None:
        old = "#!/usr/bin/env python3\n# no structured interface\nraise SystemExit(0)\n"
        (self.repo / "scripts" / "check_repository_integrity.py").write_text(
            old, encoding="utf-8"
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "legacy base checker")
        self.base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "switch", "-qc", "pr")
        (self.repo / "scripts" / "check_repository_integrity.py").write_bytes(
            CHECKER.read_bytes()
        )
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", "fork tries to provide checker")
        head = git(self.repo, "rev-parse", "HEAD")
        exit_code, verified = self.run_recompute(head, None)
        self.assertEqual(exit_code, 1)
        self.assertFalse(verified.exists())

    def test_an_unusable_range_refuses_rather_than_reporting_clean(self) -> None:
        _, head = self.contaminate()
        path = self.work / "binding.json"
        path.write_text(
            json.dumps({
                "pr_number": 513,
                "head_sha": "f" * 40,
                "head_repository": FORK,
                "head_branch": "feat/x",
                "repository": REPOSITORY,
                "run_id": 1,
                "pr_source": "artifact",
                "base_sha": self.base,
                "pr_author": "attacker",
            }),
            encoding="utf-8",
        )
        output = self.work / "verified-report.json"
        previous = Path.cwd()
        os.chdir(self.repo)
        try:
            code = recompute.main([
                "--binding",
                str(path),
                "--output",
                str(output),
                "--summary",
                str(self.work / "s.md"),
                "--repo-owner",
                OWNER,
                "--no-fetch",
            ])
        finally:
            os.chdir(previous)
        self.assertEqual(code, 1)
        self.assertFalse(output.exists())


class BindingValidationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "binding.json"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, **overrides) -> Path:
        payload = {
            "pr_number": 513,
            "head_sha": "a" * 40,
            "head_repository": FORK,
            "repository": REPOSITORY,
            "run_id": 1,
            "pr_source": "artifact",
            "base_sha": "b" * 40,
            "pr_author": "someone",
        }
        payload.update(overrides)
        self.path.write_text(json.dumps(payload), encoding="utf-8")
        return self.path

    def test_bot_form_authors_are_accepted(self) -> None:
        for login in ("dependabot[bot]", "github-actions[bot]", "renovate[bot]"):
            with self.subTest(login=login):
                binding = recompute.load_binding(self.write(pr_author=login))
                self.assertEqual(binding["pr_author"], login)

    def test_every_field_the_checker_receives_is_revalidated(self) -> None:
        recompute.load_binding(self.write())
        for field, bad in (
            ("base_sha", "not-a-sha"),
            ("base_sha", None),
            ("head_sha", "../../etc/passwd"),
            ("head_sha", 7),
            ("head_repository", "a/b/c"),
            ("head_repository", ""),
            ("repository", "a/b/c"),
            ("repository", ""),
            ("repository", None),
            ("pr_author", "-leading"),
            ("pr_author", "new\nline"),
            ("pr_author", ""),
            ("pr_author", "x" * 65),
            ("pr_number", 0),
            ("pr_number", True),
            ("pr_number", "513"),
        ):
            with self.subTest(field=field, bad=bad):
                with self.assertRaises(recompute.RecomputeError):
                    recompute.load_binding(self.write(**{field: bad}))

    def test_the_checker_path_is_constrained(self) -> None:
        for bad in ("../../etc/passwd", "a/../../b", "with space", "x" * 201, ""):
            with self.subTest(bad=bad):
                with self.assertRaises(recompute.RecomputeError):
                    recompute.load_checker("a" * 40, bad, Path("/dev/null"))

    def test_the_checker_is_invoked_as_an_argument_vector(self) -> None:
        binding = recompute.load_binding(self.write())
        command = recompute.checker_command(
            Path("scripts/check_repository_integrity.py"),
            binding,
            Path("out.json"),
            Path("out.md"),
            OWNER,
        )
        self.assertIsInstance(command, list)
        self.assertEqual(command[0], sys.executable)
        for flag, value in (
            ("--base", "b" * 40),
            ("--head", "a" * 40),
            ("--pr-author", "someone"),
            ("--repo-owner", OWNER),
            ("--head-repository", FORK),
            ("--pr-number", "513"),
        ):
            self.assertEqual(command[command.index(flag) + 1], value)


class TrustBoundaryTest(unittest.TestCase):
    reporter = (ROOT / ".github/workflows/repository-integrity-reporter.yml").read_text()

    def test_the_rendered_report_is_the_re_derived_one(self) -> None:
        self.assertIn("recompute_repository_integrity_report.py", self.reporter)
        self.assertIn(
            '--report "$RUNNER_TEMP/repository-integrity/verified-report.json"',
            self.reporter,
        )
        self.assertLess(
            self.reporter.index("recompute_repository_integrity_report.py"),
            self.reporter.index("render_repository_integrity_comment.py"),
        )

    def test_the_uploaded_artifact_is_never_rendered(self) -> None:
        render = self.reporter.index("render_repository_integrity_comment.py")
        tail = self.reporter[render:]
        self.assertNotIn(
            '--report "$RUNNER_TEMP/repository-integrity/report.json"', tail
        )

    def test_checker_selection_matches_scanner_trust_policy(self) -> None:
        """Base normally wins; owner/same-repo head is the only bootstrap."""
        self.assertIn(
            "--checker-path scripts/check_repository_integrity.py", self.reporter
        )
        source = (
            ROOT / "scripts" / "recompute_repository_integrity_report.py"
        ).read_text()
        self.assertIn('f"{commit_sha}:{checker_path}"', source)
        self.assertIn('str(binding["base_sha"])', source)
        self.assertIn('head_sha=str(binding["head_sha"])', source)
        self.assertIn('pr_author == repo_owner', source)
        self.assertIn('head_repository == repository', source)
        self.assertIn("refusing to execute pull-request checker code", source)

    def test_no_pull_request_tree_is_checked_out(self) -> None:
        self.assertEqual(self.reporter.count("uses: actions/checkout"), 1)
        self.assertIn(
            "ref: ${{ github.event.repository.default_branch }}", self.reporter
        )
        self.assertNotIn(
            "ref: ${{ github.event.workflow_run.head_sha }}", self.reporter
        )
        for forbidden in ("git checkout", "git switch", "git worktree"):
            self.assertNotIn(forbidden, self.reporter)


if __name__ == "__main__":
    unittest.main()
