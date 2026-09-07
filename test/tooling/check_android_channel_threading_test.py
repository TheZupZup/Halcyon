#!/usr/bin/env python3
"""Unit tests for scripts/check_android_channel_threading.py (#346).

    python3 test/tooling/check_android_channel_threading_test.py

The checker exists to notice one silent regression: the SAF library walk drifting
back onto Android's platform thread, where it becomes an ANR on a real library.
That regression compiles, passes every test in the repo, and reads like a
simplification in review, so the tests here are "take a good checkout, break
exactly one thing, expect it to be caught".

They run against a synthetic Kotlin fixture rather than the real files, because a
fixture is the only way to prove the checker *fails* when it should. One test
does run against the real repository, since "the checker passes on the actual
Kotlin" is what the CI step cares about.

Everything is offline. No network, no Gradle, no Android SDK, no repository
writes.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


checker = _load("check_android_channel_threading", "check_android_channel_threading.py")


GOOD_WORKER = """package io.github.thezupzup.linthra

import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Runs blocking channel work off the platform thread. */
class PlatformChannelWorker(
    private val background: Executor = SHARED_BACKGROUND,
) {
    fun <T> submit(
        work: () -> T,
        onSuccess: (T) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        background.execute {
            val value =
                try {
                    work()
                } catch (e: Exception) {
                    onFailure(e)
                    return@execute
                }
            onSuccess(value)
        }
    }

    companion object {
        private val SHARED_BACKGROUND: Executor =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "linthra-channel-work").apply { isDaemon = true }
            }
    }
}
"""

SUBMITTING_SCAN = """        worker.submit(
            work = { walk(Uri.parse(treeUri)) },
            onSuccess = { documents -> result.success(documents) },
            onFailure = { error ->
                if (error is SecurityException) {
                    result.error("saf_permission", "No access.", null)
                } else {
                    result.error("saf_failed", "Failed to read.", null)
                }
            },
        )"""

GOOD_SCANNER = (
    """package io.github.thezupzup.linthra

import android.content.Context
import android.net.Uri
import io.flutter.plugin.common.MethodChannel

class SafDocumentScanner(
    private val context: Context,
    private val worker: PlatformChannelWorker = PlatformChannelWorker(),
) {
    /** Walks the tree off the platform thread. */
    fun listAudioDocuments(treeUri: String, result: MethodChannel.Result) {
"""
    + SUBMITTING_SCAN
    + """
    }

    fun hasPersistedPermission(treeUri: String): Boolean = true

    private fun walk(treeUri: Uri): Map<String, Any?> = emptyMap()
}
"""
)


class CheckerTest(unittest.TestCase):
    def check(self, *, worker: str = GOOD_WORKER, scanner: str = GOOD_SCANNER):
        """Runs the checker over a throwaway Kotlin directory."""
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / checker.WORKER_FILE).write_text(worker, encoding="utf-8")
            (directory / checker.SCANNER_FILE).write_text(scanner, encoding="utf-8")
            return checker.check(directory)

    def assertCaught(self, failures: list[str], needle: str) -> None:
        self.assertTrue(failures, "expected the checker to fail, it passed")
        self.assertIn(needle, "\n".join(failures))

    def test_a_good_pair_passes(self):
        self.assertEqual(self.check(), [])

    def test_the_real_kotlin_passes(self):
        # The claim the CI step is actually making.
        self.assertEqual(checker.check(checker.KOTLIN), [])

    def test_a_missing_worker_file_is_caught(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / checker.SCANNER_FILE).write_text(
                GOOD_SCANNER, encoding="utf-8"
            )
            self.assertCaught(checker.check(directory), "missing")

    def test_the_pre_fix_shape_is_caught(self):
        # Exactly how the scan looked before #346: the whole walk evaluated as
        # the argument to the reply, on the caller's thread.
        inline = """        try {
            result.success(walk(Uri.parse(treeUri)))
        } catch (e: Exception) {
            result.error("saf_failed", "Failed to read.", null)
        }"""
        scanner = GOOD_SCANNER.replace(SUBMITTING_SCAN, inline)
        self.assertCaught(self.check(scanner=scanner), "inline")

    def test_a_reformatted_inline_reply_is_still_caught(self):
        inline = """        result . success (
            walk( Uri.parse(treeUri) )
        )"""
        scanner = GOOD_SCANNER.replace(SUBMITTING_SCAN, inline)
        self.assertCaught(self.check(scanner=scanner), "inline")

    def test_dropping_the_worker_from_the_scan_is_caught(self):
        scanner = GOOD_SCANNER.replace("worker.submit(", "runNow(")
        self.assertCaught(self.check(scanner=scanner), "does not submit")

    def test_a_commented_out_submit_does_not_satisfy_the_checker(self):
        # A file whose comments still describe the fix, whose code no longer
        # has it. Checking raw text would pass this.
        scanner = GOOD_SCANNER.replace(
            "worker.submit(", "// worker.submit(\n        runNow("
        )
        self.assertCaught(self.check(scanner=scanner), "does not submit")

    def test_a_worker_that_never_leaves_the_caller_thread_is_caught(self):
        worker = GOOD_WORKER.replace("background.execute {", "run {")
        self.assertCaught(self.check(worker=worker), "background executor")

    def test_work_evaluated_before_the_executor_is_caught(self):
        worker = GOOD_WORKER.replace(
            "        background.execute {\n            val value =",
            "        val eager = work()\n        background.execute {\n            val value =",
        ).replace("                    work()", "                    eager")
        self.assertCaught(self.check(worker=worker), "work() is evaluated outside")

    def test_callbacks_outside_the_executor_are_caught(self):
        worker = GOOD_WORKER.replace(
            "                    onFailure(e)", "                    throw e"
        ).replace(
            "            onSuccess(value)",
            "            value\n        }\n        onSuccess(work())",
        )
        self.assertCaught(self.check(worker=worker), "callbacks must stay inside")

    def test_a_renamed_scan_method_is_caught(self):
        scanner = GOOD_SCANNER.replace("fun listAudioDocuments", "fun listAudio")
        self.assertCaught(self.check(scanner=scanner), "no listAudioDocuments()")


if __name__ == "__main__":
    unittest.main(verbosity=2)
