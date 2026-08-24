from __future__ import annotations

import json
import os
import random
import statistics
import subprocess
from dataclasses import replace
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence

from .model import (
    ComparisonResult, EvalSuite, EvalSuiteTask, ExperimentalCondition, ExperimentPlan,
    ExperimentTrial, FailureClassification, PilotResult, PilotSuggestion, QualifiedEvalTask,
    SuiteKind, SuiteResult, TaskLifecycle, jsonable,
)
from .experiment_invariants import (
    build_experiment_invariant_snapshot, invariant_snapshot_digest,
    legacy_experiment_invariants, validate_experiment_invariant_snapshot,
)
from .runner import EvalRunner, InvalidTrialError, _settings_fingerprint
from .metrics import derive_trajectory_metrics
from .storage import ArtifactStore
from .task import parse_qualified_task
from .util import hash_json, host_fingerprint, new_id, utc_now
from .util import canonical_json, sha256_bytes
from .provider_execution import (
    canonical_provider_execution_spec, provider_execution_digest,
)
from .provider_settings import (
    provider_settings_closure_digest, validate_provider_settings_closure,
)
from .model_attempt_recovery import (
    canonical_model_stream_recovery_policy, model_stream_recovery_policy_digest,
)
from .model_stream_fault import (
    canonical_model_stream_fault_profile, model_stream_fault_profile_digest,
)


def load_suite(path: Path) -> tuple[EvalSuite, tuple[QualifiedEvalTask, ...]]:
    source = path / "suite.json" if path.is_dir() else path
    value = json.loads(source.read_text())
    tasks: list[QualifiedEvalTask] = []
    refs: list[EvalSuiteTask] = []
    for item in value["tasks"]:
        qualified_path = (source.parent / item["qualifiedTask"]).resolve()
        task = parse_qualified_task(qualified_path)
        if item.get("id", task.id) != task.id or item.get("version", task.version) != task.version:
            raise ValueError("suite task identity/version does not match QualifiedEvalTask")
        if item.get("taskFingerprint", task.task_fingerprint) != task.task_fingerprint:
            raise ValueError(f"suite task fingerprint changed: {task.id}")
        if task.lifecycle in (TaskLifecycle.DRAFT, TaskLifecycle.RETIRED):
            raise ValueError(f"{task.lifecycle.value} task cannot enter a runnable suite: {task.id}")
        tasks.append(task)
        refs.append(EvalSuiteTask(task.id, task.version, task.task_fingerprint, str(qualified_path)))
    canonical = {
        "id": value["id"], "version": value["version"], "kind": value["kind"],
        "tasks": [jsonable(item) for item in refs], "metadata": value.get("metadata", {}),
    }
    suite = EvalSuite(
        id=value["id"], version=value["version"], kind=SuiteKind(value["kind"]),
        tasks=tuple(refs), metadata=value.get("metadata", {}),
        fingerprint=hash_json(canonical), root=str(source.parent.resolve()),
    )
    return suite, tuple(tasks)


def build_experiment_plan(
    experiment_id: str, kind: str, suite: EvalSuite,
    tasks: Sequence[QualifiedEvalTask], conditions: Sequence[ExperimentalCondition],
    trials: int, seed: int, created_at: Optional[str] = None,
) -> ExperimentPlan:
    if trials < 1:
        raise ValueError("trials must be positive")
    snapshot = build_experiment_invariant_snapshot(
        tasks, conditions, paired=(kind == "PairedAB")
    )
    return ExperimentPlan(
        id=experiment_id, kind=kind, suite_fingerprint=suite.fingerprint,
        condition_fingerprints=tuple(item.fingerprint for item in conditions),
        trials_per_task=trials, seed=seed,
        order=_experiment_order(tasks, conditions, trials, seed),
        created_at=created_at or utc_now(), invariants={},
        invariant_schema_version=snapshot.schema_version,
        invariant_snapshot=snapshot,
        invariant_snapshot_digest=invariant_snapshot_digest(snapshot),
    )


