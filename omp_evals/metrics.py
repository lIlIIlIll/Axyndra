from __future__ import annotations

from collections import Counter
from typing import Any, Mapping, Optional, Sequence

from .model import AgentTermination, CandidateOutcome, TrajectoryMetrics


_READ_TOOLS = {"read"}
_SEARCH_TOOLS = {"grep", "glob", "find", "ast_grep"}
_EDIT_TOOLS = {"write", "edit", "apply_patch", "ast_edit"}
_SHELL_TOOLS = {"bash", "bash_readonly", "shell", "exec"}


def derive_trajectory_metrics(
    frames: Sequence[Mapping[str, Any]], usage: Mapping[str, Any],
    candidate_outcome: Optional[CandidateOutcome] = None,
    termination: Optional[AgentTermination] = None,
) -> TrajectoryMetrics:
    """Derive only metrics supported by canonical typed events.

    Shell command text is deliberately not inspected.  Consequently build/test
    verification and timing metrics remain explicitly unsupported in v0.2.
    """
    model_calls = 0
    model_attempts = 0
    tools: list[tuple[int, str]] = []
    failed = 0
    compactions = 0
    last_mutation = None
    event_usage = {"input": 0, "cached": 0, "output": 0}
    saw_event_usage = False
    event_cost = 0
    saw_event_cost = False
    mutations: list[int] = []
    last_operation = None
    last_model_completion = None
    for sequence, frame in enumerate(frames):
        event = frame.get("event")
        if not isinstance(event, Mapping):
            continue
        code = str(event.get("code", ""))
        if code == "model.started":
            model_calls += 1
        elif code == "model.request_attempt_completed":
            model_attempts += 1
        elif code == "model.completed":
            last_model_completion = sequence
        elif code == "context.compacted":
            compactions += 1
        elif code == "model.usage":
            saw_event_usage = True
            event_usage["input"] += int(event.get("input_tokens", 0) or 0)
            event_usage["cached"] += int(event.get("cache_read_tokens", 0) or 0)
            event_usage["output"] += int(event.get("output_tokens", 0) or 0)
            if isinstance(event.get("cost_micros"), (int, float)):
                event_cost += int(event["cost_micros"])
                saw_event_cost = True
        elif code == "tool.execution_started":
            name = str(event.get("name", ""))
            tools.append((sequence, name))
        elif code == "tool.execution_completed" and bool(event.get("is_error", False)):
            failed += 1
            last_operation = sequence
        elif code == "tool.execution_completed":
            last_operation = sequence
            if str(event.get("name", "")) in _EDIT_TOOLS:
                mutations.append(sequence)
                last_mutation = sequence
    names = [name for _, name in tools]
    return TrajectoryMetrics(
        model_calls=max(model_attempts, model_calls),
        tool_calls=len(names),
        read_calls=sum(name in _READ_TOOLS for name in names),
        search_calls=sum(name in _SEARCH_TOOLS for name in names),
        edit_calls=sum(name in _EDIT_TOOLS for name in names),
        shell_calls=sum(name in _SHELL_TOOLS for name in names),
        failed_tool_calls=failed,
        compaction_count=compactions,
        input_tokens=_usage_int(usage, "inputTokens", "input_tokens", "input")
        if _has_usage(usage, "inputTokens", "input_tokens", "input") else event_usage["input"] if saw_event_usage else None,
        cached_tokens=_usage_int(usage, "cachedTokens", "cached_tokens", "cached")
        if _has_usage(usage, "cachedTokens", "cached_tokens", "cached") else event_usage["cached"] if saw_event_usage else None,
        output_tokens=_usage_int(usage, "outputTokens", "output_tokens", "output")
        if _has_usage(usage, "outputTokens", "output_tokens", "output") else event_usage["output"] if saw_event_usage else None,
        cost_micros=_usage_int(usage, "costMicros", "cost_micros")
        if _has_usage(usage, "costMicros", "cost_micros") else event_cost if saw_event_cost else None,
        last_mutation_sequence=last_mutation,
        verified_final_state=None,
        unsupported=(
            "buildRuns", "testRuns", "timeToFirstTool", "timeToFirstEdit",
            "timeToFirstVerification", "lastSuccessfulVerificationAt",
            "verifiedFinalState", "networkAttemptCount",
        ),
        tool_calls_by_tool=dict(sorted(Counter(names).items())),
        failed_operations=failed,
        candidate_mutation_count=len(mutations),
        first_candidate_mutation_sequence=mutations[0] if mutations else None,
        last_candidate_mutation_sequence=mutations[-1] if mutations else None,
        last_operation_sequence=last_operation,
        last_model_completion_sequence=last_model_completion,
        final_candidate_outcome=candidate_outcome,
        termination=termination,
    )


def _usage_int(usage: Mapping[str, Any], *names: str) -> int:
    tokens = usage.get("tokens")
    if isinstance(tokens, Mapping):
        usage = {**tokens, **usage}
    for name in names:
        value = usage.get(name)
        if isinstance(value, (int, float)):
            return int(value)
    return 0


def _has_usage(usage: Mapping[str, Any], *names: str) -> bool:
    tokens = usage.get("tokens")
    return any(name in usage for name in names) or (
        isinstance(tokens, Mapping) and any(name in tokens for name in names)
    )
