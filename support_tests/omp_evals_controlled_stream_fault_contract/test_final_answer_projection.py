from __future__ import annotations

import unittest

from omp_evals.worker import _final_answer


def event(code: str, **fields: object) -> dict:
    return {"type": "agent_event", "event": {"code": code, **fields}}


class FinalAnswerProjectionContract(unittest.TestCase):
    def test_exp003_legacy_all_delta_projection_reproduces_the_leak(self) -> None:
        frames = [
            event("model.attempt_started", attempt_id="attempt-1"),
            event("model.text_delta", text="controlled incomplete stream"),
            event("model.attempt_aborted", attempt_id="attempt-1"),
            event("model.attempt_started", attempt_id="attempt-2"),
            event("model.text_delta", text="real final response"),
            event("model.decision_committed", attempt_id="attempt-2"),
        ]
        legacy = "".join(
            frame["event"].get("text", "")
            for frame in frames
            if frame["event"].get("code") == "model.text_delta"
        )
        self.assertEqual(legacy, "controlled incomplete streamreal final response")
        self.assertEqual(_final_answer(frames), "real final response")

    def test_abandoned_attempt_partial_does_not_enter_final_answer(self) -> None:
        frames = [
            event("model.attempt_started", attempt_id="attempt-1"),
            event("model.text_delta", text="controlled incomplete stream"),
            event("model.attempt_aborted", attempt_id="attempt-1"),
        ]
        self.assertEqual(_final_answer(frames), "")
        self.assertEqual(frames[1]["event"]["text"], "controlled incomplete stream")

    def test_retry_final_answer_contains_only_completed_attempt(self) -> None:
        frames = [
            event("model.attempt_started", attempt_id="attempt-1"),
            event("model.text_delta", text="controlled incomplete stream"),
            event("model.attempt_aborted", attempt_id="attempt-1"),
            event("model.attempt_started", attempt_id="attempt-2"),
            event("model.text_delta", text="real final response"),
            event("model.decision_committed", attempt_id="attempt-2"),
        ]
        self.assertEqual(_final_answer(frames), "real final response")

    def test_healthy_single_attempt_final_answer_is_unchanged(self) -> None:
        frames = [
            event("model.attempt_started", attempt_id="attempt-1"),
            event("model.text_delta", text="healthy response"),
            event("model.decision_committed", attempt_id="attempt-1"),
        ]
        self.assertEqual(_final_answer(frames), "healthy response")

    def test_failed_attempt_does_not_replace_last_committed_answer(self) -> None:
        frames = [
            event("model.attempt_started", attempt_id="attempt-1"),
            event("model.text_delta", text="committed response"),
            event("model.decision_committed", attempt_id="attempt-1"),
            event("model.attempt_started", attempt_id="attempt-2"),
            event("model.text_delta", text="later abandoned partial"),
            event("model.attempt_failed", attempt_id="attempt-2"),
        ]
        self.assertEqual(_final_answer(frames), "committed response")

    def test_legacy_unscoped_trajectory_remains_compatible(self) -> None:
        frames = [event("model.text_delta", text="legacy "), event("model.text_delta", text="answer")]
        self.assertEqual(_final_answer(frames), "legacy answer")


if __name__ == "__main__":
    unittest.main()