def validate_experiment_plan_inputs(
    suite: EvalSuite, tasks: Sequence[QualifiedEvalTask],
    conditions: Sequence[ExperimentalCondition], plan: ExperimentPlan,
) -> None:
    current_snapshot = build_experiment_invariant_snapshot(
        tasks, conditions, paired=(plan.kind == "PairedAB")
    )
    if plan.invariant_schema_version is None:
        expected_invariants = legacy_experiment_invariants(current_snapshot)
        if dict(plan.invariants) != expected_invariants:
            raise ValueError("frozen experiment invariants do not match current inputs")
    else:
        if plan.invariant_snapshot is None or plan.invariant_snapshot_digest is None:
            raise ValueError("current-schema experiment plan is missing its invariant snapshot")
        if plan.invariant_schema_version != plan.invariant_snapshot.schema_version:
            raise ValueError("experiment invariant schema version does not match snapshot")
        validate_experiment_invariant_snapshot(
            plan.invariant_snapshot, plan.invariant_snapshot_digest, current_snapshot,
        )
    expected_order = _experiment_order(tasks, conditions, plan.trials_per_task, plan.seed)
    if tuple(plan.order) != expected_order:
        raise ValueError("frozen experiment order does not match its seed and inputs")
    if tuple(plan.condition_fingerprints) != tuple(item.fingerprint for item in conditions):
        raise ValueError("frozen condition fingerprints do not match supplied conditions")
    if plan.suite_fingerprint != suite.fingerprint:
        raise ValueError("frozen suite fingerprint does not match supplied suite")


