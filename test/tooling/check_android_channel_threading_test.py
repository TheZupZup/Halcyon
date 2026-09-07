#!/usr/bin/env python3
"""Mutation tests for the SAF threading tripwire (#346).

The synthetic fixtures deliberately break one thing each: the walk moved
outside the submitted work (including the regression that #570's previous
checker failed to detect), and the two quiet ways scan cancellation stops
working. Everything runs offline without an Android SDK or Gradle.
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
            work = { walk(Uri.parse(treeUri), cancelled) },
            onSuccess = { documents -> result.success(documents) },
            onFailure = { error ->
                if (error is SecurityException) {
                    result.error("saf_permission", "No access.", null)
                } else {
                    result.error("saf_failed", "Failed to read.", null)
                }
            },
        )"""

GOOD_WALK = """    private fun walk(treeUri: Uri, cancelled: AtomicBoolean): Map<String, Any?> {
        while (queue.isNotEmpty()) {
            if (cancelled.get()) throw ScanSuperseded()
            try {
                cursor.use { c ->
                    while (c.moveToNext()) {
                        if (cancelled.get()) throw ScanSuperseded()
                    }
                }
            } catch (e: ScanSuperseded) {
                throw e
            } catch (e: SecurityException) {
                throw e
            } catch (e: Exception) {
                readFailures++
            }
        }
        return emptyMap()
    }
"""

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
"""
    + GOOD_WALK
    + """    private class ScanSuperseded : Exception()
    companion object {
        private val currentScan = AtomicReference<AtomicBoolean?>(null)
    }
}
"""
)


class CheckerTest(unittest.TestCase):
    def check(
        self,
        *,
        worker: str = GOOD_WORKER,
        scanner: str = GOOD_SCANNER,
    ):
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
        self.assertEqual(checker.check(checker.KOTLIN), [])

    def test_a_missing_worker_file_is_caught(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / checker.SCANNER_FILE).write_text(
                GOOD_SCANNER, encoding="utf-8"
            )
            self.assertCaught(checker.check(directory), "missing")

    def test_the_pre_fix_shape_is_caught(self):
        inline = "        result.success(walk(Uri.parse(treeUri), cancelled))"
        self.assertCaught(
            self.check(scanner=GOOD_SCANNER.replace(SUBMITTING_SCAN, inline)),
            "does not submit",
        )

    def test_a_reformatted_inline_reply_is_caught(self):
        inline = "        result . success (\n walk(Uri.parse(treeUri), cancelled)\n )"
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
            "        val documents = walk(Uri.parse(treeUri), cancelled)\n"
            + SUBMITTING_SCAN.replace(
                "walk(Uri.parse(treeUri), cancelled)", "documents"
            ),
        )
        self.assertCaught(self.check(scanner=scanner), "inside the submitted work")

    def test_eager_walk_with_another_valid_work_lambda_is_caught(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN,
            "        val eager = walk(Uri.parse(treeUri), cancelled)\n"
            + SUBMITTING_SCAN,
        )
        self.assertCaught(self.check(scanner=scanner), "inside the submitted work")

    def test_walk_after_submission_is_caught(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN,
            SUBMITTING_SCAN + "\n        walk(Uri.parse(treeUri), cancelled)",
        )
        self.assertCaught(self.check(scanner=scanner), "inside the submitted work")

    def test_work_in_a_comment_cannot_hide_an_eager_walk(self):
        scanner = GOOD_SCANNER.replace(
            SUBMITTING_SCAN,
            "        val documents = walk(Uri.parse(treeUri), cancelled)\n"
            "        // work = { walk(Uri.parse(treeUri), cancelled) }\n"
            + SUBMITTING_SCAN.replace(
                "walk(Uri.parse(treeUri), cancelled)", "documents"
            ),
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

    def test_an_instance_scoped_cancellation_flag_is_caught(self):
        # Compiles and works until the activity is recreated mid-scan, at which
        # point the new scanner's flag is empty and nothing cancels.
        scanner = GOOD_SCANNER.replace(
            """    companion object {
        private val currentScan = AtomicReference<AtomicBoolean?>(null)
    }
""",
            "",
        ).replace(
            "class SafDocumentScanner(",
            "private val currentScan = AtomicReference<AtomicBoolean?>(null)\n"
            "class SafDocumentScanner(",
        )
        self.assertCaught(self.check(scanner=scanner), "companion object")

    def test_a_missing_cancellation_flag_is_caught(self):
        scanner = GOOD_SCANNER.replace("val currentScan", "val unusedScan")
        self.assertCaught(self.check(scanner=scanner), "no currentScan")

    def test_dropping_the_superseded_rethrow_is_caught(self):
        # The quiet one: cancellation becomes "one unreadable subtree" and the
        # walk answers a partial success instead of saf_superseded.
        scanner = GOOD_SCANNER.replace(
            "            } catch (e: ScanSuperseded) {\n                throw e\n", ""
        )
        self.assertCaught(self.check(scanner=scanner), "before its catch-all")

    def test_a_superseded_catch_after_the_catch_all_is_caught(self):
        # Present but unreachable: Kotlin matches the catch-all first.
        scanner = GOOD_SCANNER.replace(
            "            } catch (e: ScanSuperseded) {\n                throw e\n", ""
        ).replace(
            "            } catch (e: Exception) {\n                readFailures++\n",
            "            } catch (e: Exception) {\n                readFailures++\n"
            "            } catch (e: ScanSuperseded) {\n                throw e\n",
        )
        self.assertCaught(self.check(scanner=scanner), "before its catch-all")

    def test_a_walk_that_never_checks_cancellation_is_caught(self):
        scanner = GOOD_SCANNER.replace("throw ScanSuperseded()", "continue")
        self.assertCaught(self.check(scanner=scanner), "never acts on cancellation")

    def test_a_commented_out_rethrow_does_not_count(self):
        scanner = GOOD_SCANNER.replace(
            "            } catch (e: ScanSuperseded) {\n                throw e\n",
            "            // } catch (e: ScanSuperseded) { throw e\n",
        )
        self.assertCaught(self.check(scanner=scanner), "before its catch-all")


if __name__ == "__main__":
    unittest.main(verbosity=2)
