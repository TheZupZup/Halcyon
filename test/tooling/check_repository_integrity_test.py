#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_repository_integrity.py"

spec = importlib.util.spec_from_file_location("integrity", SCRIPT)
integrity = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = integrity
spec.loader.exec_module(integrity)

SELF_TEST_PATH = "test/tooling/check_repository_integrity_test.py"

# A real attack string, kept literal so the tests below exercise the production
# pattern rather than a sanitised stand-in. The trailing marker is what keeps
# the repository-wide scan of this very file from flagging it; the string
# written into a fixture repository carries no marker, so it stays detectable.
ASSET_EXECUTION_PAYLOAD = "node ./public/fonts/looks-safe.woff2\n"  # integrity-guard-fixture

# Built at runtime so this source line holds neither the payload nor the marker.
MARKED_PAYLOAD_LINE = f"{ASSET_EXECUTION_PAYLOAD.strip()}  # {integrity.FIXTURE_EXEMPTION_MARKER}"

# Script body used as a disguised-asset payload. Contains no asset extension, so
# it is inert to the text scan and needs no fixture marker of its own.
PREFIXED_SCRIPT_PAYLOAD = b"=0;\nglobal.p=require('child_process');p.exec('id');\n"


def woff2_blob(num_tables: int = 1) -> bytes:
    """A structurally valid WOFF2 header padded out to its declared length."""
    body = bytes(64)
    total = 48 + len(body)
    return (
        b"wOF2"
        + b"\x00\x01\x00\x00"
        + total.to_bytes(4, "big")
        + num_tables.to_bytes(2, "big")
        + b"\x00\x00"
        + bytes(32)
        + body
    )


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


class RepositoryIntegrityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-b", "main")
        git(self.repo, "config", "user.name", "Test")
        git(self.repo, "config", "user.email", "test@example.invalid")
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n", encoding="utf-8")
        (self.repo / "lib").mkdir()
        (self.repo / "lib" / "main.dart").write_text("void main() {}\n", encoding="utf-8")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def commit(self, message: str = "change") -> str:
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", message)
        return git(self.repo, "rev-parse", "HEAD")

    def scan(self, head: str, author: str = "external") -> list:
        old = Path.cwd()
        os.chdir(self.repo)
        try:
            return integrity.scan(self.base, head, author, "TheZupZup")
        finally:
            os.chdir(old)

    def test_clean_code_change_passes(self) -> None:
        (self.repo / "lib" / "main.dart").write_text("void main() { print('ok'); }\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_external_vscode_change_is_blocked(self) -> None:
        path = self.repo / ".vscode" / "tasks.json"
        path.parent.mkdir()
        path.write_text('{"version":"2.0.0"}\n', encoding="utf-8")
        git(self.repo, "add", "-f", ".vscode/tasks.json")
        git(self.repo, "commit", "-m", "workspace")
        head = git(self.repo, "rev-parse", "HEAD")
        findings = self.scan(head)
        self.assertTrue(any(f.path == ".vscode/tasks.json" for f in findings))

    def test_owner_can_change_maintainer_controlled_path(self) -> None:
        path = self.repo / ".vscode" / "extensions.json"
        path.parent.mkdir()
        path.write_text('{"recommendations":[]}\n', encoding="utf-8")
        git(self.repo, "add", "-f", ".vscode/extensions.json")
        git(self.repo, "commit", "-m", "owner workspace")
        head = git(self.repo, "rev-parse", "HEAD")
        findings = self.scan(head, author="TheZupZup")
        self.assertEqual(findings, [])

    def test_fake_woff2_is_blocked(self) -> None:
        path = self.repo / "public" / "fonts" / "bad.woff2"
        path.parent.mkdir(parents=True)
        path.write_text("global.r=require; console.log('not a font');\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("not a valid WOFF2" in f.reason for f in findings))

    def test_valid_woff2_passes_structural_check(self) -> None:
        path = self.repo / "public" / "fonts" / "ok.woff2"
        path.parent.mkdir(parents=True)
        path.write_bytes(woff2_blob())
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_woff2_magic_prefix_alone_is_not_enough(self) -> None:
        """A valid `wOF2` prefix in front of script is the incident's attack."""
        path = self.repo / "public" / "fonts" / "sneaky.woff2"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"wOF2" + PREFIXED_SCRIPT_PAYLOAD)
        findings = self.scan(self.commit())
        self.assertTrue(any("not a valid WOFF2" in f.reason for f in findings))

    def test_script_appended_to_a_real_font_is_blocked(self) -> None:
        path = self.repo / "public" / "fonts" / "trailer.woff2"
        path.parent.mkdir(parents=True)
        path.write_bytes(woff2_blob() + PREFIXED_SCRIPT_PAYLOAD)
        findings = self.scan(self.commit())
        self.assertTrue(any("not a valid WOFF2" in f.reason for f in findings))

    def test_png_signature_without_ihdr_is_blocked(self) -> None:
        path = self.repo / "assets" / "bad.png"
        path.parent.mkdir()
        path.write_bytes(b"\x89PNG\r\n\x1a\n" + PREFIXED_SCRIPT_PAYLOAD)
        findings = self.scan(self.commit())
        self.assertTrue(any("not a valid PNG" in f.reason for f in findings))

    def test_truncated_but_genuine_webp_is_not_flagged(self) -> None:
        """Broken assets are not this guard's business; disguised ones are."""
        path = self.repo / "assets" / "short.webp"
        path.parent.mkdir()
        path.write_bytes(b"RIFF" + (9999).to_bytes(4, "little") + b"WEBPVP8 " + bytes(32))
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_asset_execution_command_is_blocked(self) -> None:
        path = self.repo / "docs" / "note.txt"
        path.parent.mkdir()
        path.write_text(ASSET_EXECUTION_PAYLOAD, encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("asset file as executable" in f.reason for f in findings))

    def test_asset_execution_payload_is_blocked_inside_the_self_test_path(self) -> None:
        """The fixture exemption is per line, not per file."""
        path = self.repo / SELF_TEST_PATH
        path.parent.mkdir(parents=True)
        path.write_text(ASSET_EXECUTION_PAYLOAD, encoding="utf-8")
        findings = self.scan(self.commit(), author="TheZupZup")
        self.assertTrue(
            any(
                f.path == SELF_TEST_PATH and "asset file as executable" in f.reason
                for f in findings
            )
        )

    def test_external_change_to_the_guard_self_test_is_blocked(self) -> None:
        path = self.repo / SELF_TEST_PATH
        path.parent.mkdir(parents=True)
        path.write_text("import unittest\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(
            any(
                f.path == SELF_TEST_PATH and "maintainer-controlled" in f.reason
                for f in findings
            )
        )

    def test_external_composite_action_change_is_blocked(self) -> None:
        """Composite actions run from the PR head in privileged workflows."""
        path = self.repo / ".github" / "actions" / "setup-flutter" / "action.yml"
        path.parent.mkdir(parents=True)
        path.write_text("runs:\n  using: composite\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(
            any(
                f.path == ".github/actions/setup-flutter/action.yml"
                and "maintainer-controlled" in f.reason
                for f in findings
            )
        )

    def test_owner_can_change_a_composite_action(self) -> None:
        path = self.repo / ".github" / "actions" / "setup-flutter" / "action.yml"
        path.parent.mkdir(parents=True)
        path.write_text("runs:\n  using: composite\n", encoding="utf-8")
        findings = self.scan(self.commit(), author="TheZupZup")
        self.assertEqual(findings, [])

    def test_negated_vscode_ignore_is_blocked(self) -> None:
        """Git applies the last matching rule, so a later `!` undoes the entry."""
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n!.vscode/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("re-enabled by" in f.reason for f in findings))

    def test_glob_negation_of_a_protected_ignore_is_blocked(self) -> None:
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n!.vs*\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("re-enabled by" in f.reason for f in findings))

    def test_negation_before_the_entry_is_harmless(self) -> None:
        """Order matters: the positive entry comes last, so it wins."""
        (self.repo / ".gitignore").write_text(".idea/\n!.vscode/\n.vscode/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_unrelated_negation_is_allowed(self) -> None:
        (self.repo / ".gitignore").write_text(
            ".idea/\n.vscode/\nbuild/\n!build/keep.txt\n", encoding="utf-8"
        )
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_removing_vscode_ignore_is_blocked(self) -> None:
        (self.repo / ".gitignore").write_text(".idea/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("`.vscode/` was removed" in f.reason for f in findings))

    def test_external_symlink_is_blocked(self) -> None:
        os.symlink("lib/main.dart", self.repo / "shortcut")
        findings = self.scan(self.commit())
        self.assertTrue(any("Git symlink" in f.reason for f in findings))

    def test_svg_animation_event_handler_is_blocked(self) -> None:
        """Handlers outside the old five-name allowlist still execute."""
        path = self.repo / "assets" / "anim.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg"><animate onbegin="alert(1)"/></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))

    def test_inert_svg_passes(self) -> None:
        path = self.repo / "assets" / "ok.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" version="1.1">'
            '<rect width="10" height="10" fill="#0088cc"/></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_active_svg_is_blocked(self) -> None:
        path = self.repo / "assets" / "bad.svg"
        path.parent.mkdir()
        path.write_text('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>', encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))


