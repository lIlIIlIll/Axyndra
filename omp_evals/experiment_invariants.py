from __future__ import annotations

from dataclasses import fields
from typing import Any, Mapping, Sequence

from .model import (
    ExperimentConditionInvariant, ExperimentInvariantSnapshot,
    ExperimentalCondition, ExperimentPlan, ExperimentTrial, QualifiedEvalTask, jsonable,
)
from .util import canonical_json, hash_json, sha256_bytes


EXPERIMENT_INVARIANT_SCHEMA_VERSION = "omp-evals-experiment-invariants-v4"
LEGACY_PROVIDER_INVARIANT_SCHEMA_VERSION = "omp-evals-experiment-invariants-v3"
LEGACY_TYPED_INVARIANT_SCHEMA_VERSION = "omp-evals-experiment-invariants-v2"


class UnsupportedInvariantSchema(ValueError):
    pass


class ExperimentInvariantMismatch(ValueError):
    def __init__(self, schema_version: str, differences: Sequence[Mapping[str, Any]]):
        self.schema_version = schema_version
        self.differences = tuple(dict(item) for item in differences)
        fields_text = ", ".join(str(item["field"]) for item in self.differences)
        super().__init__(
            f"experiment invariant mismatch ({schema_version}): {fields_text or 'unknown'}"
        )


def build_experiment_invariant_snapshot(
    tasks: Sequence[QualifiedEvalTask],
    conditions: Sequence[ExperimentalCondition],
    paired: bool,
) -> ExperimentInvariantSnapshot:
    if paired and len(conditions) != 2:
        raise ValueError("paired A/B requires exactly two conditions")
    environment_classes = {
        str(item.manifest.get("environmentFingerprint", item.manifest.get("environmentClass", "unsupported")))
        for item in conditions
    }
    tool_planes = {
        str(item.manifest.get("toolExecutionPlaneDigest", "unsupported"))
        for item in conditions
    }
    if paired and ("unsupported" in environment_classes or len(environment_classes) != 1):
        raise ValueError("paired A/B requires the same environment class")
    if paired and len(tool_planes) != 1:
        raise ValueError("paired A/B requires the same ToolExecutionPlane")
    condition_values = tuple(_condition_invariant(item) for item in conditions)
    return ExperimentInvariantSnapshot(
        schema_version=EXPERIMENT_INVARIANT_SCHEMA_VERSION,
        paired_by_task=paired,
        condition_scope="agent-and-harness-only",
        task_fingerprints=tuple(item.task_fingerprint for item in tasks),
        condition_fingerprints=tuple(item.fingerprint for item in conditions),
        fixture_digests={item.task_fingerprint: item.fixture_digest for item in tasks},
        task_prompt_digests={
            item.task_fingerprint: hash_json({
                "prompt": item.prompt, "visibleConstraints": item.visible_constraints,
            }) for item in tasks
        },
        grader_spec_digests={
            item.task_fingerprint: hash_json(item.graders) for item in tasks
        },
        budget_digests={
            item.task_fingerprint: hash_json(jsonable(item.resource_policy)) for item in tasks
        },
        environment_class=next(iter(environment_classes)) if environment_classes else "unsupported",
        tool_execution_plane_digest=next(iter(tool_planes)) if tool_planes else "unsupported",
        conditions=condition_values,
    )


def canonical_invariant_bytes(snapshot: ExperimentInvariantSnapshot) -> bytes:
    _require_supported_schema(snapshot.schema_version)
    value = jsonable(snapshot)
    if snapshot.schema_version == LEGACY_TYPED_INVARIANT_SCHEMA_VERSION:
        for condition in value["conditions"]:
            condition.pop("provider_execution_digest", None)
            condition.pop("provider_settings_closure_digest", None)
            condition.pop("provider_settings_closure_ref", None)
            condition.pop("provider_settings_materializer_version", None)
    elif snapshot.schema_version == LEGACY_PROVIDER_INVARIANT_SCHEMA_VERSION:
        for condition in value["conditions"]:
            condition.pop("provider_settings_closure_digest", None)
            condition.pop("provider_settings_closure_ref", None)
            condition.pop("provider_settings_materializer_version", None)
    return canonical_json(value)


def invariant_snapshot_digest(snapshot: ExperimentInvariantSnapshot) -> str:
    return sha256_bytes(canonical_invariant_bytes(snapshot))


