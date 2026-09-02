#!/usr/bin/env python3
"""Regression tests for quoted Flatpak finish-args in the Linux checker."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_linux_runner as checker  # noqa: E402


APP_ID = "io.example.app"


def _manifest(*, extra: str | None = None, quoted_network: bool = False) -> str:
    lines = ["app-id: io.example.app", "finish-args:"]
    for permission in sorted(checker.EXPECTED_FLATPAK_FINISH_ARGS):
        if permission == "--share=network" and quoted_network:
            lines.append('  - "--share=network" # configured providers')
        else:
            lines.append(f"  - {permission}")
    if extra is not None:
        lines.append(f"  - {extra}")
    lines.extend(("modules:", "  []", ""))
    return "\n".join(lines)


def _root_with_manifests(template: str, generated: str) -> tempfile.TemporaryDirectory:
    temporary = tempfile.TemporaryDirectory()
    root = Path(temporary.name)
    (root / "android" / "app").mkdir(parents=True)
    (root / "flatpak").mkdir(parents=True)
    (root / "android" / "app" / "build.gradle").write_text(
        f'android {{\n  defaultConfig {{\n    applicationId = "{APP_ID}"\n  }}\n}}\n',
        encoding="utf-8",
    )
    (root / "flatpak" / "flatpak-flutter.yml").write_text(
        template, encoding="utf-8"
    )
    (root / "flatpak" / f"{APP_ID}.yml").write_text(generated, encoding="utf-8")
    temporary.root = root  # type: ignore[attr-defined]
    return temporary


class QuotedFlatpakPermissionTest(unittest.TestCase):
    def test_double_quoted_filesystem_permission_is_caught(self) -> None:
        normal = _manifest()
        temporary = _root_with_manifests(
            normal,
            _manifest(extra='"--filesystem=host"'),
        )
        self.addCleanup(temporary.cleanup)

        problems = checker.flatpak_permission_problems(temporary.root)  # type: ignore[attr-defined]

        self.assertEqual(len(problems), 1)
        self.assertIn("--filesystem=host", problems[0])
        self.assertIn(f"flatpak/{APP_ID}.yml", problems[0])

    def test_single_quoted_dbus_permission_with_comment_is_caught(self) -> None:
        normal = _manifest()
        temporary = _root_with_manifests(
            normal,
            _manifest(extra="'--talk-name=org.example.Service' # comment"),
        )
        self.addCleanup(temporary.cleanup)

        problems = checker.flatpak_permission_problems(temporary.root)  # type: ignore[attr-defined]

        self.assertEqual(len(problems), 1)
        self.assertIn("--talk-name=org.example.Service", problems[0])

    def test_allowed_quoted_permission_with_comment_is_recognised(self) -> None:
        quoted = _manifest(quoted_network=True)
        temporary = _root_with_manifests(quoted, quoted)
        self.addCleanup(temporary.cleanup)

        self.assertEqual(
            checker.flatpak_permission_problems(temporary.root),  # type: ignore[attr-defined]
            [],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
