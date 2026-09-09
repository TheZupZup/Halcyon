#!/usr/bin/env python3
"""Unit tests for the benchmark summary block (#338).

    python3 test/tooling/large_library_benchmark_test.py

`tools/large_library/benchmark_sqlite.py` prints a small summary after the
per-query lines, and that block is what a contributor (or a CI log reader)
actually looks at. These tests pin the two things that make it useful: the
numbers are the ones the labels claim, and the block stays aligned and
deterministic. `summary_lines` takes plain timings, so none of this needs a
200k-track fixture or a database.
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BENCHMARK = ROOT / "tools" / "large_library" / "benchmark_sqlite.py"


def _load():
    spec = importlib.util.spec_from_file_location("benchmark_sqlite", BENCHMARK)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


benchmark_sqlite = _load()

# (name, average ms, p95 ms, max ms): the shape main() collects per query.
RESULTS = (
    ("title prefix", 1.5, 2.0, 4.25),
    ("artist exact", 0.5, 0.9, 1.75),
    ("provider album", 2.0, 3.0, 9.5),
    ("recently added", 0.25, 0.4, 0.75),
)


class SummaryLinesTest(unittest.TestCase):
    def summary(self, results=RESULTS, track_count=200_000, iterations=200):
        return benchmark_sqlite.summary_lines(track_count, results, iterations)

    def labelled(self, label: str) -> str:
        matches = [line for line in self.summary() if line.strip().startswith(label)]
        self.assertEqual(len(matches), 1, f"expected exactly one {label!r} line")
        return matches[0]

    def test_counts_are_grouped_for_reading(self):
        self.assertIn("200,000", self.labelled("tracks:"))
        self.assertIn("4", self.labelled("queries:"))
        self.assertIn("200", self.labelled("iterations per query:"))

    def test_summed_averages_add_up_the_per_query_averages(self):
        # 1.5 + 0.5 + 2.0 + 0.25, not the wall-clock time of 200 iterations.
        self.assertIn("4.250 ms", self.labelled("sum of query averages:"))

    def test_average_per_query_is_the_mean_of_those_averages(self):
        self.assertIn("1.062 ms", self.labelled("average per query:"))

    def test_slowest_single_run_reports_the_max_sample_and_its_query(self):
        line = self.labelled("slowest single run:")
        self.assertIn("9.500 ms", line)
        self.assertIn("(provider album)", line)

    def test_no_label_claims_a_total_the_benchmark_never_measures(self):
        # The old "total query time" label read as wall-clock time while the
        # value was the sum of the per-query averages (#338).
        joined = "\n".join(self.summary())
        self.assertNotIn("total query time", joined)

    def test_values_line_up_in_one_column(self):
        rows = [line for line in self.summary() if line.startswith("  ")]
        self.assertEqual(len(rows), 6)
        # Counts have no unit and end the line; timings are followed by " ms".
        # Both end their value in the same column, which is what makes the
        # block scannable in a CI log.
        ends = {len(line) if " ms" not in line else line.index(" ms") for line in rows}
        self.assertEqual(len(ends), 1, f"values end at {ends}")

    def test_no_tabs_anywhere(self):
        # A stray tab used to make the iterations line jump around (#338).
        self.assertNotIn("\t", "\n".join(self.summary()))

    def test_output_is_deterministic(self):
        self.assertEqual(self.summary(), self.summary())

    def test_single_query_run_still_renders(self):
        lines = self.summary(results=(("title prefix", 1.0, 1.2, 1.5),))
        joined = "\n".join(lines)
        self.assertIn("sum of query averages:", joined)
        self.assertIn("1.000 ms", joined)
        self.assertIn("1.500 ms (title prefix)", joined)


if __name__ == "__main__":
    unittest.main()