def build_condition(
    path: Optional[Path], task: QualifiedEvalTask, omp_binary: Path,
    settings_source: Optional[Path], environment_fingerprint: Optional[str] = None,
) -> ExperimentalCondition:
    value = {"id": "default", "version": "1", "agent": {}}
    if path:
        value = json.loads(path.read_text())
    agent = _merge_agent(task.agent, value.get("agent", {}))
    condition_binary = (
        (path.parent / str(value["agentBinary"])).resolve()
        if path and value.get("agentBinary") else omp_binary.resolve()
    )
    if not condition_binary.is_file():
        raise FileNotFoundError(f"condition agent binary not found: {condition_binary}")
    host = host_fingerprint(condition_binary)
    host.pop("capturedAt", None)
    environment_fp = environment_fingerprint or value.get("environmentClass") or hash_json(host)
    settings = _settings_fingerprint(settings_source)
    provider_spec = value.get("providerExecutionSpec")
    provider_digest = None
    provider_settings_closure = value.get("providerSettingsClosure")
    provider_settings_closure_ref = value.get("providerSettingsClosureRef")
    provider_settings_digest = None
    recovery_policy = value.get("modelStreamRecoveryPolicy")
    recovery_policy_digest = None
    fault_profile = value.get("modelStreamFaultProfile")
    fault_profile_digest = None
    if provider_spec is not None:
        provider_spec = canonical_provider_execution_spec(provider_spec)
        provider_digest = provider_execution_digest(provider_spec)
        if value.get("providerExecutionDigest") != provider_digest:
            raise ValueError("provider execution digest does not match canonical spec")
        frozen_profile = str(value.get("frozenProviderProfileId", "frozen-provider"))
        resolved_model = f"{frozen_profile}/{provider_spec['wireModel']}"
        resolved_provider = str(provider_spec["adapterIdentity"])
        if provider_spec["credentialSlot"] not in agent.get("inheritEnvironment", []):
            raise ValueError("provider credential slot is not declared by the Agent condition")
        agent = {**agent, "model": resolved_model}
    else:
        resolved_model = str(agent.get("model", "")) or _configured_model(settings_source)
        configured_provider = value.get("provider")
        resolved_provider = (
            resolved_model.split("/", 1)[0] if resolved_model and configured_provider == "settings-resolved"
            else configured_provider or (resolved_model.split("/", 1)[0] if resolved_model else "unsupported")
        )
    if provider_settings_closure is not None:
        if provider_digest is None:
            raise ValueError("provider settings closure requires a ProviderExecutionSpec")
        validate_provider_settings_closure(provider_settings_closure, provider_digest)
        provider_settings_digest = provider_settings_closure_digest(provider_settings_closure)
        expected_ref = f"sha256:{sha256_bytes(canonical_json(provider_settings_closure))}"
        if provider_settings_closure_ref != expected_ref:
            raise ValueError("provider settings closure ref does not match canonical manifest")
        if value.get("providerSettingsClosureDigest") != provider_settings_digest:
            raise ValueError("provider settings closure digest does not match manifest")
    if recovery_policy is not None:
        recovery_policy = canonical_model_stream_recovery_policy(recovery_policy)
        recovery_policy_digest = model_stream_recovery_policy_digest(recovery_policy)
        if value.get("modelStreamRecoveryPolicyDigest") != recovery_policy_digest:
            raise ValueError("model stream recovery policy digest does not match canonical policy")
    if fault_profile is not None:
        fault_profile = canonical_model_stream_fault_profile(fault_profile)
        fault_profile_digest = model_stream_fault_profile_digest(fault_profile)
        if value.get("modelStreamFaultProfileDigest") != fault_profile_digest:
            raise ValueError("model stream fault profile digest does not match canonical profile")
    manifest = {
        "schemaVersion": "omp-evals-condition-v1",
        "id": value["id"], "version": value.get("version", "1"),
        "baseProductState": value.get("baseProductState", "unsupported"),
        "harnessRevision": value.get("harnessRevision", _revision()),
        "agentBinaryDigest": host.get("ompBinarySha256"),
        "agentBinaryArtifactRef": value.get("agentBinaryArtifactRef"),
        "provider": resolved_provider,
        "model": resolved_model,
        "modelConfig": value.get("modelConfig", {}),
        "reasoningConfig": value.get("reasoningConfig", {}),
        "systemPromptDigest": value.get("systemPromptDigest", "unsupported"),
        "toolSet": agent.get("tools", []),
        "toolSetDigest": hash_json(agent.get("tools", [])),
        "toolDescriptionDigest": value.get("toolDescriptionDigest", "subsumed-by-agent-binary"),
        "editAciContract": value.get("editAciContract", "unspecified"),
        "parserDigest": value.get("parserDigest", "unsupported"),
        "applicationDigest": value.get("applicationDigest", "unsupported"),
        "toolSchemaDigest": value.get("toolSchemaDigest", "unsupported"),
        "editModelContractDigest": value.get("editModelContractDigest", "unsupported"),
        "generalPromptDigest": value.get("generalPromptDigest", "unsupported"),
        "nonEditToolSetDigest": value.get("nonEditToolSetDigest", "unsupported"),
        "budgetDigest": value.get("budgetDigest", "unsupported"),
        "toolExecutionPlane": value.get("toolExecutionPlane"),
        "toolExecutionPlaneDigest": value.get("toolExecutionPlaneDigest", "unsupported"),
        "skillSet": agent.get("skills", []),
        "skillSetDigest": hash_json(agent.get("skills", [])),
        "contextPolicyDigest": _optional_digest(value, "contextPolicy"),
        "compactionPolicyDigest": _optional_digest(value, "compactionPolicy"),
        "permissionProfileDigest": _optional_digest(value, "permissionProfile"),
        "settingsManifestDigest": (
            f"provider-execution:{provider_digest}"
            if provider_spec is not None else hash_json(settings)
        ),
        "providerExecutionDigest": provider_digest or "legacy-unfrozen",
        "providerSettingsClosureDigest": provider_settings_digest or "legacy-unfrozen",
        "providerSettingsClosureRef": provider_settings_closure_ref or "legacy-unfrozen",
        "providerSettingsMaterializerVersion": (
            provider_settings_closure.get("materializerVersion", "legacy-unfrozen")
            if provider_settings_closure is not None else "legacy-unfrozen"
        ),
        "frozenProviderProfileId": value.get("frozenProviderProfileId", "legacy-unfrozen"),
        "environmentFingerprint": environment_fp,
        "arguments": agent.get("arguments", []),
        "inheritedEnvironmentNames": sorted(agent.get("inheritEnvironment", [])),
        "environmentValueDigests": {
            str(name): hash_json(value) for name, value in agent.get("environment", {}).items()
            if not _credential_like(str(name))
        },
        "unsupported": [name for name in (
            "systemPromptDigest" if value.get("systemPromptDigest") is None else None,
        ) if name],
    }
    if recovery_policy is not None:
        manifest.update({
            "modelStreamRecoveryPolicy": recovery_policy,
            "modelStreamRecoveryPolicyDigest": recovery_policy_digest,
        })
    if fault_profile is not None:
        manifest.update({
            "modelStreamFaultProfile": fault_profile,
            "modelStreamFaultProfileDigest": fault_profile_digest,
        })
    if value.get("runtimeClosure") is not None:
        expected_ref = f"sha256:{sha256_bytes(canonical_json(value['runtimeClosure']))}"
        if value.get("runtimeClosureRef") != expected_ref:
            raise ValueError("runtime closure ref does not match canonical manifest")
        manifest.update({
            "runtimeClosureRef": value.get("runtimeClosureRef"),
        "runtimeClosureDigest": (
                value["runtimeClosure"].get("closure_digest")
                or value["runtimeClosure"].get("closureDigest")
            ),
            "runtimeSchemaVersion": value["runtimeClosure"].get("version"),
        })
    fingerprint = hash_json(manifest)
    return ExperimentalCondition(
        id=str(value["id"]), version=str(value.get("version", "1")),
        fingerprint=fingerprint, manifest=manifest, agent=agent,
        agent_binary=str(condition_binary), runtime_closure=value.get("runtimeClosure"),
        runtime_closure_ref=value.get("runtimeClosureRef"),
        provider_execution_spec=provider_spec,
        provider_execution_digest=provider_digest,
        provider_settings_closure=provider_settings_closure,
        provider_settings_closure_ref=provider_settings_closure_ref,
        provider_settings_closure_digest=provider_settings_digest,
    )