def parse_experiment_invariant_snapshot(value: Mapping[str, Any]) -> ExperimentInvariantSnapshot:
    allowed = {item.name for item in fields(ExperimentInvariantSnapshot)}
    missing = allowed - set(value)
    unknown = set(value) - allowed
    if missing:
        raise ValueError("missing experiment invariant fields: " + ", ".join(sorted(missing)))
    if unknown:
        raise ValueError("unknown experiment invariant fields: " + ", ".join(sorted(unknown)))
    schema_version = str(value["schema_version"])
    _require_supported_schema(schema_version)
    condition_allowed = {item.name for item in fields(ExperimentConditionInvariant)}
    conditions = []
    for index, raw in enumerate(value["conditions"]):
        raw = dict(raw)
        if schema_version == LEGACY_TYPED_INVARIANT_SCHEMA_VERSION:
            raw["provider_execution_digest"] = "legacy-unfrozen"
        if schema_version in (
            LEGACY_TYPED_INVARIANT_SCHEMA_VERSION,
            LEGACY_PROVIDER_INVARIANT_SCHEMA_VERSION,
        ):
            raw["provider_settings_closure_digest"] = "legacy-unfrozen"
            raw["provider_settings_closure_ref"] = "legacy-unfrozen"
            raw["provider_settings_materializer_version"] = "legacy-unfrozen"
        condition_missing = condition_allowed - set(raw)
        condition_unknown = set(raw) - condition_allowed
        if condition_missing:
            raise ValueError(
                f"missing condition invariant fields at {index}: "
                + ", ".join(sorted(condition_missing))
            )
        if condition_unknown:
            raise ValueError(
                f"unknown condition invariant fields at {index}: "
                + ", ".join(sorted(condition_unknown))
            )
        conditions.append(ExperimentConditionInvariant(**raw))
    return ExperimentInvariantSnapshot(
        schema_version=str(value["schema_version"]),
        paired_by_task=bool(value["paired_by_task"]),
        condition_scope=str(value["condition_scope"]),
        task_fingerprints=tuple(value["task_fingerprints"]),
        condition_fingerprints=tuple(value["condition_fingerprints"]),
        fixture_digests=dict(value["fixture_digests"]),
        task_prompt_digests=dict(value["task_prompt_digests"]),
        grader_spec_digests=dict(value["grader_spec_digests"]),
        budget_digests=dict(value["budget_digests"]),
        environment_class=str(value["environment_class"]),
        tool_execution_plane_digest=str(value["tool_execution_plane_digest"]),
        conditions=tuple(conditions),
    )


def experiment_plan_from_mapping(
    value: Mapping[str, Any], *, legacy_suite_fingerprint: str = "legacy-unstored",
    legacy_created_at: str = "legacy-unstored",
) -> ExperimentPlan:
    """Read current and historical plan artifacts without upgrading legacy semantics."""
    schema_version = value.get("invariantSchemaVersion", value.get("invariant_schema_version"))
    raw_snapshot = value.get("invariantSnapshot", value.get("invariant_snapshot"))
    raw_digest = value.get("invariantSnapshotDigest", value.get("invariant_snapshot_digest"))
    if schema_version is None:
        snapshot = None
        digest = None
    else:
        _require_supported_schema(str(schema_version))
        if raw_snapshot is None or raw_digest is None:
            raise ValueError("current-schema experiment plan is missing its invariant snapshot")
        snapshot = parse_experiment_invariant_snapshot(raw_snapshot)
        digest = str(raw_digest)
        if invariant_snapshot_digest(snapshot) != digest:
            raise ValueError("experiment invariant snapshot digest is invalid")
    raw_order = value.get("order", ())
    order = tuple(ExperimentTrial(
        ordinal=int(item["ordinal"]),
        task_fingerprint=str(item.get("task_fingerprint", item.get("taskFingerprint"))),
        condition_fingerprint=str(
            item.get("condition_fingerprint", item.get("conditionFingerprint"))
        ),
        repetition_index=int(item.get("repetition_index", item.get("repetitionIndex"))),
        trial_id=item.get("trial_id", item.get("trialId")),
        grading_run_id=item.get("grading_run_id", item.get("gradingRunId")),
    ) for item in raw_order)
    return ExperimentPlan(
        id=str(value.get("id", value.get("experimentId"))),
        kind=str(value["kind"]),
        suite_fingerprint=str(
            value.get("suite_fingerprint", value.get("suiteFingerprint", legacy_suite_fingerprint))
        ),
        condition_fingerprints=tuple(
            value.get("condition_fingerprints", value.get("conditionFingerprints", ()))
        ),
        trials_per_task=int(
            value.get("trials_per_task", value.get("trialsPerCondition", value.get("trialsPerTask")))
        ),
        seed=int(value["seed"]), order=order,
        created_at=str(value.get("created_at", value.get("createdAt", legacy_created_at))),
        invariants=dict(value.get("invariants", {})),
        invariant_schema_version=None if schema_version is None else str(schema_version),
        invariant_snapshot=snapshot, invariant_snapshot_digest=digest,
    )


