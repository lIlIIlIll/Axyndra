from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any, Mapping, Optional, Sequence


_IDENTIFIER_MILLIS = re.compile(r"^(?:run|operation)-(\d{13})-")


@dataclass(frozen=True)
class TerminalCompletionFinding:
    trial_id: str
    termination: str
    last_candidate_mutation_sequence: int
    last_candidate_mutation_at_millis: int
    termination_at_millis: int
    post_candidate_tail_millis: int
    post_candidate_model_calls: int
    post_candidate_tool_calls: int
    verification_state: str
    final_answer_state: str
    pending_model_request_ids: tuple[str, ...]
    pending_tool_call_ids: tuple[str, ...]
    run_lifecycle_state: str
    mechanism: str
    primary: Optional[str]
    contributing: tuple[str, ...]
    confidence: float


def identifier_millis(identifier: str) -> int:
    match = _IDENTIFIER_MILLIS.match(identifier)
    if match is None:
        raise ValueError(f"identifier has no embedded Unix milliseconds: {identifier}")
    return int(match.group(1))


def event_code(frame: Mapping[str, Any]) -> str:
    event = frame.get("event")
    return str(event.get("code", "")) if isinstance(event, Mapping) else ""


def event_sequence(frame: Mapping[str, Any]) -> Optional[int]:
    value = frame.get("sequence")
    return int(value) if isinstance(value, (int, float)) else None


def pending_model_requests(frames: Sequence[Mapping[str, Any]]) -> tuple[str, ...]:
    started: list[str] = []
    completed: set[str] = set()
    for frame in frames:
        event = frame.get("event")
        if not isinstance(event, Mapping):
            continue
        if event.get("code") == "model.started" and isinstance(event.get("request_id"), str):
            started.append(str(event["request_id"]))
        elif event.get("code") == "model.request_attempt_completed" and isinstance(event.get("request_id"), str):
            completed.add(str(event["request_id"]))
    return tuple(request_id for request_id in started if request_id not in completed)


def pending_tool_calls(frames: Sequence[Mapping[str, Any]]) -> tuple[str, ...]:
    started: list[str] = []
    completed: set[str] = set()
    for frame in frames:
        event = frame.get("event")
        if not isinstance(event, Mapping):
            continue
        code = event.get("code")
        call_id = event.get("call_id")
        if code == "tool.execution_started" and isinstance(call_id, str):
            started.append(call_id)
        elif code in ("tool.execution_completed", "tool.execution_failed") and isinstance(call_id, str):
            completed.add(call_id)
    return tuple(call_id for call_id in started if call_id not in completed)


