from __future__ import annotations

import unittest

from omp_evals.terminal_completion import (
    analyze_terminal_completion, classify_final_answer_state,
    pending_model_requests, pending_tool_calls,
)


def frame(sequence, code, **detail):
    return {"type": "agent_event", "sequence": sequence,
            "event": {"code": code, **detail}}


class TerminalCompletionContractTests(unittest.TestCase):
    def test_correct_completed_control_has_no_termination_failure(self):
        frames = [
            frame(1, "model.started", request_id="request-1"),
            frame(2, "model.text_delta", text="done"),
            frame(3, "model.completed"),
            frame(4, "model.request_attempt_completed", request_id="request-1"),
            frame(5, "turn.completed"), frame(6, "run.completed"),
        ]
        finding = analyze_terminal_completion(
            trial_id="completed", termination="AgentCompleted", frames=frames,
            last_mutation_sequence=0, last_mutation_at_millis=10,
            termination_at_millis=20, verification_state="Succeeded",
        )
        self.assertEqual(finding.mechanism, "CompletedControl")
        self.assertIsNone(finding.primary)

    def test_partial_final_response_is_pending_but_not_a_lifecycle_mismatch(self):
        frames = [
            frame(1, "tool.execution_completed", name="edit", call_id="edit-1"),
            frame(2, "model.started", request_id="request-final"),
            frame(3, "model.text_delta", text="fixed"),
        ]
        finding = analyze_terminal_completion(
            trial_id="timeout", termination="AgentTimedOut", frames=frames,
            last_mutation_sequence=1, last_mutation_at_millis=100,
            termination_at_millis=300100, verification_state="Succeeded",
        )
        self.assertEqual(finding.primary, "IncompleteFinalModelAttemptAtDeadline")
        self.assertEqual(finding.final_answer_state, "PartialFinalResponseAtDeadline")
        self.assertEqual(finding.post_candidate_tail_millis, 300000)
        self.assertEqual(pending_model_requests(frames), ("request-final",))

    def test_final_answer_without_run_completion_is_lifecycle_mismatch(self):
        frames = [
            frame(1, "model.started", request_id="request-final"),
            frame(2, "model.text_delta", text="done"), frame(3, "model.completed"),
            frame(4, "model.request_attempt_completed", request_id="request-final"),
            frame(5, "turn.completed"),
        ]
        self.assertEqual(
            classify_final_answer_state(frames),
            "FinalAnswerCompletedButRunNotCompleted",
        )
        finding = analyze_terminal_completion(
            trial_id="lifecycle", termination="AgentTimedOut", frames=frames,
            last_mutation_sequence=0, last_mutation_at_millis=1,
            termination_at_millis=2, verification_state="Succeeded",
        )
        self.assertEqual(finding.primary, "LifecycleCompletionNotObserved")

    def test_continued_completed_cycles_are_objectively_counted(self):
        frames = [
            frame(1, "tool.execution_completed", name="edit", call_id="edit-1"),
            frame(2, "model.started", request_id="request-1"),
            frame(3, "model.completed"),
            frame(4, "model.request_attempt_completed", request_id="request-1"),
            frame(5, "tool.execution_started", name="read", call_id="read-1"),
            frame(6, "tool.execution_completed", name="read", call_id="read-1"),
            frame(7, "model.started", request_id="request-2"),
        ]
        finding = analyze_terminal_completion(
            trial_id="continuation", termination="AgentTimedOut", frames=frames,
            last_mutation_sequence=1, last_mutation_at_millis=100,
            termination_at_millis=200, verification_state="Succeeded",
        )
        self.assertEqual(finding.post_candidate_model_calls, 2)
        self.assertEqual(finding.post_candidate_tool_calls, 1)

    def test_pending_tools_are_typed_by_call_lifecycle(self):
        frames = [
            frame(1, "tool.execution_started", name="read", call_id="done"),
            frame(2, "tool.execution_completed", name="read", call_id="done"),
            frame(3, "tool.execution_started", name="bash", call_id="pending"),
        ]
        self.assertEqual(pending_tool_calls(frames), ("pending",))


if __name__ == "__main__":
    unittest.main()