class BenchmarkRunner:
    def __init__(self, runner: EvalRunner):
        self.runner = runner

    def run_task(
        self, task: QualifiedEvalTask, condition: ExperimentalCondition, trials: int,
        omp_binary: Path, settings_source: Optional[Path], seed: int = 0,
        kind: str = "TaskReplication",
    ) -> tuple[ExperimentPlan, SuiteResult]:
        suite = EvalSuite(
            id=f"task-{task.id}", version=task.version, kind=task.benchmark_kind,
            tasks=(EvalSuiteTask(task.id, task.version, task.task_fingerprint, ""),),
            metadata={"ephemeral": True}, fingerprint=hash_json({"task": task.task_fingerprint}), root="",
        )
        plan = self._execute(suite, (task,), (condition,), trials, omp_binary, settings_source, seed, kind)
        return plan, aggregate_experiment(self.runner.database, plan.id)

    def run_suite(
        self, suite: EvalSuite, tasks: Sequence[QualifiedEvalTask],
        conditions: Sequence[ExperimentalCondition], trials: int,
        omp_binary: Path, settings_source: Optional[Path], seed: int = 0,
        kind: str = "SuiteRun",
    ) -> tuple[ExperimentPlan, SuiteResult]:
        plan = self._execute(suite, tasks, conditions, trials, omp_binary, settings_source, seed, kind)
        return plan, aggregate_experiment(self.runner.database, plan.id)

    def _execute(
        self, suite: EvalSuite, tasks: Sequence[QualifiedEvalTask],
        conditions: Sequence[ExperimentalCondition], trials: int, omp_binary: Path,
        settings_source: Optional[Path], seed: int, kind: str,
    ) -> ExperimentPlan:
        if trials < 1:
            raise ValueError("trials must be positive")
        if not conditions:
            raise ValueError("at least one ExperimentalCondition is required")
        experiment_id = new_id("experiment")
        plan = build_experiment_plan(
            experiment_id, kind, suite, tasks, conditions, trials, seed,
        )
        return self.execute_plan(suite, tasks, conditions, plan, omp_binary, settings_source)

    def execute_plan(
        self, suite: EvalSuite, tasks: Sequence[QualifiedEvalTask],
        conditions: Sequence[ExperimentalCondition], plan: ExperimentPlan,
        omp_binary: Path, settings_source: Optional[Path],
    ) -> ExperimentPlan:
        """Execute an already frozen plan without regenerating identity or order."""
        if plan.trials_per_task < 1:
            raise ValueError("trials must be positive")
        if not conditions:
            raise ValueError("at least one ExperimentalCondition is required")
        validate_experiment_plan_inputs(suite, tasks, conditions, plan)
        for condition in conditions:
            if condition.runtime_closure is not None:
                readiness = self.runner.preflight_condition_runtime(condition)
                if readiness.readiness.value != "Ready":
                    raise ValueError(
                        f"condition runtime is not ready: {condition.id}: "
                        + "; ".join(readiness.diagnostics)
                    )
                if condition.runtime_closure.get("version") == "omp-evals-runtime-closure-v2":
                    linkage = self.runner.preflight_condition_model_path_dynamic_link(condition)
                    if linkage.readiness.value != "Pass":
                        raise ValueError(
                            f"condition model path dynamic linkage is not ready: {condition.id}: "
                            + "; ".join(linkage.diagnostics)
                        )
                tool_readiness = self.runner.preflight_condition_tool_execution(condition)
                if tool_readiness.readiness.value != "Ready":
                    raise ValueError(
                        f"condition tool execution plane is not ready: {condition.id}: "
                        + "; ".join(tool_readiness.diagnostics)
                    )
                if condition.provider_settings_closure is not None:
                    provider_readiness = self.runner.preflight_condition_provider_settings(condition)
                    if provider_readiness.readiness.value != "Ready":
                        raise ValueError(
                            f"condition provider settings are not compatible: {condition.id}: "
                            + "; ".join(provider_readiness.diagnostics)
                        )
        if self.runner.database.has_experiment(plan.id):
            raise ValueError(f"experiment already exists: {plan.id}")
        self.runner.database.save_suite(jsonable(suite))
        for task in tasks:
            self.runner.database.save_task(jsonable(task))
            if self.runner.database.task_record(task.task_fingerprint)["lifecycle"] == TaskLifecycle.RETIRED.value:
                raise ValueError(f"Retired task cannot be executed: {task.id}")
        for condition in conditions:
            self.runner.database.save_condition(jsonable(condition))
        self.runner.database.save_experiment(jsonable(plan))
        by_task = {item.task_fingerprint: item for item in tasks}
        by_condition = {item.fingerprint: item for item in conditions}
        for scheduled in plan.order:
            trial_id = None
            grading_id = None
            try:
                trial, _, grading, _ = self.runner.run(
                    by_task[scheduled.task_fingerprint],
                    Path(by_condition[scheduled.condition_fingerprint].agent_binary or omp_binary),
                    settings_source=settings_source, repetition_index=scheduled.repetition_index,
                    condition=by_condition[scheduled.condition_fingerprint], experiment_id=plan.id,
                )
                trial_id, grading_id = trial.id, grading.id
            except InvalidTrialError as error:
                trial_id = error.trial_id
            self.runner.database.update_experiment_trial(
                plan.id, scheduled.ordinal, scheduled.task_fingerprint,
                scheduled.condition_fingerprint, scheduled.repetition_index, trial_id, grading_id,
            )
        return plan