class FixtureExemptionTest(unittest.TestCase):
    """The narrow carve-out that lets this module hold literal attack strings."""

    def test_payload_is_detected_at_an_ordinary_path(self) -> None:
        finding = integrity.asset_execution_finding("docs/note.txt", ASSET_EXECUTION_PAYLOAD)
        self.assertIsNotNone(finding)

    def test_marker_does_not_exempt_an_ordinary_path(self) -> None:
        finding = integrity.asset_execution_finding("docs/note.txt", MARKED_PAYLOAD_LINE)
        self.assertIsNotNone(finding)

    def test_marker_exempts_only_the_line_that_carries_it(self) -> None:
        text = f"{MARKED_PAYLOAD_LINE}\n{ASSET_EXECUTION_PAYLOAD}"
        self.assertIsNone(integrity.asset_execution_finding(SELF_TEST_PATH, MARKED_PAYLOAD_LINE))
        self.assertIsNotNone(integrity.asset_execution_finding(SELF_TEST_PATH, text))

    def test_marker_cannot_be_smuggled_across_a_line_break(self) -> None:
        text = f"{integrity.FIXTURE_EXEMPTION_MARKER}\n{ASSET_EXECUTION_PAYLOAD}"
        self.assertIsNotNone(integrity.asset_execution_finding(SELF_TEST_PATH, text))

    def test_this_module_does_not_trip_the_repository_wide_scan(self) -> None:
        source = (ROOT / SELF_TEST_PATH).read_text(encoding="utf-8")
        self.assertIn(ASSET_EXECUTION_PAYLOAD.strip(), source, "fixture literal went missing")
        self.assertIsNone(integrity.asset_execution_finding(SELF_TEST_PATH, source))
        self.assertIsNotNone(integrity.asset_execution_finding("docs/note.txt", source))

    def test_checker_source_does_not_trip_the_repository_wide_scan(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIsNone(
            integrity.asset_execution_finding("scripts/check_repository_integrity.py", source)
        )


if __name__ == "__main__":
    unittest.main()