def model_request_summaries(frames: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    current: Optional[dict[str, Any]] = None
    for frame in frames:
        event = frame.get("event")
        if not isinstance(event, Mapping):
            continue
        code = str(event.get("code", ""))
        sequence = event_sequence(frame)
        if code == "model.started":
            current = {
                "requestId": event.get("request_id"),
                "startedSequence": sequence,
                "completedSequence": None,
                "attemptCompletedSequence": None,
                "turnCompletedSequence": None,
                "textDeltaCount": 0,
                "reasoningDeltaCount": 0,
                "toolCallCount": 0,
                "text": "",
                "usage": None,
            }
            summaries.append(current)
        elif current is not None:
            if code == "model.text_delta":
                current["textDeltaCount"] += 1
                current["text"] += str(event.get("text", ""))
            elif code == "model.reasoning_delta":
                current["reasoningDeltaCount"] += 1
            elif code == "model.tool_started":
                current["toolCallCount"] += 1
            elif code == "model.completed":
                current["completedSequence"] = sequence
            elif code == "model.request_attempt_completed":
                current["attemptCompletedSequence"] = sequence
                current["usage"] = event.get("usage")
            elif code == "turn.completed":
                current["turnCompletedSequence"] = sequence
    for summary in summaries:
        text = summary.pop("text")
        summary["textBytes"] = len(text.encode())
        summary["textSha256"] = hashlib.sha256(text.encode()).hexdigest()
        summary["textPreview"] = text[:240]
        summary["textTail"] = text[-160:]
        summary["isFinalResponseShape"] = bool(text) and summary["toolCallCount"] == 0
        summary["completed"] = summary["attemptCompletedSequence"] is not None
    return summaries


def classify_final_answer_state(frames: Sequence[Mapping[str, Any]]) -> str:
    requests = model_request_summaries(frames)
    if not requests:
        return "NotProduced"
    last = requests[-1]
    run_completed = any(event_code(frame) == "run.completed" for frame in frames)
    if run_completed and last["completed"] and last["isFinalResponseShape"]:
        return "ProducedAndRunCompleted"
    if last["completed"] and last["turnCompletedSequence"] is not None and not run_completed:
        return "FinalAnswerCompletedButRunNotCompleted"
    if not last["completed"] and last["isFinalResponseShape"]:
        return "PartialFinalResponseAtDeadline"
    return "NotProduced"


def analyze_terminal_completion(
    *, trial_id: str, termination: str, frames: Sequence[Mapping[str, Any]],
    last_mutation_sequence: int, last_mutation_at_millis: int,
    termination_at_millis: int, verification_state: str,
) -> TerminalCompletionFinding:
    post = [
        frame for frame in frames
        if (event_sequence(frame) or -1) > last_mutation_sequence
    ]
    pending_models = pending_model_requests(frames)
    pending_tools = pending_tool_calls(frames)
    final_state = classify_final_answer_state(frames)
    run_completed = any(event_code(frame) == "run.completed" for frame in frames)
    turn_completed = any(event_code(frame) == "turn.completed" for frame in frames)

    if termination == "AgentCompleted" and run_completed:
        mechanism = "CompletedControl"
        primary = None
        contributing: tuple[str, ...] = ()
        confidence = 1.0
    elif final_state == "FinalAnswerCompletedButRunNotCompleted":
        mechanism = "RunCompletionLifecycleFailure"
        primary = "LifecycleCompletionNotObserved"
        contributing = ()
        confidence = 0.99
    elif final_state == "PartialFinalResponseAtDeadline" and pending_models:
        mechanism = "FinalResponseStreamingIncompleteAtDeadline"
        primary = "IncompleteFinalModelAttemptAtDeadline"
        contributing = ("PostCandidateVerificationAndFinalization",)
        confidence = 0.99
    elif pending_models:
        mechanism = "ModelAttemptIncompleteAtDeadline"
        primary = "IncompleteModelAttemptAtDeadline"
        contributing = ("PostCandidateContinuation",)
        confidence = 0.95
    else:
        mechanism = "Unknown"
        primary = "AgentTerminationFailure"
        contributing = ()
        confidence = 0.5

    return TerminalCompletionFinding(
        trial_id=trial_id,
        termination=termination,
        last_candidate_mutation_sequence=last_mutation_sequence,
        last_candidate_mutation_at_millis=last_mutation_at_millis,
        termination_at_millis=termination_at_millis,
        post_candidate_tail_millis=termination_at_millis - last_mutation_at_millis,
        post_candidate_model_calls=sum(event_code(frame) == "model.started" for frame in post),
        post_candidate_tool_calls=sum(event_code(frame) == "tool.execution_started" for frame in post),
        verification_state=verification_state,
        final_answer_state=final_state,
        pending_model_request_ids=pending_models,
        pending_tool_call_ids=pending_tools,
        run_lifecycle_state=("RunCompleted" if run_completed else
                             "RunningWithEarlierTurnsCompleted" if turn_completed else "Running"),
        mechanism=mechanism,
        primary=primary,
        contributing=contributing,
        confidence=confidence,
    )


def finding_json(finding: TerminalCompletionFinding) -> dict[str, Any]:
    return {
        "trialId": finding.trial_id,
        "termination": finding.termination,
        "lastCandidateMutationSequence": finding.last_candidate_mutation_sequence,
        "lastCandidateMutationAtMillis": finding.last_candidate_mutation_at_millis,
        "terminationAtMillis": finding.termination_at_millis,
        "postCandidateTailMs": finding.post_candidate_tail_millis,
        "postCandidateModelCalls": finding.post_candidate_model_calls,
        "postCandidateToolCalls": finding.post_candidate_tool_calls,
        "verificationState": finding.verification_state,
        "finalAnswerState": finding.final_answer_state,
        "pendingModelRequestIds": list(finding.pending_model_request_ids),
        "pendingToolCallIds": list(finding.pending_tool_call_ids),
        "runLifecycleState": finding.run_lifecycle_state,
        "mechanism": finding.mechanism,
        "primary": finding.primary,
        "contributing": list(finding.contributing),
        "confidence": finding.confidence,
    }
