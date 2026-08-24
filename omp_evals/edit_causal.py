from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, Callable, Mapping, Optional, Sequence

from .storage import ArtifactStore


class EditCommandKind(str, Enum):
    SWAP_SINGLE = "SWAP_SINGLE"
    SWAP_RANGE = "SWAP_RANGE"
    DEL_SINGLE = "DEL_SINGLE"
    DEL_RANGE = "DEL_RANGE"
    INSERT = "INSERT"
    UNKNOWN = "UNKNOWN"


class EditRejectionCause(str, Enum):
    RANGE_GRAMMAR_MISMATCH = "RangeGrammarMismatch"
    MALFORMED_COMMAND = "MalformedCommand"
    UNKNOWN_COMMAND = "UnknownCommand"
    MISSING_REPLACEMENT_BODY = "MissingReplacementBody"
    INVALID_HEADER = "InvalidHeader"
    INVALID_HASHLINE_TAG = "InvalidHashlineTag"
    STALE_ANCHOR = "StaleAnchor"
    TARGET_NOT_FOUND = "TargetNotFound"
    AMBIGUOUS_TARGET = "AmbiguousTarget"
    WORKSPACE_BOUNDARY = "WorkspaceBoundary"
    EXPECTED_CONTENT_MISMATCH = "ExpectedContentMismatch"
    OVERLAPPING_EDIT = "OverlappingEdit"
    APPLICATION_FAILURE = "ApplicationFailure"
    UNKNOWN = "Unknown"


class EditFixEffect(str, Enum):
    DIRECT_FIX = "DirectFix"
    ENABLING_FIX = "EnablingFix"
    NO_EFFECT = "NoEffect"
    UNKNOWN = "Unknown"


class EditSyntaxViolation(str, Enum):
    MISSING_REQUIRED_COLON = "MissingRequiredColon"
    INVALID_HEADER = "InvalidHeader"
    MALFORMED_COMMAND_OTHER = "MalformedCommandOther"


@dataclass(frozen=True)
class ReplayOutcome:
    parser_outcome: str
    application_outcome: str
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    candidate_changed: bool = False


@dataclass(frozen=True)
class HistoricalEditAttempt:
    trial_id: str
    attempt_ordinal: int
    trajectory_sequence: Optional[int]
    completion_sequence: Optional[int]
    operation_id: Optional[str]
    started_artifact_ref: str
    completed_artifact_ref: Optional[str]
    raw_model_arguments: Mapping[str, Any]
    raw_edit_payload: str
    tool_name: str
    path: Optional[str]
    command_kind: EditCommandKind
    range_syntax_observed: Optional[str]
    historical_outcome: ReplayOutcome


def extract_historical_edit_attempts(
    trial_id: str, operation_refs: Sequence[str], artifacts: ArtifactStore,
) -> tuple[HistoricalEditAttempt, ...]:
    frames: list[tuple[str, Mapping[str, Any]]] = []
    for reference in operation_refs:
        value = json.loads(artifacts.get_bytes(reference))
        frames.append((reference, value))
    completions = {
        frame.get("event", {}).get("call_id"): (reference, frame)
        for reference, frame in frames
        if frame.get("event", {}).get("code") == "tool.execution_completed"
    }
    result: list[HistoricalEditAttempt] = []
    for reference, frame in frames:
        event = frame.get("event", {})
        if event.get("code") != "tool.execution_started" or event.get("name") != "edit":
            continue
        arguments = event.get("arguments") if isinstance(event.get("arguments"), Mapping) else {}
        payload = arguments.get("input") if isinstance(arguments.get("input"), str) else ""
        completed_ref, completed = completions.get(event.get("call_id"), (None, {}))
        completed_event = completed.get("event", {})
        output = completed_event.get("output") if isinstance(completed_event.get("output"), Mapping) else {}
        is_error = completed_event.get("is_error") is not False
        result.append(HistoricalEditAttempt(
            trial_id=trial_id,
            attempt_ordinal=len(result) + 1,
            trajectory_sequence=frame.get("sequence"),
            completion_sequence=completed.get("sequence"),
            operation_id=completed_event.get("receipt_id"),
            started_artifact_ref=reference,
            completed_artifact_ref=completed_ref,
            raw_model_arguments=dict(arguments),
            raw_edit_payload=payload,
            tool_name="edit",
            path=_path(payload),
            command_kind=classify_command(payload),
            range_syntax_observed=_range_syntax(payload),
            historical_outcome=ReplayOutcome(
                parser_outcome="Rejected" if is_error else "Accepted",
                application_outcome="NotReached" if is_error else "Applied",
                error_code=output.get("error"),
                error_message=output.get("message"),
                candidate_changed=not is_error and bool(output.get("changed")),
            ),
        ))
    return tuple(result)


