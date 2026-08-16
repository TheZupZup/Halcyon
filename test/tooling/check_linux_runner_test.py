#!/usr/bin/env python3
"""Unit tests for scripts/check_linux_runner.py (#376, PR 1).

    python3 test/tooling/check_linux_runner_test.py

The checker's job is to notice when the committed Linux runner drifts from the
app's identity — most plausibly because someone re-ran
`flutter create --platforms=linux .` and the template overwrote it. So the tests
are mostly "take a good checkout, break exactly one thing, expect it to be
caught", built on a synthetic checkout rather than the real one: a fixture that
can be broken is the only way to prove the checker fails when it should, and it
keeps these tests from depending on Linthra's current version or app id.

One test does run against the real repository, because "the checker passes on
the actual runner" is the thing the CI job cares about.

Everything is offline. No network, no git, no repository writes.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

sys.path.insert(0, str(SCRIPTS))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


checker = _load("check_linux_runner", "check_linux_runner.py")


APP_ID = "io.example.app"
BINARY = "exampleapp"
DISPLAY_NAME = "ExampleApp"

CMAKELISTS = """\
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

set(BINARY_NAME "{binary}")
set(APPLICATION_ID "{app_id}")

set(LINTHRA_SQLITE3_SOURCE_DIR "$ENV{{LINTHRA_SQLITE3_SOURCE_DIR}}" CACHE PATH "")
if(LINTHRA_SQLITE3_SOURCE_DIR)
  set(FETCHCONTENT_SOURCE_DIR_SQLITE3 "${{LINTHRA_SQLITE3_SOURCE_DIR}}"
    CACHE PATH "" FORCE)
endif()

include(flutter/generated_plugins.cmake)

