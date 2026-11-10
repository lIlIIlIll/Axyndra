import unittest
from unittest.mock import patch
from scripts.tui_pty_bench import matched_frame_input, PtyRun


def actual_frame(seq=1, count=1, first=10, event="message"):
    return dict(seq=seq, event=event, input_received_ns=40,
                terminal_flush_completed_ns=50,
                frame_inputs=[dict(event="key_down", count=count, first_received_ns=first)])


class FrameInputEvidenceTests(unittest.TestCase):
    def test_actual_coalesced_input_survives_later_message_and_uses_earlier_time(self):
        row = actual_frame(count=120)
        selected = matched_frame_input(row, {"key_down"})
        self.assertEqual(selected["event"], "message")
        self.assertEqual(selected["input_received_ns"], 10)
        self.assertEqual(selected["last_input_received_ns"], 40)
        self.assertEqual(selected["matched_input_count"], 120)
        self.assertEqual(row["input_received_ns"], 40)

    def test_old_trace_keeps_original_filter_and_input_timestamp(self):
        row = dict(event="key_down", input_received_ns=20)
        self.assertIs(matched_frame_input(row, {"key_down"}), row)
        self.assertIsNone(matched_frame_input(row, {"timer"}))

    def test_new_record_cannot_infer_input_from_last_label_or_global_sequence(self):
        row = actual_frame(seq=999, event="key_down")
        row["frame_inputs"] = []
        self.assertIsNone(matched_frame_input(row, {"key_down"}))

    def test_invalid_counts_timestamps_identity_duplicates_and_bound_fail_closed(self):
        for entries in [
            [dict(event="key_down", count=0, first_received_ns=10)],
            [dict(event="key_down", count=True, first_received_ns=10)],
            [dict(event="key_down", count=1, first_received_ns=51)],
            [dict(event="key_down", count=1, first_received_ns=-1)],
            [dict(event="unknown", count=1, first_received_ns=10)],
            actual_frame()["frame_inputs"] * 2,
            actual_frame()["frame_inputs"] * 6,
        ]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                matched_frame_input(dict(actual_frame(), frame_inputs=entries), {"key_down"})

    def test_batched_wait_requires_all_actual_inputs_despite_large_async_sequence(self):
        run = PtyRun.__new__(PtyRun)
        run.operations = []
        run.timeout = 12.0
        run.master_fd = 99
        run.process = None
        pending = iter([actual_frame(seq=999), actual_frame(seq=1000)])
        run.pump = lambda: run.operations.append(next(pending))
        with patch("scripts.tui_pty_bench.os.write", return_value=2) as write:
            result = run.send_batched(b"xx", 2, {"key_down"})
        self.assertEqual(len(result), 2)
        self.assertEqual(sum(row["matched_input_count"] for row in result), 2)
        write.assert_called_once_with(99, b"xx")

    def test_setup_interval_drains_output_for_the_entire_original_duration(self):
        run = PtyRun.__new__(PtyRun)
        run.process = None
        waits = []
        run.pump = waits.append
        with patch("scripts.tui_pty_bench.time.monotonic", side_effect=[0, 0, 0.2, 0.3]):
            run.drain_for(0.3)
        self.assertEqual(len(waits), 2)
        self.assertAlmostEqual(waits[0], 0.3)
        self.assertAlmostEqual(waits[1], 0.1)

    def test_setup_child_failure_cannot_be_hidden_by_the_drain(self):
        run = PtyRun.__new__(PtyRun)
        run.pump = lambda timeout: None
        run.process = unittest.mock.Mock(returncode=9)
        run.process.poll.return_value = 9
        with patch("scripts.tui_pty_bench.time.monotonic", side_effect=[0, 0]), self.assertRaises(RuntimeError):
            run.drain_for(0.3)

    def test_missing_second_actual_input_remains_a_timeout(self):
        run = PtyRun.__new__(PtyRun)
        run.operations = []
        run.timeout = 12.0
        run.master_fd = 99
        run.process = None
        run.pump = lambda: run.operations.append(actual_frame(seq=999))
        with patch("scripts.tui_pty_bench.os.write", return_value=2), \
                patch("scripts.tui_pty_bench.time.monotonic", side_effect=[0, 0, 13]), \
                self.assertRaises(TimeoutError):
            run.send_batched(b"xx", 2, {"key_down"})


if __name__ == "__main__":
    unittest.main()