def validate_experiment_invariant_snapshot(
    frozen: ExperimentInvariantSnapshot,
    frozen_digest: str,
    current: ExperimentInvariantSnapshot,
) -> None:
    _require_supported_schema(frozen.schema_version)
    if frozen.schema_version != current.schema_version:
        raise ExperimentInvariantMismatch(frozen.schema_version, ({
            "field": "schema_version", "frozen": frozen.schema_version,
            "current": current.schema_version,
        },))
    if invariant_snapshot_digest(frozen) != frozen_digest:
        raise ExperimentInvariantMismatch(frozen.schema_version, ({
            "field": "invariant_snapshot_digest",
            "frozen": frozen_digest,
            "current": invariant_snapshot_digest(frozen),
        },))
    differences = _differences(jsonable(frozen), jsonable(current))
    if differences:
        raise ExperimentInvariantMismatch(frozen.schema_version, differences)


def legacy_experiment_invariants(snapshot: ExperimentInvariantSnapshot) -> Mapping[str, Any]:
    """Historical projection only; current plans persist the full typed snapshot."""
    return {
        "pairedByTask": snapshot.paired_by_task,
        "taskFingerprints": list(snapshot.task_fingerprints),
        "fixtureDigests": dict(snapshot.fixture_digests),
        "graderSpecDigests": dict(snapshot.grader_spec_digests),
        "budgetDigests": dict(snapshot.budget_digests),
        "environmentClass": snapshot.environment_class,
        "conditionScope": snapshot.condition_scope,
    }


def _condition_invariant(condition: ExperimentalCondition) -> ExperimentConditionInvariant:
    manifest = condition.manifest
    tool_plane = manifest.get("toolExecutionPlane") or {}
    return ExperimentConditionInvariant(
        condition_fingerprint=condition.fingerprint,
        provider=str(manifest.get("provider", "unsupported")),
        model=str(manifest.get("model", "unsupported")),
        settings_manifest_digest=str(manifest.get("settingsManifestDigest", "unsupported")),
        system_prompt_digest=str(manifest.get("systemPromptDigest", "unsupported")),
        general_prompt_digest=str(manifest.get("generalPromptDigest", "unsupported")),
        context_policy_digest=str(manifest.get("contextPolicyDigest", "unsupported")),
        compaction_policy_digest=str(manifest.get("compactionPolicyDigest", "unsupported")),
        permission_profile_digest=str(manifest.get("permissionProfileDigest", "unsupported")),
        non_edit_tool_set_digest=str(manifest.get("nonEditToolSetDigest", "unsupported")),
        tool_set_digest=str(manifest.get("toolSetDigest", "unsupported")),
        runtime_closure_digest=str(manifest.get("runtimeClosureDigest", "unsupported")),
        runtime_closure_ref=str(manifest.get("runtimeClosureRef", "unsupported")),
        environment_fingerprint=str(
            manifest.get("environmentFingerprint", manifest.get("environmentClass", "unsupported"))
        ),
        tool_execution_plane_digest=str(
            manifest.get("toolExecutionPlaneDigest", "unsupported")
        ),
        sandbox_policy_digest=str(tool_plane.get("sandboxPolicyDigest", "unsupported")),
        provider_execution_digest=str(
            manifest.get("providerExecutionDigest", "legacy-unfrozen")
        ),
        provider_settings_closure_digest=str(
            manifest.get("providerSettingsClosureDigest", "legacy-unfrozen")
        ),
        provider_settings_closure_ref=str(
            manifest.get("providerSettingsClosureRef", "legacy-unfrozen")
        ),
        provider_settings_materializer_version=str(
            manifest.get("providerSettingsMaterializerVersion", "legacy-unfrozen")
        ),
    )


def _require_supported_schema(value: str) -> None:
    if value not in {
        EXPERIMENT_INVARIANT_SCHEMA_VERSION, LEGACY_PROVIDER_INVARIANT_SCHEMA_VERSION,
        LEGACY_TYPED_INVARIANT_SCHEMA_VERSION,
    }:
        raise UnsupportedInvariantSchema(f"unsupported experiment invariant schema: {value}")


def _differences(frozen: Any, current: Any, prefix: str = "") -> list[Mapping[str, Any]]:
    if isinstance(frozen, Mapping) and isinstance(current, Mapping):
        result = []
        for key in sorted(set(frozen) | set(current)):
            field = f"{prefix}.{key}" if prefix else str(key)
            if key not in frozen or key not in current:
                result.append({"field": field, "frozen": frozen.get(key), "current": current.get(key)})
            else:
                result.extend(_differences(frozen[key], current[key], field))
        return result
    if isinstance(frozen, list) and isinstance(current, list):
        result = []
        for index in range(max(len(frozen), len(current))):
            field = f"{prefix}[{index}]"
            if index >= len(frozen) or index >= len(current):
                result.append({
                    "field": field,
                    "frozen": frozen[index] if index < len(frozen) else None,
                    "current": current[index] if index < len(current) else None,
                })
            else:
                result.extend(_differences(frozen[index], current[index], field))
        return result
    return [] if frozen == current else [{"field": prefix, "frozen": frozen, "current": current}]
