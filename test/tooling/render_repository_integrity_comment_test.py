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
        body = reporter.render(reporter.validate(payload([finding()]), EVENT))
        self.assertIn("**BLOCKED**", body)
        self.assertIn("**How to fix:** remove the prohibited path", body)
        self.assertIn(SHA, body)

    def test_multiple_findings_are_one_comment(self) -> None:
        body = reporter.render(reporter.validate(payload([finding("one"), finding("two")]), EVENT))
        self.assertEqual(body.count(reporter.MARKER), 1)
        self.assertIn("Finding 1", body)
        self.assertIn("Finding 2", body)

    def test_resolved_is_clean_with_same_marker(self) -> None:
        body = reporter.render(reporter.validate(payload([]), EVENT))
        self.assertTrue(body.startswith(reporter.MARKER))
        self.assertIn("**CLEAN**", body)

    def test_markup_and_html_are_inert(self) -> None:
        hostile = finding("</details> @everyone [click](javascript:alert(1)) `x`")
        body = reporter.render(reporter.validate(payload([hostile]), EVENT))
        self.assertNotIn("</details>", body)
        self.assertNotIn("@everyone", body)
        self.assertNotIn("(javascript:alert", body)
        self.assertIn("&#60;", body)

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
        self.assertNotIn("pull_request_target", writer)

    def test_untrusted_fields_are_never_inserted_into_commands(self) -> None:
        writer = (ROOT / ".github/workflows/repository-integrity-reporter.yml").read_text()
        self.assertNotIn("${{ github.event.workflow_run.head", writer)
        self.assertIn("fs.readFileSync(process.env.COMMENT_PATH", writer)


if __name__ == "__main__":
    unittest.main()
