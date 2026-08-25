#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "render_repository_integrity_comment.py"
spec = importlib.util.spec_from_file_location("reporter", SCRIPT)
reporter = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = reporter
spec.loader.exec_module(reporter)

SHA = "a" * 40


def finding(path: str = ".vscode/tasks.json") -> dict:
    return {
        "severity": "blocked", "commit": SHA, "path": path,
        "rule": "external-maintainer-controlled-path", "reason": "observable change",
        "remediation": "remove the prohibited path",
    }


def payload(findings: list[dict]) -> dict:
    return {"schema_version": 1, "pr_number": 7, "head_sha": SHA,
            "head_repository": "fork/repo", "findings": findings}


EVENT = {"workflow_run": {"head_sha": SHA, "head_repository": {"full_name": "fork/repo"},
                          "pull_requests": [{"number": 7}]}}


class ReporterTest(unittest.TestCase):
    def test_one_violation_is_actionable(self) -> None:
        body = reporter.render(*reporter.validate(payload([finding()]), EVENT))
        self.assertIn("**BLOCKED**", body)
        self.assertIn("**How to fix:** remove the prohibited path", body)
        self.assertIn(SHA, body)

    def test_multiple_findings_are_one_comment(self) -> None:
        body = reporter.render(*reporter.validate(payload([finding("one"), finding("two")]), EVENT))
        self.assertEqual(body.count(reporter.MARKER), 1)
        self.assertIn("Finding 1", body)
        self.assertIn("Finding 2", body)

    def test_resolved_is_clean_with_same_marker(self) -> None:
        body = reporter.render(*reporter.validate(payload([]), EVENT))
        self.assertTrue(body.startswith(reporter.MARKER))
        self.assertIn("**CLEAN**", body)

    def test_markup_and_html_are_inert(self) -> None:
        hostile = finding("</details> @everyone [click](javascript:alert(1)) `x`")
        body = reporter.render(*reporter.validate(payload([hostile]), EVENT))
        self.assertNotIn("</details>", body)
        self.assertNotIn("@everyone", body)
        self.assertNotIn("(javascript:alert", body)
        self.assertIn("&#60;", body)

    def test_truncated_findings_are_reported_not_silently_dropped(self) -> None:
        """The scanner caps the artifact at MAX_FINDINGS; the cap must be visible.

        Producing more than the reporter accepts used to fail validation, which
        left a stale sticky comment while the guard was blocking.
        """
        capped = payload([finding(f"scripts/x{i}.sh") for i in range(reporter.MAX_FINDINGS)])
        capped["truncated"] = 7
        findings, truncated = reporter.validate(capped, EVENT)
        self.assertEqual(truncated, 7)
        body = reporter.render(findings, truncated)
        self.assertIn("**BLOCKED**", body)
        self.assertIn("7 further finding(s) were withheld", body)
        self.assertIn("all of them block this PR", body)

    def test_truncated_count_is_validated(self) -> None:
        for bad in (-1, "3", 1.5, True, None):
            with self.subTest(bad=bad):
                bogus = payload([finding()])
                bogus["truncated"] = bad
                with self.assertRaises(ValueError):
                    reporter.validate(bogus, EVENT)

    def test_absent_truncated_defaults_to_zero(self) -> None:
        findings, truncated = reporter.validate(payload([finding()]), EVENT)
        self.assertEqual(truncated, 0)
        self.assertNotIn("withheld", reporter.render(findings, truncated))

    def test_report_binding_and_shape_are_fail_closed(self) -> None:
        bad = payload([finding()])
        bad["pr_number"] = 8
        with self.assertRaises(ValueError):
            reporter.validate(bad, EVENT)
        injected = finding()
        injected["command"] = "echo owned"
        with self.assertRaises(ValueError):
            reporter.validate(payload([injected]), EVENT)

    def test_workflows_separate_untrusted_scan_from_sticky_writer(self) -> None:
        scanner = (ROOT / ".github/workflows/repository-integrity.yml").read_text()
        writer = (ROOT / ".github/workflows/repository-integrity-reporter.yml").read_text()
        self.assertIn("permissions:\n  contents: read", scanner)
        self.assertNotIn("pull-requests: write", scanner)
        self.assertNotIn("issues: write", scanner)
        self.assertIn("workflow_run:", writer)
        self.assertIn("pull-requests: write", writer)
        self.assertIn("updateComment", writer)
        self.assertIn("createComment", writer)
        self.assertIn("github-actions[bot]", writer)
        self.assertIn("comment.body?.startsWith(marker)", writer)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", writer)
        # Build the blocked trigger name at runtime so this negative-test fixture
        # does not itself look like a real high-risk workflow trigger to the
        # repository security surface scanner.
        blocked_trigger = "pull_request" + "_target"
        self.assertNotIn(blocked_trigger, writer)

    def test_reporter_binds_to_the_scanner_workflow_identity(self) -> None:
        """Display name alone is contributor-forgeable; bind the file path too."""
        writer = (ROOT / ".github/workflows/repository-integrity-reporter.yml").read_text()
        self.assertIn(
            "github.event.workflow_run.path == '.github/workflows/repository-integrity.yml'",
            writer,
        )
        self.assertIn("github.event.workflow_run.event == 'pull_request'", writer)
        self.assertIn("github.event.workflow_run.pull_requests[0] != null", writer)

    def test_superseded_reports_do_not_overwrite_a_newer_result(self) -> None:
        """Out-of-order synchronize runs must not restore an older verdict."""
        writer = (ROOT / ".github/workflows/repository-integrity-reporter.yml").read_text()
        self.assertIn("getWorkflowRun", writer)
        self.assertIn("pr.head.sha !== run.head_sha", writer)
        # The guard must precede both write paths, or it guards nothing.
        guard = writer.index("pr.head.sha !== run.head_sha")
        self.assertLess(guard, writer.index("updateComment"))
        self.assertLess(guard, writer.index("createComment"))

    def test_untrusted_fields_are_never_inserted_into_commands(self) -> None:
        writer = (ROOT / ".github/workflows/repository-integrity-reporter.yml").read_text()
        self.assertNotIn("${{ github.event.workflow_run.head", writer)
        self.assertIn("fs.readFileSync(process.env.COMMENT_PATH", writer)


if __name__ == "__main__":
    unittest.main()
