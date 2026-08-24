#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("tui_memory_soak.py")
SPEC = importlib.util.spec_from_file_location("tui_memory_soak", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SOAK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOAK)


class TuiMemorySoakTest(unittest.TestCase):
    def test_slope_uses_only_requested_phase(self) -> None:
        rows = [
            {"elapsed_seconds": 0.0, "phase": "warmup", "rss_kib": 9999},
            {"elapsed_seconds": 60.0, "phase": "active", "rss_kib": 1000},
            {"elapsed_seconds": 120.0, "phase": "active", "rss_kib": 1010},
            {"elapsed_seconds": 180.0, "phase": "active", "rss_kib": 1020},
            {"elapsed_seconds": 240.0, "phase": "idle_after", "rss_kib": 1},
        ]
        self.assertAlmostEqual(SOAK.slope_per_minute(rows, "rss_kib", "active"), 10.0)

    def test_proc_parser_does_not_invent_missing_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status"
            path.write_text("VmRSS:\t1234 kB\nThreads:\t7\nName:\tagent_app\n")
            self.assertEqual(SOAK.parse_kib_map(path), {"VmRSS": 1234, "Threads": 7})

    def test_descendant_target_pid_falls_back_for_unknown_root(self) -> None:
        self.assertEqual(SOAK.descendant_target_pid(99_999_999), 99_999_999)

    def test_fixed_card_growth_is_a_hard_failure_but_rss_is_only_warning(self) -> None:
        samples = [
            {
                "phase": "active",
                "elapsed_seconds": float(index),
                "rss_kib": 1000 + index,
                "anonymous_rss_kib": 500 + index,
                "card_count": 10 + index,
                "fd_count": 5,
                "thread_count": 7,
                "event_queue_length": 0,
                "pending_job_count": 0,
            }
            for index in range(3)
        ]
        status = {
            "operation_count": 3,
            "terminal_byte_count": 42,
            "planned_stop": True,
            "stop_signal": "SIGTERM",
            "returncode": -15,
        }
        summary = SOAK.summarize_run(samples, status, "fixed-card-stream")
        self.assertIn(
            "card_count_changed_after_stream_card_created",
            summary["hard_correctness_failures"],
        )
        self.assertEqual(summary["trend_warning"], "positive RSS slope; inspect repeated runs and retained stacks")
        self.assertEqual(summary["managed_heap_metrics"], "unavailable")

    def test_fixed_payload_replace_uses_same_card_bound(self) -> None:
        samples = [
            {
                "phase": "active",
                "elapsed_seconds": float(index),
                "rss_kib": 1000,
                "anonymous_rss_kib": 500,
                "card_count": count,
                "fd_count": 5,
                "thread_count": 7,
                "event_queue_length": 0,
                "pending_job_count": 0,
            }
            for index, count in enumerate((10, 11, 11, 11))
        ]
        summary = SOAK.summarize_run(
            samples,
            {
                "operation_count": 4,
                "terminal_byte_count": 42,
                "planned_stop": True,
                "stop_signal": "SIGTERM",
                "returncode": -15,
            },
            "fixed-card-replace",
        )
        self.assertEqual(summary["hard_correctness_failures"], [])

    def test_unplanned_or_forced_process_exit_is_a_hard_failure(self) -> None:
        sample = {
            "phase": "active",
            "elapsed_seconds": 1.0,
            "rss_kib": 1000,
            "anonymous_rss_kib": 500,
            "card_count": 1,
            "fd_count": 5,
            "thread_count": 7,
            "event_queue_length": 0,
            "pending_job_count": 0,
        }
        unplanned = SOAK.summarize_run(
            [sample],
            {"operation_count": 1, "terminal_byte_count": 1, "returncode": -11},
            "idle",
        )
        self.assertIn("process_exited_before_planned_stop", unplanned["hard_correctness_failures"])
        forced = SOAK.summarize_run(
            [sample],
            {
                "operation_count": 1,
                "terminal_byte_count": 1,
                "planned_stop": True,
                "stop_signal": "SIGKILL",
                "returncode": -9,
            },
            "idle",
        )
        self.assertIn("process_required_forced_kill", forced["hard_correctness_failures"])

    def test_planned_sigterm_teardown_anomaly_is_reported_not_hidden(self) -> None:
        sample = {
            "phase": "active",
            "elapsed_seconds": 1.0,
            "rss_kib": 1000,
            "anonymous_rss_kib": 500,
            "card_count": 1,
            "fd_count": 5,
            "thread_count": 7,
            "event_queue_length": 0,
            "pending_job_count": 0,
        }
        summary = SOAK.summarize_run(
            [sample],
            {
                "operation_count": 1,
                "terminal_byte_count": 1,
                "planned_stop": True,
                "stop_signal": "SIGTERM",
                "returncode": -11,
            },
            "search",
        )
        self.assertEqual(summary["hard_correctness_failures"], [])
        self.assertEqual(summary["process_completion"], "planned_signal_teardown")
        self.assertIn("SIGSEGV", summary["termination_anomaly"])

    def test_aggregate_runs_preserves_distribution_and_failures(self) -> None:
        aggregate = SOAK.aggregate_runs(
            [
                {
                    "peak_rss_kib": 100,
                    "steady_state_rss_median_kib": 80,
                    "hard_correctness_failures": [],
                    "process_completion": "clean_exit",
                },
                {
                    "peak_rss_kib": 120,
                    "steady_state_rss_median_kib": 90,
                    "hard_correctness_failures": ["queue"],
                    "process_completion": "planned_signal_teardown",
                },
            ]
        )
        self.assertEqual(aggregate["run_count"], 2)
        self.assertEqual(aggregate["clean_exit_count"], 1)
        self.assertEqual(aggregate["metrics"]["peak_rss_kib"]["median"], 110)
        self.assertEqual(aggregate["hard_correctness_failures"], ["queue"])

    def test_expand_collapse_requires_both_observable_states(self) -> None:
        def sample(expanded: int) -> dict[str, object]:
            return {
                "phase": "active",
                "elapsed_seconds": float(expanded),
                "rss_kib": 1000,
                "anonymous_rss_kib": 500,
                "card_count": 5,
                "expanded_card_count": expanded,
                "large_fixture_expanded_count": expanded,
                "fd_count": 5,
                "thread_count": 7,
                "event_queue_length": 0,
                "pending_job_count": 0,
            }

        status = {
            "operation_count": 2,
            "terminal_byte_count": 1,
            "planned_stop": True,
            "stop_signal": None,
            "returncode": 0,
        }
        exercised = SOAK.summarize_run([sample(0), sample(1)], status, "expand-collapse")
        self.assertEqual(exercised["hard_correctness_failures"], [])
        missed = SOAK.summarize_run([sample(0), sample(0)], status, "expand-collapse")
        self.assertIn("large_card_was_never_expanded", missed["hard_correctness_failures"])

    def test_idle_tail_rejects_buffered_input_work(self) -> None:
        samples = []
        for index, operations in enumerate((10, 11, 20, 30)):
            samples.append(
                {
                    "phase": "idle_after",
                    "elapsed_seconds": float(index),
                    "rss_kib": 1000,
                    "anonymous_rss_kib": 500,
                    "operation_count": operations,
                    "card_count": 5,
                    "event_queue_length": 0,
                    "pending_job_count": 0,
                }
            )
        status = {
            "operation_count": 30,
            "terminal_byte_count": 1,
            "planned_stop": True,
            "stop_signal": None,
            "returncode": 0,
        }
        summary = SOAK.summarize_run(samples, status, "fixed-card-replace")
        self.assertIn(
            "input_or_render_work_continued_through_idle_tail",
            summary["hard_correctness_failures"],
        )

    def test_fd_peak_must_return_to_baseline(self) -> None:
        def sample(index: int, count: int) -> dict[str, object]:
            return {
                "phase": "active",
                "elapsed_seconds": float(index),
                "rss_kib": 1000,
                "anonymous_rss_kib": 500,
                "card_count": 5,
                "fd_count": count,
                "thread_count": 7,
                "event_queue_length": 0,
                "pending_job_count": 0,
            }

        status = {
            "operation_count": 3,
            "terminal_byte_count": 1,
            "planned_stop": True,
            "stop_signal": None,
            "returncode": 0,
        }
        transient = SOAK.summarize_run(
            [sample(0, 5), sample(1, 11), sample(2, 5)],
            status,
            "session-churn",
        )
        self.assertNotIn("fd_count_grew", transient["hard_correctness_failures"])
        retained = SOAK.summarize_run(
            [sample(0, 5), sample(1, 11), sample(2, 11)],
            status,
            "session-churn",
        )
        self.assertIn("fd_count_grew", retained["hard_correctness_failures"])

    def test_pty_send_retries_nonblocking_backpressure(self) -> None:
        process = SOAK.SoakProcess.__new__(SOAK.SoakProcess)
        process.master_fd = 7
        process.args = type("Args", (), {"input_write_timeout": 1.0})()
        process.pump = mock.Mock()
        process.assert_running = mock.Mock()
        with mock.patch.object(SOAK.os, "write", side_effect=[BlockingIOError(), 3]):
            process.send(b"abc")
        process.pump.assert_called_once_with(0.01)
        process.assert_running.assert_called_once_with()

    def test_resize_tracks_two_buffer_capacity_bound(self) -> None:
        process = SOAK.SoakProcess.__new__(SOAK.SoakProcess)
        process.master_fd = 7
        process.process = None
        process.args = type("Args", (), {"terminal_height": 28})()
        process.terminal_width = 100
        with mock.patch.object(SOAK, "set_winsize") as set_size:
            process.resize(160)
        set_size.assert_called_once_with(7, 160, 28)
        self.assertEqual(process.terminal_width, 160)


if __name__ == "__main__":
    unittest.main()
