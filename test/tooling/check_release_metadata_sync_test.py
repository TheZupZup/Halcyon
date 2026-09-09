#!/usr/bin/env python3
"""Unit tests for scripts/check_release_metadata_sync.py (#452).

    python3 test/tooling/check_release_metadata_sync_test.py

The script's whole job is to notice that two files disagree about the release
version, so every test builds a small fixture checkout, breaks exactly one of
those files, and asserts the disagreement is reported (and that a matching
checkout reports nothing). Fixtures are written to a temporary directory: the
real repository is never touched, and nothing here runs git, builds, or reaches
the network.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

sys.path.insert(0, str(SCRIPTS))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


checker = _load("check_release_metadata_sync", "check_release_metadata_sync.py")

APP_ID = "io.github.thezupzup.linthra"

METAINFO = """<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>{app_id}</id>
  <releases>
{entries}
  </releases>
</component>
"""

FDROID = """Name: Linthra
RepoType: git
VercodeOperation:
  - "%c*10 + 1"
  - "%c*10 + 2"
  - "%c*10 + 3"

CurrentVersion: {version}
CurrentVersionCode: {code}
"""


def metainfo(entries):
    return METAINFO.format(app_id=APP_ID, entries="\n".join(entries))


class FixtureRepo:
    """A checkout with just the files the checker reads."""

    def __init__(self, root: Path):
        self.root = root

    def write(self, relative: str, content: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def problems(self, tag: str | None = None) -> list[str]:
        return checker.check(self.root, tag)


class SyncTest(unittest.TestCase):
    def repo(
        self,
        *,
        version: str = "0.2.6",
        code: int = 206999,
        app_info_version: str | None = None,
        changelog_code: int | None = None,
        fdroid_version: str | None = None,
        fdroid_code: int | None = None,
        releases: list[str] | None = None,
        flatpak: str | None = None,
    ) -> FixtureRepo:
        directory = Path(tempfile.mkdtemp(prefix="release_metadata_sync_"))
        self.addCleanup(_rmtree, directory)
        repo = FixtureRepo(directory)

        repo.write("pubspec.yaml", f"name: linthra\nversion: {version}+{code}\n")
        repo.write(
            "lib/core/app_info.dart",
            "abstract final class AppInfo {\n"
            f"  static const String _devVersionName = '{app_info_version or version}';\n"
            "}\n",
        )
        repo.write(
            "fastlane/metadata/android/en-US/changelogs/"
            f"{changelog_code if changelog_code is not None else code}.txt",
            "Linthra maintenance update.\n",
        )
        repo.write(
            f"metadata/{APP_ID}.yml",
            FDROID.format(
                version=fdroid_version or version,
                code=fdroid_code if fdroid_code is not None else code * 10 + 3,
            ),
        )
        repo.write(
            f"linux/packaging/{APP_ID}.metainfo.xml",
            metainfo(
                releases
                if releases is not None
                else [f'    <release version="{version}" date="2026-09-08"/>']
            ),
        )
        if flatpak is not None:
            repo.write(f"flatpak/{APP_ID}.yml", flatpak)
        return repo

    def test_a_consistent_checkout_reports_nothing(self):
        self.assertEqual(self.repo().problems(), [])

    def test_matching_tag_reports_nothing(self):
        self.assertEqual(self.repo().problems("v0.2.6"), [])

    def test_mismatched_tag_is_reported(self):
        problems = self.repo().problems("v0.2.5")
        self.assertEqual(len(problems), 1)
        self.assertIn("does not match pubspec version 0.2.6", problems[0])

    def test_hand_edited_version_code_is_reported(self):
        problems = self.repo(code=206000).problems()
        self.assertTrue(any("expected 206999" in p for p in problems), problems)

    def test_about_screen_version_drift_is_reported(self):
        problems = self.repo(app_info_version="0.2.5").problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("_devVersionName is 0.2.5", problems[0])

    def test_missing_play_changelog_is_reported(self):
        problems = self.repo(changelog_code=205999).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("206999.txt is missing", problems[0])

    def test_empty_play_changelog_is_reported(self):
        repo = self.repo()
        repo.write("fastlane/metadata/android/en-US/changelogs/206999.txt", "\n")
        problems = repo.problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("is empty", problems[0])

    def test_fdroid_version_drift_is_reported(self):
        problems = self.repo(fdroid_version="0.2.5").problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("CurrentVersion is 0.2.5", problems[0])

    def test_fdroid_untransformed_version_code_is_reported(self):
        # The base code, not the highest per-ABI code F-Droid actually records.
        problems = self.repo(fdroid_code=206999).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("expected 2069993", problems[0])

    def test_missing_fdroid_metadata_is_not_an_error(self):
        repo = self.repo()
        (repo.root / "metadata" / f"{APP_ID}.yml").unlink()
        self.assertEqual(repo.problems(), [])

    def test_stale_appstream_entry_is_reported(self):
        problems = self.repo(
            releases=['    <release version="0.2.5" date="2026-09-06"/>']
        ).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("newest <release> is 0.2.5", problems[0])

    def test_entries_listed_oldest_first_are_reported(self):
        problems = self.repo(
            releases=[
                '    <release version="0.2.5" date="2026-09-06"/>',
                '    <release version="0.2.6" date="2026-09-08"/>',
            ]
        ).problems()
        self.assertTrue(any("newest first" in p for p in problems), problems)

    def test_duplicate_entry_is_reported(self):
        problems = self.repo(
            releases=[
                '    <release version="0.2.6" date="2026-09-08"/>',
                '    <release version="0.2.6" date="2026-09-07"/>',
            ]
        ).problems()
        self.assertTrue(any("listed twice" in p for p in problems), problems)

    def test_entry_without_a_date_is_reported(self):
        problems = self.repo(releases=['    <release version="0.2.6"/>']).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("has no date", problems[0])

    def test_malformed_date_is_reported(self):
        problems = self.repo(
            releases=['    <release version="0.2.6" date="08/09/2026"/>']
        ).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("Malformed release date", problems[0])

    def test_prerelease_without_the_development_marker_is_reported(self):
        problems = self.repo(
            version="0.3.0-beta.1",
            code=300301,
            releases=['    <release version="0.3.0-beta.1" date="2026-09-09"/>'],
        ).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn('type="development"', problems[0])

    def test_prerelease_with_the_development_marker_is_accepted(self):
        problems = self.repo(
            version="0.3.0-beta.1",
            code=300301,
            releases=[
                '    <release version="0.3.0-beta.1" date="2026-09-09" '
                'type="development"/>'
            ],
        ).problems()
        self.assertEqual(problems, [])

    def test_stable_release_marked_as_development_is_reported(self):
        problems = self.repo(
            releases=[
                '    <release version="0.2.6" date="2026-09-08" type="development"/>'
            ]
        ).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("marked", problems[0])

    def test_an_entry_that_wraps_a_description_is_read_as_one_entry(self):
        # AppStream allows child elements inside a <release>. The attributes
        # that matter are the opening tag's, and a <url type="..."> inside the
        # description must not be mistaken for one of them.
        problems = self.repo(
            releases=[
                '    <release version="0.2.6" date="2026-09-08">',
                "      <description>",
                "        <p>Folder browsing.</p>",
                "      </description>",
                '      <url type="details">https://example.invalid/notes</url>',
                "    </release>",
                '    <release version="0.2.5" date="2026-09-06"/>',
            ]
        ).problems()
        self.assertEqual(problems, [])

    def test_missing_releases_block_is_reported(self):
        repo = self.repo()
        repo.write(
            f"linux/packaging/{APP_ID}.metainfo.xml",
            f'<component type="desktop-application">\n  <id>{APP_ID}</id>\n</component>\n',
        )
        problems = repo.problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("no <releases> block", problems[0])

    def test_dir_source_manifest_has_no_version_to_drift(self):
        problems = self.repo(
            flatpak="modules:\n"
            "  - name: linthra\n"
            "    sources:\n"
            "      - type: dir\n"
            "        path: ..\n"
            "      - type: git\n"
            "        url: https://github.com/flutter/flutter.git\n"
            "        tag: '3.44.7'\n"
            "        dest: flutter\n"
        ).problems()
        self.assertEqual(problems, [])

    def test_manifest_pinned_to_another_release_is_reported(self):
        problems = self.repo(
            flatpak="modules:\n"
            "  - name: linthra\n"
            "    sources:\n"
            "      - type: git\n"
            "        url: https://github.com/TheZupZup/Linthra.git\n"
            "        tag: v0.2.4\n"
        ).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("pinned to v0.2.4, expected v0.2.6", problems[0])

    def test_manifest_source_without_a_tag_is_reported(self):
        # The quiet version of the same drift: nothing says which release the
        # manifest builds, so there is no synchronization to confirm.
        problems = self.repo(
            flatpak="modules:\n"
            "  - name: linthra\n"
            "    sources:\n"
            "      - type: git\n"
            "        url: https://github.com/TheZupZup/Linthra.git\n"
            "      - type: git\n"
            "        url: https://github.com/flutter/flutter.git\n"
            "        tag: '3.44.7'\n"
            "        dest: flutter\n"
        ).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("no tag:", problems[0])
        # Not the Flutter SDK's tag from the source below it.
        self.assertNotIn("3.44.7", problems[0])

    def test_a_commented_out_source_is_not_read_as_one(self):
        problems = self.repo(
            flatpak="modules:\n"
            "  - name: linthra\n"
            "    sources:\n"
            "      # url: https://github.com/TheZupZup/Linthra.git\n"
            "      - type: dir\n"
            "        path: ..\n"
        ).problems()
        self.assertEqual(problems, [])

    def test_manifest_pinned_to_this_release_is_accepted(self):
        problems = self.repo(
            flatpak="modules:\n"
            "  - name: linthra\n"
            "    sources:\n"
            "      - type: git\n"
            "        url: https://github.com/TheZupZup/Linthra.git\n"
            "        tag: v0.2.6\n"
        ).problems()
        self.assertEqual(problems, [])

    def test_main_exits_non_zero_and_names_the_fix(self):
        repo = self.repo(app_info_version="0.2.5")
        self.assertEqual(
            checker.main(["--repo-root", str(repo.root)]),
            1,
        )

    def test_main_offers_a_fix_that_works_with_written_release_notes(self):
        # Reported drift is often AppStream-only, next to a hand-written Play
        # changelog. Without --keep-changelog the bump script refuses rather
        # than touch those notes, so the advertised fix has to name it.
        repo = self.repo(app_info_version="0.2.5")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(checker.main(["--repo-root", str(repo.root)]), 1)
        message = stderr.getvalue()
        self.assertIn("prepare_release_bump.py", message)
        self.assertIn("--keep-changelog", message)

    def test_main_exits_zero_on_a_consistent_checkout(self):
        repo = self.repo()
        self.assertEqual(checker.main(["--repo-root", str(repo.root)]), 0)

    def test_the_real_repository_is_in_sync(self):
        # The point of the script: this repository, right now.
        self.assertEqual(checker.check(ROOT), [])


def _rmtree(path: Path) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
