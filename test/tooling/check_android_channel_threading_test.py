#!/usr/bin/env python3
"""Mutation tests for the SAF threading tripwire (#346).

The synthetic fixtures deliberately move the walk outside the submitted work,
including the regression that #570's previous checker failed to detect.
Everything runs offline without an Android SDK or Gradle.
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
    fun listAudioDocuments(treeUri: String, result: MethodChannel.Result) {
"""
    + SUBMITTING_SCAN
    + """
    }
    private fun walk(treeUri: Uri): Map<String, Any?> = emptyMap()
}
"""
)


GOOD_ACTIVITY = """package io.github.thezupzup.linthra

class MainActivity : AudioServiceActivity() {
    // One scanner for the channel: it holds the cancellation flag of the walk
    // in flight, and a fresh one per request would have nothing to cancel.
    private val safDocumentScanner by lazy {
        SafDocumentScanner(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        when (call.method) {
            "listAudioDocuments" -> safDocumentScanner.listAudioDocuments(treeUri, result)
            "hasPersistedPermission" ->
                result.success(safDocumentScanner.hasPersistedPermission(treeUri))
            "readSidecarText" ->
                result.success(safDocumentScanner.readSidecarText(uri, extension))
        }
    }
}
"""


class CheckerTest(unittest.TestCase):
    def check(
        self,
        *,
        worker: str = GOOD_WORKER,
        scanner: str = GOOD_SCANNER,
        activity: str = GOOD_ACTIVITY,
    ):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / checker.WORKER_FILE).write_text(worker, encoding="utf-8")
            (directory / checker.SCANNER_FILE).write_text(scanner, encoding="utf-8")
            (directory / checker.ACTIVITY_FILE).write_text(activity, encoding="utf-8")
            return checker.check(directory)

    def assertCaught(self, failures: list[str], needle: str) -> None:
        self.assertTrue(failures, "expected the checker to fail, it passed")
        self.assertIn(needle, "\n".join(failures))

    def test_a_good_pair_passes(self):
        self.assertEqual(self.check(), [])

    def test_the_real_kotlin_passes(self):
        self.assertEqual(checker.check(checker.KOTLIN), [])

    def test_a_missing_worker_file_is_caught(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / checker.SCANNER_FILE).write_text(
                GOOD_SCANNER, encoding="utf-8"
            )
            (directory / checker.ACTIVITY_FILE).write_text(
                GOOD_ACTIVITY, encoding="utf-8"
            )
            self.assertCaught(checker.check(directory), "missing")

    def test_the_pre_fix_shape_is_caught(self):
        inline = "        result.success(walk(Uri.parse(treeUri)))"
        self.assertCaught(
            self.check(scanner=GOOD_SCANNER.replace(SUBMITTING_SCAN, inline)),
            "does not submit",
        )

    def test_a_reformatted_inline_reply_is_caught(self):
        inline = "        result . success (\n walk(Uri.parse(treeUri))\n )"
        self.assertCaught(
            self.check(scanner=GOOD_SCANNER.replace(SUBMITTING_SCAN, inline)),
            "does not submit",
        )

    def test_dropping_the_worker_from_the_scan_is_caught(self):
        self.assertCaught(
            self.check(scanner=GOOD_SCANNER.replace("worker.submit(", "runNow(")),
            "does not submit",
        )

    def test_a_commented_out_submit_is_not_a_submission(self):
        scanner = GOOD_SCANNER.replace("worker.submit(", "// worker.submit(\n runNow(")
        self.assertCaught(self.check(scanner=scanner), "does not submit")

    def test_a_worker_that_never_leaves_the_caller_thread_is_caught(self):
        self.assertCaught(
            self.check(worker=GOOD_WORKER.replace("background.execute {", "run {")),
            "background executor",
        )

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
        self.assertCaught(
            self.check(
                scanner=GOOD_SCANNER.replace("fun listAudioDocuments", "fun listAudio")
            ),
            "no listAudioDocuments()",
        )

    def test_eager_walk_then_submitted_value_is_caught(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN,
            "        val documents = walk(Uri.parse(treeUri))\n"
            + SUBMITTING_SCAN.replace("walk(Uri.parse(treeUri))", "documents"),
        )
        self.assertCaught(self.check(scanner=scanner), "inside the submitted work")

    def test_eager_walk_with_another_valid_work_lambda_is_caught(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN,
            "        val eager = walk(Uri.parse(treeUri))\n" + SUBMITTING_SCAN,
        )
        self.assertCaught(self.check(scanner=scanner), "inside the submitted work")

    def test_walk_after_submission_is_caught(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN, SUBMITTING_SCAN + "\n        walk(Uri.parse(treeUri))"
        )
        self.assertCaught(self.check(scanner=scanner), "inside the submitted work")

    def test_work_in_a_comment_cannot_hide_an_eager_walk(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN,
            "        val documents = walk(Uri.parse(treeUri))\n"
            "        // work = { walk(Uri.parse(treeUri)) }\n"
            + SUBMITTING_SCAN.replace("walk(Uri.parse(treeUri))", "documents"),
        )
        self.assertCaught(self.check(scanner=scanner), "inside the submitted work")

    def test_a_second_inline_success_is_caught(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN, SUBMITTING_SCAN + "\n        result.success(emptyMap())"
        )
        self.assertCaught(self.check(scanner=scanner), "must not answer inline")

    def test_a_second_submission_is_caught(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN, SUBMITTING_SCAN + "\n" + SUBMITTING_SCAN
        )
        self.assertCaught(self.check(scanner=scanner), "exactly one")

    def test_a_synchronous_production_executor_is_caught(self):
        worker = GOOD_WORKER.replace(
            "newSingleThreadExecutor", "newSingleThreadExecutorRemoved"
        )
        self.assertCaught(self.check(worker=worker), "background thread factory")

    def test_comments_and_strings_cannot_fake_calls(self):
        worker = GOOD_WORKER.replace(
            "                    work()", '                    "work()"'
        )
        self.assertCaught(self.check(worker=worker), "work() is evaluated outside")

    def test_nested_comments_and_raw_strings_do_not_break_nesting(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN,
            "        /* outer { /* inner ) } */ still } */\n"
            '        val prose = """{ ) worker.submit(work = { walk() })"""\n'
            + SUBMITTING_SCAN,
        )
        self.assertEqual(self.check(scanner=scanner), [])

    def test_a_scanner_built_per_request_is_caught(self):
        # The shape that silently disabled cancellation: each request gets a
        # fresh instance, so there is never an in-flight walk to supersede.
        activity = GOOD_ACTIVITY.replace(
            "safDocumentScanner.listAudioDocuments(treeUri, result)",
            "SafDocumentScanner(applicationContext)"
            ".listAudioDocuments(treeUri, result)",
        )
        self.assertCaught(self.check(activity=activity), "exactly one")

    def test_a_scanner_built_at_a_call_site_is_caught(self):
        # Exactly one construction, but not a stored one: cancellation state
        # still dies with the call.
        activity = GOOD_ACTIVITY.replace(
            """    private val safDocumentScanner by lazy {
        SafDocumentScanner(applicationContext)
    }

""",
            "",
        ).replace(
            "safDocumentScanner.listAudioDocuments(treeUri, result)",
            "SafDocumentScanner(applicationContext)"
            ".listAudioDocuments(treeUri, result)",
        )
        self.assertCaught(self.check(activity=activity), "held for the")

    def test_a_missing_activity_is_caught(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / checker.WORKER_FILE).write_text(GOOD_WORKER, encoding="utf-8")
            (directory / checker.SCANNER_FILE).write_text(
                GOOD_SCANNER, encoding="utf-8"
            )
            self.assertCaught(checker.check(directory), "missing")


if __name__ == "__main__":
    unittest.main(verbosity=2)