def classify_command(payload: str) -> EditCommandKind:
    command = _command_line(payload)
    if re.fullmatch(r"SWAP\s+\d+:", command):
        return EditCommandKind.SWAP_SINGLE
    if re.fullmatch(r"SWAP\s+\d+(?:\.\.=|\.=)\d+:", command):
        return EditCommandKind.SWAP_RANGE
    # Classification describes intent even when the required trailing colon is absent.
    if re.fullmatch(r"SWAP\s+\d+", command):
        return EditCommandKind.SWAP_SINGLE
    if re.fullmatch(r"SWAP\s+\d+(?:\.\.=|\.=)\d+", command):
        return EditCommandKind.SWAP_RANGE
    if re.fullmatch(r"DEL\s+\d+", command):
        return EditCommandKind.DEL_SINGLE
    if re.fullmatch(r"DEL\s+\d+(?:\.\.=|\.=)\d+", command):
        return EditCommandKind.DEL_RANGE
    if re.fullmatch(r"INS\.(?:HEAD|TAIL):?", command) or re.fullmatch(
        r"INS\.(?:PRE|POST)\s+\d+:?", command
    ):
        return EditCommandKind.INSERT
    return EditCommandKind.UNKNOWN


def rejection_cause(attempt: HistoricalEditAttempt) -> Optional[EditRejectionCause]:
    outcome = attempt.historical_outcome
    if outcome.parser_outcome != "Rejected":
        return None
    message = outcome.error_message or ""
    if "header is malformed" in message or "before the first [path#TAG]" in message:
        return EditRejectionCause.INVALID_HEADER
    if "stale hashline anchor" in message:
        return EditRejectionCause.STALE_ANCHOR
    if "overlap" in message:
        return EditRejectionCause.OVERLAPPING_EDIT
    if "outside" in message or outcome.error_code == "workspace.path_escape":
        return EditRejectionCause.WORKSPACE_BOUNDARY
    if "unsupported hashline operation" in message:
        command = _command_line(attempt.raw_edit_payload)
        if attempt.command_kind in (
            EditCommandKind.SWAP_SINGLE, EditCommandKind.SWAP_RANGE, EditCommandKind.INSERT,
        ) and not command.endswith(":"):
            return EditRejectionCause.MALFORMED_COMMAND
        if attempt.command_kind == EditCommandKind.SWAP_RANGE and "..=" in command:
            return EditRejectionCause.RANGE_GRAMMAR_MISMATCH
        return EditRejectionCause.UNKNOWN_COMMAND
    if outcome.error_code == "edit.invalid_hashline":
        return EditRejectionCause.MALFORMED_COMMAND
    return EditRejectionCause.UNKNOWN


def syntax_violation(
    payload: str, *, error_code: Optional[str] = None, error_message: Optional[str] = None,
) -> Optional[EditSyntaxViolation]:
    """Classify mechanical syntax violations from raw input and canonical hashline grammar."""
    command = _command_line(payload)
    missing_colon = (
        re.fullmatch(r"SWAP\s+\d+(?:\.\.=\d+)?", command) is not None or
        re.fullmatch(r"INS\.(?:HEAD|TAIL)", command) is not None or
        re.fullmatch(r"INS\.(?:PRE|POST)\s+\d+", command) is not None
    )
    if missing_colon:
        return EditSyntaxViolation.MISSING_REQUIRED_COLON
    message = error_message or ""
    if "header is malformed" in message or "before the first [path#TAG]" in message:
        return EditSyntaxViolation.INVALID_HEADER
    if error_code == "edit.invalid_hashline":
        return EditSyntaxViolation.MALFORMED_COMMAND_OTHER
    return None