def aggregate_experiment(database: Any, experiment_id: str) -> SuiteResult:
    plan = database.experiment(experiment_id)
    rows = database.experiment_trials(experiment_id)
    _refresh_metrics_from_canonical_trajectory(database, rows)
    rows = database.experiment_trials(experiment_id)
    version_sets: dict[str, Any] = {}
    enriched: list[dict[str, Any]] = []
    for row in rows:
        trial = row["trial_json"] or {}
        result = row["result_json"] or {}
        task = database.task_record(row["task_fingerprint"])
        if row.get("grading_run_id"):
            grading = database.load_grading_run(row["grading_run_id"])
            versions = {
                item["grader_id"]: {
                    "version": item["grader_version"], "outcome": item.get("outcome_requirement")
                } for item in grading["grader_results"]
            }
            value = {"bundleFingerprint": grading["grader_bundle_fingerprint"], "graders": versions}
            previous = version_sets.setdefault(row["task_fingerprint"], value)
            if previous != value:
                raise ValueError("grader versions cannot be silently mixed in one aggregate")
        classification = row.get("classification") or result.get("failure_classification")
        if row.get("effective_validity"):
            trial = {**trial, "storedValidity": trial.get("validity"),
                     "validity": row["effective_validity"]}
        enriched.append({**row, "trial": trial, "result": result, "task": task,
                         "classification": classification})
    by_task = _task_group(enriched)
    overall = _summary(enriched)
    overall.update({
        "totalTasks": len(by_task),
        "allValidTrialsPassedTasks": sum(
            value["validTrials"] > 0 and value["passedTrials"] == value["validTrials"]
            for value in by_task.values()
        ),
        "zeroPassTasks": sum(value["validTrials"] > 0 and value["passedTrials"] == 0
                             for value in by_task.values()),
    })
    suite_result = SuiteResult(
        id=new_id("suite-result"), experiment_id=experiment_id,
        suite_fingerprint=plan["suite_fingerprint"], grader_version_set=version_sets,
        overall=overall,
        by_task=by_task,
        by_category=_group(enriched, lambda row: row["task"]["category"]),
        by_capability=_multi_group(enriched, lambda row: row["task"].get("capabilities", [])),
        by_termination=_group(enriched, lambda row: row["trial"].get("termination", "NotStarted")),
        by_failure_classification=_group(
            [row for row in enriched if row["classification"]], lambda row: row["classification"]
        ),
        by_condition=_group(enriched, lambda row: row["condition_fingerprint"]), created_at=utc_now(),
    )
    database.save_benchmark_result(jsonable(suite_result))
    return suite_result