if(TARGET flutter_secure_storage_linux_plugin AND
   CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  target_compile_options(flutter_secure_storage_linux_plugin PRIVATE
    -Wno-error=deprecated-literal-operator)
endif()
"""

MY_APPLICATION = """\
#include "my_application.h"

static constexpr const char* kApplicationName = "{display_name}";
static constexpr int kDefaultWindowWidth = 1180;
static constexpr int kDefaultWindowHeight = 780;
static constexpr int kMinimumWindowWidth = 420;
static constexpr int kMinimumWindowHeight = 600;
"""

BUILD_GRADLE = """\
android {{
    namespace = "{app_id}"
    defaultConfig {{
        applicationId = "{app_id}"
    }}
}}
"""

PUBSPEC = """\
name: {binary}
description: An example.
version: 1.2.3+10203
"""

APP_INFO = """\
abstract final class AppInfo {{
  static const String name = '{display_name}';
  static const String tagline = 'Example.';
}}
"""


def build_checkout(
    directory: Path,
    *,
    cmakelists: str | None = None,
    my_application: str | None = None,
    build_gradle: str | None = None,
    pubspec: str | None = None,
    app_info: str | None = None,
) -> Path:
    """Write a minimal, internally consistent checkout the checker can read."""
    (directory / "linux" / "runner").mkdir(parents=True, exist_ok=True)
    (directory / "android" / "app").mkdir(parents=True, exist_ok=True)
    (directory / "lib" / "core").mkdir(parents=True, exist_ok=True)

    (directory / "linux" / "CMakeLists.txt").write_text(
        cmakelists
        if cmakelists is not None
        else CMAKELISTS.format(binary=BINARY, app_id=APP_ID),
        encoding="utf-8",
    )
    (directory / "linux" / "runner" / "my_application.cc").write_text(
        my_application
        if my_application is not None
        else MY_APPLICATION.format(display_name=DISPLAY_NAME),
        encoding="utf-8",
    )
    (directory / "android" / "app" / "build.gradle").write_text(
        build_gradle
        if build_gradle is not None
        else BUILD_GRADLE.format(app_id=APP_ID),
        encoding="utf-8",
    )
    (directory / "pubspec.yaml").write_text(
        pubspec if pubspec is not None else PUBSPEC.format(binary=BINARY),
        encoding="utf-8",
    )
    (directory / "lib" / "core" / "app_info.dart").write_text(
        app_info
        if app_info is not None
        else APP_INFO.format(display_name=DISPLAY_NAME),
        encoding="utf-8",
    )
    return directory


class CheckoutCase(unittest.TestCase):
    """Base class giving each test a fresh throwaway checkout."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)


class ConsistentCheckoutTest(CheckoutCase):
    def test_a_consistent_checkout_has_no_problems(self) -> None:
        build_checkout(self.root)
        self.assertEqual(checker.check(self.root), [])

    def test_main_exits_zero(self) -> None:
        build_checkout(self.root)
        self.assertEqual(checker.main(["--root", str(self.root)]), 0)


class IdentityDriftTest(CheckoutCase):
    def test_application_id_must_match_android(self) -> None:
        build_checkout(
            self.root,
            cmakelists=CMAKELISTS.format(binary=BINARY, app_id="com.example.other"),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("APPLICATION_ID", problems[0])
        self.assertIn("com.example.other", problems[0])

    def test_binary_name_must_match_the_package_name(self) -> None:
        build_checkout(
            self.root,
            cmakelists=CMAKELISTS.format(binary="renamed", app_id=APP_ID),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("BINARY_NAME", problems[0])

    def test_window_title_must_match_app_info(self) -> None:
        # The regression a template regeneration actually causes: the title
        # goes back to the lowercase package name.
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=BINARY),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("kApplicationName", problems[0])

    def test_a_wholly_regenerated_runner_is_caught(self) -> None:
        # The full template restoration: lowercase title, no size constants.
        build_checkout(
            self.root,
            my_application='  gtk_window_set_title(window, "exampleapp");\n',
        )
        with self.assertRaises(checker.CheckError):
            checker.check(self.root)

    def test_several_problems_are_all_reported(self) -> None:
        build_checkout(
            self.root,
            cmakelists=CMAKELISTS.format(binary="renamed", app_id="com.example.other"),
            my_application=MY_APPLICATION.format(display_name="Other"),
        )
        self.assertEqual(len(checker.check(self.root)), 3)


class WindowMetricsTest(CheckoutCase):
    def test_minimum_may_not_exceed_the_default(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "kMinimumWindowWidth = 420", "kMinimumWindowWidth = 2000"
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("minimum window size", problems[0])

    def test_a_zero_minimum_is_rejected(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "kMinimumWindowHeight = 600", "kMinimumWindowHeight = 0"
            ),
        )
        self.assertIn("must be positive", " ".join(checker.check(self.root)))

    def test_equal_minimum_and_default_is_allowed(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME)
            .replace("kMinimumWindowWidth = 420", "kMinimumWindowWidth = 1180")
            .replace("kMinimumWindowHeight = 600", "kMinimumWindowHeight = 780"),
        )
        self.assertEqual(checker.check(self.root), [])


class OfflineBuildSeamTest(CheckoutCase):
    def test_losing_the_sqlite_seam_is_caught(self) -> None:
        # This is the check that matters for packaging: without the seam the
        # build still succeeds anywhere with a network, so nothing else notices.
        build_checkout(
            self.root,
            cmakelists='set(BINARY_NAME "exampleapp")\nset(APPLICATION_ID "io.example.app")\n',
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 2)
        self.assertIn("LINTHRA_SQLITE3_SOURCE_DIR", problems[0])

    def test_a_seam_that_is_never_forwarded_is_caught(self) -> None:
        # Declaring the variable and not wiring it to FetchContent would look
        # right in a diff and do nothing.
        build_checkout(
            self.root,
            cmakelists=(
                'set(BINARY_NAME "exampleapp")\n'
                'set(APPLICATION_ID "io.example.app")\n'
                'set(LINTHRA_SQLITE3_SOURCE_DIR "" CACHE PATH "")\n'
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 2)
        self.assertIn("never forwards it", problems[0])


class SecureStorageWarningScopeTest(CheckoutCase):
    def test_losing_the_plugin_exception_is_caught(self) -> None:
        cmakelists = CMAKELISTS.format(binary=BINARY, app_id=APP_ID).replace(
            """\
if(TARGET flutter_secure_storage_linux_plugin AND
   CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  target_compile_options(flutter_secure_storage_linux_plugin PRIVATE
    -Wno-error=deprecated-literal-operator)
endif()
""",
            "",
        )
        build_checkout(self.root, cmakelists=cmakelists)

        problems = checker.check(self.root)

        self.assertEqual(len(problems), 1)
        self.assertIn("deprecated-literal-operator", problems[0])

    def test_a_global_exception_is_rejected(self) -> None:
        cmakelists = CMAKELISTS.format(binary=BINARY, app_id=APP_ID).replace(
            """\
  target_compile_options(flutter_secure_storage_linux_plugin PRIVATE
    -Wno-error=deprecated-literal-operator)
""",
            "  add_compile_options(-Wno-error=deprecated-literal-operator)\n",
        )
        build_checkout(self.root, cmakelists=cmakelists)

        problems = checker.check(self.root)

        self.assertEqual(len(problems), 1)
        self.assertIn("PRIVATE", problems[0])


class AbsolutePathTest(CheckoutCase):
    def test_a_hardcoded_host_path_is_caught(self) -> None:
        build_checkout(self.root)
        (self.root / "linux" / "CMakeLists.txt").write_text(
            CMAKELISTS.format(binary=BINARY, app_id=APP_ID)
            + 'include_directories("/home/dev/sqlite")\n',
            encoding="utf-8",
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("absolute host path", problems[0])
        self.assertIn("/home/dev/sqlite", problems[0])

    def test_ordinary_cmake_variable_paths_are_not_flagged(self) -> None:
        build_checkout(self.root)
        (self.root / "linux" / "CMakeLists.txt").write_text(
            CMAKELISTS.format(binary=BINARY, app_id=APP_ID)
            + 'set(BUNDLE "${CMAKE_INSTALL_PREFIX}/data/flutter_assets")\n'
            + 'set(RPATH "$ORIGIN/lib")\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.check(self.root), [])

    def test_generated_ephemeral_files_are_ignored(self) -> None:
        # linux/flutter/ephemeral is per-build output full of machine paths and
        # is not in git; scanning it would fail on every developer's checkout.
        build_checkout(self.root)
        ephemeral = self.root / "linux" / "flutter" / "ephemeral"
        ephemeral.mkdir(parents=True)
        (ephemeral / "generated_config.cmake").write_text(
            'set(FLUTTER_ROOT "/home/dev/flutter")\n', encoding="utf-8"
        )
        self.assertEqual(checker.check(self.root), [])


class MissingFileTest(CheckoutCase):
    def test_a_missing_runner_is_an_error_not_a_pass(self) -> None:
        with self.assertRaises(checker.CheckError):
            checker.check(self.root)

    def test_main_reports_a_read_failure_as_exit_two(self) -> None:
        self.assertEqual(checker.main(["--root", str(self.root)]), 2)


class RealRepositoryTest(unittest.TestCase):
    def test_the_committed_linux_runner_is_consistent(self) -> None:
        self.assertEqual(checker.check(ROOT), [])

    def test_the_runner_uses_the_android_application_id(self) -> None:
        # Stated explicitly because it is the decision that matters for
        # Flathub: one reverse-DNS id for the product on every platform.
        self.assertEqual(
            checker.application_id(ROOT), checker.android_application_id(ROOT)
        )

    def test_the_window_title_is_the_product_name(self) -> None:
        self.assertEqual(checker.window_title(ROOT), checker.app_display_name(ROOT))


if __name__ == "__main__":
    unittest.main(verbosity=2)