def edit_syntax_metrics(attempts: Sequence[HistoricalEditAttempt]) -> Mapping[str, Any]:
    violations = [
        syntax_violation(
            item.raw_edit_payload,
            error_code=item.historical_outcome.error_code,
            error_message=item.historical_outcome.error_message,
        )
        for item in attempts
    ]
    counts = {value.value: violations.count(value) for value in EditSyntaxViolation}
    return {
        "totalEditAttempts": len(attempts),
        "missingRequiredColonAttempts": counts[EditSyntaxViolation.MISSING_REQUIRED_COLON.value],
        "trialsWithMissingRequiredColon": int(
            counts[EditSyntaxViolation.MISSING_REQUIRED_COLON.value] > 0
        ),
        "violations": counts,
    }


def analyze_candidate_edit_syntax(
    trial_id: str, candidate: Mapping[str, Any], artifacts: ArtifactStore,
) -> Mapping[str, Any]:
    """Offline-only metric derivation from immutable Candidate operation artifacts."""
    attempts = extract_historical_edit_attempts(
        trial_id, tuple(candidate.get("operation_refs", ())), artifacts,
    )
    metrics = dict(edit_syntax_metrics(attempts))
    metrics.update({
        "successfulEditApplications": sum(
            item.historical_outcome.application_outcome == "Applied" for item in attempts
        ),
        "rejectedEditAttempts": sum(
            item.historical_outcome.parser_outcome == "Rejected" or
            item.historical_outcome.application_outcome == "Rejected" for item in attempts
        ),
        "commandKinds": {
            kind.value: sum(item.command_kind == kind for item in attempts)
            for kind in EditCommandKind
        },
        "source": "immutable operation artifacts",
        "modelCalls": 0,
        "graderExecutions": 0,
    })
    return metrics


def fix_effect(
    historical: ReplayOutcome, condition_b: ReplayOutcome, *, feedback_actionable: bool = False,
) -> EditFixEffect:
    if historical.parser_outcome == "Rejected" and condition_b.parser_outcome == "Accepted":
        return EditFixEffect.DIRECT_FIX
    if historical.parser_outcome == "Rejected" and condition_b.parser_outcome == "Rejected":
        if feedback_actionable and historical.error_message != condition_b.error_message:
            return EditFixEffect.ENABLING_FIX
        return EditFixEffect.NO_EFFECT
    if historical.parser_outcome == condition_b.parser_outcome:
        return EditFixEffect.NO_EFFECT
    return EditFixEffect.UNKNOWN


def attempt_record(
    attempt: HistoricalEditAttempt, condition_b: ReplayOutcome, *,
    pre_state_level: str, pre_state_evidence: Sequence[str], feedback_actionable: bool = False,
) -> Mapping[str, Any]:
    cause = rejection_cause(attempt)
    return {
        **asdict(attempt),
        "command_kind": attempt.command_kind.value,
        "historical_outcome": asdict(attempt.historical_outcome),
        "condition_a_replay": {
            **asdict(attempt.historical_outcome),
            "evidence": "exact historical execution under frozen baseline condition",
        },
        "condition_b_replay": asdict(condition_b),
        "rejection_cause": cause.value if cause else None,
        "condition_b_effect": fix_effect(
            attempt.historical_outcome, condition_b,
            feedback_actionable=feedback_actionable,
        ).value,
        "pre_operation_state": {
            "level": pre_state_level,
            "evidence": list(pre_state_evidence),
        },
    }


def _path(payload: str) -> Optional[str]:
    first = payload.split("\n", 1)[0]
    match = re.fullmatch(r"\[([^#\]]+)#[^\]]+\]", first)
    return match.group(1) if match else None


def _command_line(payload: str) -> str:
    lines = payload.splitlines()
    return lines[1].strip() if len(lines) > 1 and lines[0].startswith("[") else ""


def _range_syntax(payload: str) -> Optional[str]:
    command = _command_line(payload)
    if "..=" in command:
        return "N..=M"
    if ".=" in command:
        return "N.=M"
    return None