def _refresh_metrics_from_canonical_trajectory(database: Any, rows: Sequence[Mapping[str, Any]]) -> None:
    artifacts = ArtifactStore(Path(database.path).parent / "artifacts")
    for row in rows:
        trial = row.get("trial_json") or {}
        candidate_id = trial.get("candidate_snapshot_id")
        if not candidate_id or not row.get("trial_id"):
            continue
        candidate = database.load_candidate(candidate_id)
        frames = [
            json.loads(line) for line in artifacts.get_bytes(candidate["trajectory_ref"]).decode().splitlines()
            if line.strip()
        ]
        result = row.get("result_json") or {}
        metrics = derive_trajectory_metrics(frames, result.get("usage", {}))
        database.save_metrics(row["trial_id"], jsonable(metrics))


def compare_result(result: SuiteResult, condition_a: str, condition_b: str) -> ComparisonResult:
    conditions = result.by_condition
    if condition_a not in conditions or condition_b not in conditions:
        raise ValueError("comparison conditions are not present in SuiteResult")
    deltas: dict[str, Any] = {}
    for task, summary in result.by_task.items():
        a = summary["byCondition"].get(condition_a, {})
        b = summary["byCondition"].get(condition_b, {})
        a_rate, b_rate = a.get("passRate"), b.get("passRate")
        delta = None if a_rate is None or b_rate is None else b_rate - a_rate
        deltas[task] = {
            "conditionA": a, "conditionB": b, "passRateDeltaBMinusA": delta,
            "direction": "improved" if delta and delta > 0 else "regressed" if delta and delta < 0 else "tied",
        }
    return ComparisonResult(
        experiment_id=result.experiment_id, condition_a=condition_a, condition_b=condition_b,
        condition_results={condition_a: conditions[condition_a], condition_b: conditions[condition_b]},
        task_deltas=deltas,
    )


def pilot_result(task: QualifiedEvalTask, result: SuiteResult, requested: int) -> PilotResult:
    values = result.overall
    valid = int(values["validTrials"])
    passed = int(values["passedTrials"])
    if valid < requested:
        suggestion = PilotSuggestion.INSUFFICIENT_DATA
    elif valid and passed == valid:
        suggestion = PilotSuggestion.TOO_EASY
    elif valid and passed == 0:
        suggestion = PilotSuggestion.TOO_HARD
    else:
        suggestion = PilotSuggestion.USEFUL
    return PilotResult(
        task_fingerprint=task.task_fingerprint, experiment_id=result.experiment_id,
        requested_trials=requested, valid_trials=valid, invalid_trials=int(values["invalidTrials"]),
        passed_trials=passed, failed_trials=int(values["failedTrials"]),
        timeout_trials=int(result.by_termination.get("AgentTimedOut", {}).get("trials", 0)),
        median_usage=values["medianUsage"], median_duration_millis=values["medianDurationMillis"],
        failure_categories={key: int(value["trials"]) for key, value in result.by_failure_classification.items()},
        suggestion=suggestion,
    )


def transition_task(database: Any, task: QualifiedEvalTask, target: TaskLifecycle,
                    evidence: Mapping[str, Any]) -> None:
    allowed = {
        TaskLifecycle.QUALIFIED: {TaskLifecycle.PILOT, TaskLifecycle.ACTIVE, TaskLifecycle.RETIRED},
        TaskLifecycle.PILOT: {TaskLifecycle.ACTIVE, TaskLifecycle.RETIRED},
        TaskLifecycle.ACTIVE: {TaskLifecycle.RETIRED},
        TaskLifecycle.RETIRED: set(),
    }
    current = database.task_record(task.task_fingerprint)["lifecycle"]
    state = TaskLifecycle(current)
    if target not in allowed.get(state, set()):
        raise ValueError(f"invalid task lifecycle transition: {state.value} -> {target.value}")
    database.transition_task(task.task_fingerprint, state.value, target.value, evidence)


