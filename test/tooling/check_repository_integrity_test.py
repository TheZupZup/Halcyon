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
        self.assertTrue(any("signature does not match" in f.reason for f in findings))

    def test_valid_woff2_magic_passes_signature_check(self) -> None:
        path = self.repo / "public" / "fonts" / "ok.woff2"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"wOF2" + b"\0" * 64)
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_asset_execution_command_is_blocked(self) -> None:
        path = self.repo / "docs" / "note.txt"
        path.parent.mkdir()
        path.write_text("node ./public/fonts/looks-safe.woff2\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("asset file as executable" in f.reason for f in findings))

    def test_removing_vscode_ignore_is_blocked(self) -> None:
        (self.repo / ".gitignore").write_text(".idea/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("`.vscode/` was removed" in f.reason for f in findings))

    def test_external_symlink_is_blocked(self) -> None:
        os.symlink("lib/main.dart", self.repo / "shortcut")
        findings = self.scan(self.commit())
        self.assertTrue(any("Git symlink" in f.reason for f in findings))

    def test_active_svg_is_blocked(self) -> None:
        path = self.repo / "assets" / "bad.svg"
        path.parent.mkdir()
        path.write_text('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>', encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))


if __name__ == "__main__":
    unittest.main()
