import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


announcement = _load_module(
    "reddit_release_announcement",
    ROOT / "scripts" / "reddit_release_announcement.py",
)
poster = _load_module(
    "post_reddit_release",
    ROOT / "scripts" / "post_reddit_release.py",
)


def _release(**overrides):
    data = {
        "tag_name": "v0.2.2",
        "name": "Linthra v0.2.2",
        "html_url": "https://github.com/TheZupZup/Linthra/releases/tag/v0.2.2",
        "body": (
            "# Linthra v0.2.2\n\n"
            "## What's new\n\n"
            "- **Smoother lyrics** while following timed lines.\n"
            "- The `seek bar` no longer jumps backwards after a seek.\n"
            "- [Dependency updates](https://example.invalid) are easier to review.\n"
        ),
        "draft": False,
        "prerelease": False,
        "published_at": "2026-08-14T12:00:00Z",
    }
    data.update(overrides)
    return data


class AnnouncementTests(unittest.TestCase):
    def setUp(self):
        self.voice = announcement.load_voice(
            ROOT / "scripts" / "reddit_release_voice.json"
        )

    def test_stable_published_release_produces_post(self):
        result = announcement.build_announcement(_release(), self.voice)
        self.assertEqual(result["title"], "Linthra v0.2.2 is out 🎵")
        self.assertIn("Smoother lyrics", result["body"])
        self.assertIn(result["release_url"], result["body"])

    def test_prerelease_is_rejected(self):
        with self.assertRaises(announcement.AnnouncementError):
            announcement.build_announcement(
                _release(tag_name="v0.2.3-beta.1", prerelease=True), self.voice
            )

    def test_draft_is_rejected(self):
        with self.assertRaises(announcement.AnnouncementError):
            announcement.build_announcement(_release(draft=True), self.voice)

    def test_empty_release_body_is_still_sensible(self):
        result = announcement.build_announcement(_release(body=""), self.voice)
        self.assertIn("full details are in the GitHub release", result["body"])
        self.assertIn(result["release_url"], result["body"])

    def test_maximum_bullet_count_is_respected(self):
        body = "## What's new\n\n" + "\n".join(
            f"- change number {index}" for index in range(1, 20)
        )
        result = announcement.build_announcement(_release(body=body), self.voice)
        bullets = [line for line in result["body"].splitlines() if line.startswith("- ")]
        self.assertEqual(len(bullets), self.voice["max_bullets"])

    def test_long_release_notes_are_shortened(self):
        long_item = "x" * 500
        result = announcement.build_announcement(
            _release(body=f"## What's new\n\n- {long_item}"), self.voice
        )
        bullet = next(
            line for line in result["body"].splitlines() if line.startswith("- ")
        )
        self.assertLessEqual(len(bullet), 182)
        self.assertTrue(bullet.endswith("…"))
        self.assertLess(len(result["body"]), announcement.MAX_BODY_CHARS)

    def test_markdown_is_cleaned_without_breaking_reddit_formatting(self):
        result = announcement.build_announcement(_release(), self.voice)
        self.assertNotIn("**Smoother lyrics**", result["body"])
        self.assertNotIn("`seek bar`", result["body"])
        self.assertNotIn("](https://example.invalid)", result["body"])
        self.assertIn("- Smoother lyrics while following timed lines.", result["body"])
        self.assertIn("- The seek bar no longer jumps backwards after a seek.", result["body"])

    def test_secrets_never_enter_generated_output(self):
        secret_values = {
            "REDDIT_CLIENT_ID": "client-secret-marker",
            "REDDIT_CLIENT_SECRET": "client-secret-value-marker",
            "REDDIT_REFRESH_TOKEN": "refresh-token-marker",
        }
        with mock.patch.dict(os.environ, secret_values, clear=False):
            result = announcement.build_announcement(_release(), self.voice)
        serialized = json.dumps(result)
        for value in secret_values.values():
            self.assertNotIn(value, serialized)

    def test_title_and_body_stay_inside_conservative_limits(self):
        result = announcement.build_announcement(_release(), self.voice)
        self.assertLessEqual(len(result["title"]), announcement.MAX_TITLE_CHARS)
        self.assertLessEqual(len(result["body"]), announcement.MAX_BODY_CHARS)

    def test_cli_writes_preview_files_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            release_path = tmp_path / "release.json"
            output = tmp_path / "out"
            release_path.write_text(json.dumps(_release()), encoding="utf-8")
            code = announcement.main(
                [
                    "--release-json",
                    str(release_path),
                    "--voice-config",
                    str(ROOT / "scripts" / "reddit_release_voice.json"),
                    "--output-dir",
                    str(output),
                ]
            )
            self.assertEqual(code, 0)
            self.assertTrue((output / "title.txt").exists())
            self.assertTrue((output / "body.md").exists())
            self.assertTrue((output / "announcement.json").exists())


class PostingSafetyTests(unittest.TestCase):
    def test_duplicate_release_url_skips_submission(self):
        listing = {
            "data": {
                "children": [
                    {
                        "data": {
                            "selftext": (
                                "GitHub release:\n"
                                "https://github.com/TheZupZup/Linthra/releases/tag/v0.2.2"
                            ),
                            "permalink": "/r/Linthra/comments/example/release/",
                        }
                    }
                ]
            }
        }
        with mock.patch.object(poster, "_request_json", return_value=listing):
            found = poster.find_existing_announcement(
                "access",
                "agent",
                "Linthra",
                "https://github.com/TheZupZup/Linthra/releases/tag/v0.2.2",
            )
        self.assertEqual(
            found, "https://www.reddit.com/r/Linthra/comments/example/release/"
        )

    def test_missing_credentials_fail_before_any_network_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            (tmp_path / "title").write_text("Title", encoding="utf-8")
            (tmp_path / "body").write_text("Body", encoding="utf-8")
            with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
                poster.urllib.request, "urlopen"
            ) as urlopen:
                code = poster.main(
                    [
                        "--title-file",
                        str(tmp_path / "title"),
                        "--body-file",
                        str(tmp_path / "body"),
                        "--release-url",
                        "https://github.com/TheZupZup/Linthra/releases/tag/v0.2.2",
                        "--subreddit",
                        "Linthra",
                    ]
                )
            self.assertEqual(code, 1)
            urlopen.assert_not_called()

    def test_manual_workflow_is_preview_only(self):
        workflow = (
            ROOT / ".github" / "workflows" / "reddit-release-announcement.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("github.event_name == 'release'", workflow)
        self.assertNotIn("workflow_dispatch' &&", workflow)
        self.assertNotIn("gh release delete", workflow)
        self.assertNotIn("gh pr merge", workflow)


if __name__ == "__main__":
    unittest.main()