def _experiment_order(tasks: Sequence[QualifiedEvalTask], conditions: Sequence[ExperimentalCondition],
                      trials: int, seed: int) -> tuple[ExperimentTrial, ...]:
    shuffled = list(tasks)
    random.Random(seed).shuffle(shuffled)
    values: list[ExperimentTrial] = []
    for task_index, task in enumerate(shuffled):
        for repetition in range(trials):
            condition_order = list(conditions)
            if (task_index + repetition) % 2:
                condition_order.reverse()
            for condition in condition_order:
                values.append(ExperimentTrial(
                    ordinal=len(values), task_fingerprint=task.task_fingerprint,
                    condition_fingerprint=condition.fingerprint, repetition_index=repetition,
                ))
    return tuple(values)


def _experiment_invariants(
    tasks: Sequence[QualifiedEvalTask], conditions: Sequence[ExperimentalCondition], paired: bool
) -> Mapping[str, Any]:
    return legacy_experiment_invariants(
        build_experiment_invariant_snapshot(tasks, conditions, paired)
    )


def _summary(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    valid = [row for row in rows if row["trial"].get("validity") == "Valid"]
    passed = [row for row in valid if row["result"].get("verdict") == "Pass"]
    failed = [row for row in valid if row["result"].get("verdict") == "Fail"]
    durations = [row["result"].get("timing", {}).get("agentMillis") for row in valid]
    durations = [float(value) for value in durations if isinstance(value, (int, float))]
    metric_names = ("input_tokens", "cached_tokens", "output_tokens", "cost_micros", "model_calls", "tool_calls")
    medians = {}
    for name in metric_names:
        numbers = [
            row["metrics_json"].get(name) for row in valid
            if row.get("metrics_json") and isinstance(row["metrics_json"].get(name), (int, float))
        ]
        medians[name] = statistics.median(numbers) if numbers else None
    return {
        "trials": len(rows), "validTrials": len(valid), "invalidTrials": len(rows) - len(valid),
        "passedTrials": len(passed), "failedTrials": len(failed),
        "passRate": (len(passed) / len(valid)) if valid else None,
        "medianDurationMillis": statistics.median(durations) if durations else None,
        "medianUsage": medians,
    }


def _group(rows: Sequence[Mapping[str, Any]], key: Any) -> dict[str, Any]:
    grouped: dict[str, list[Mapping[str, Any]]] = {}
    for row in rows:
        grouped.setdefault(str(key(row)), []).append(row)
    return {name: _summary(values) for name, values in sorted(grouped.items())}


def _task_group(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, list[Mapping[str, Any]]] = {}
    for row in rows:
        grouped.setdefault(str(row["task"]["id"]), []).append(row)
    result: dict[str, Any] = {}
    for name, values in sorted(grouped.items()):
        summary = _summary(values)
        summary["byCondition"] = _group(values, lambda row: row["condition_fingerprint"])
        result[name] = summary
    return result


def _multi_group(rows: Sequence[Mapping[str, Any]], keys: Any) -> dict[str, Any]:
    grouped: dict[str, list[Mapping[str, Any]]] = {}
    for row in rows:
        for name in keys(row):
            grouped.setdefault(str(name), []).append(row)
    return {name: _summary(values) for name, values in sorted(grouped.items())}


def _merge_agent(base: Mapping[str, Any], override: Mapping[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in override.items():
        result[key] = value
    return result


def _optional_digest(value: Mapping[str, Any], key: str) -> str:
    return hash_json(value[key]) if key in value else "unsupported"


def _revision() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"], text=True, capture_output=True, check=False,
    )
    return completed.stdout.strip() if completed.returncode == 0 else "unknown"


def _credential_like(name: str) -> bool:
    upper = name.upper()
    return any(marker in upper for marker in (
        "API_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTHORIZATION",
    ))


def _configured_model(settings_source: Optional[Path]) -> str:
    if not settings_source:
        return ""
    config = settings_source / "config.yml"
    if not config.is_file():
        return ""
    for line in config.read_text().splitlines():
        if line.startswith("default_model:"):
            return line.split(":", 1)[1].strip().strip('"').strip("'")
    return ""
