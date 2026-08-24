from __future__ import annotations

import argparse
import json
import os
import sqlite3
import tempfile
from pathlib import Path

from omp_evals.benchmark import build_condition, load_suite, validate_experiment_plan_inputs
from omp_evals.experiment_invariants import (
    build_experiment_invariant_snapshot,
    experiment_plan_from_mapping,
    invariant_snapshot_digest,
)
from omp_evals.model import TaskLifecycle, jsonable
from omp_evals.runner import EvalRunner, InvalidTrialError
from omp_evals.util import canonical_json, hash_file, utc_now


EXPERIMENT = "EXP-002R2-runtime-closure-refreeze"
PARENT = "EXP-002R-final-response-attempt-recovery"
TASKS = {
    "midpoint": "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d",
    "clamp": "e51c014cac5c54dfe5894478aeda6a8cc6ae04d4d53acb04d8e80dce51d735b7",
}
CONDITIONS = (
    "26c8b8fba7227934a711af077865ccb4e3a70a8bb49176ae13528e312bf7cd1a",
    "d974898b8649986acaa1b34e734b01641ec6c0f7078b70343a54305bc8d385e1",
)
SNAPSHOTS = {
    "midpoint": "b4b9ebb3e6ed98b872f6c2b7542ace357446e7effdeae8f6068fa8286cc23f75",
    "clamp": "f6a8626895bf390ce3945d18d49bd7668af963110e2f7108509369c7a3b3c4fb",
}
PROVIDER = "1221830a53f1058a07e335c2012b63f2b8b71aeb41e11386b52f107158fd6626"
SETTINGS = "885fc4654a7e722a4dd1cf54bc625b77d012f5da6d892851ba10242f2be1240b"
BINARY = "c75feaf250e00b8b47c8fde1a28ddc6e10634638e27c8e0a7ce84ed4a48d5054"
RUNTIME = "45c78da963cb6dd9a36bbb5192c79f78f7a02af9d9feeaf2291233351212e3ec"
COMPATIBILITY = "6343211df172c64ffad334aff92e03d346cc071c399f6bcc5756a17dbbae4c55"
POLICIES = (
    "600bea645c4c5e3023e7932fa55a2304f3e3fa61f8a23c6d0f1112790a7d8725",
    "a7e876f037dbb453dfeefd5cb7c11aa7e2ceeec70908a1c273fd307f3e46c1b3",
)
FROZEN_R2_FILES = (
    "condition-a.json", "condition-b.json", "controlled-variables.json", "decision.json",
    "experiment-plan-clamp.json", "experiment-plan-midpoint.json", "experiment-plan.json",
    "freeze-manifest.json", "infrastructure-revision.json", "invariant-snapshot.json",
    "manifest.json", "model-path-dynamic-link-readiness.json", "parent-evidence.json",
    "runtime-closure.json", "runtime-link-root-cause.json", "runtime-readiness.json",
    "security-prerequisites.json", "task-clamp-ref.json", "task-midpoint-ref.json",
    "trial-validity-persistence.json",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--credential-rotation-acknowledged", action="store_true")
    parser.add_argument("--preflight-only", action="store_true")
    options = parser.parse_args()
    if not options.credential_rotation_acknowledged:
        raise RuntimeError("trusted non-secret credential rotation acknowledgement is required")
    if not options.preflight_only and os.environ.get("OMP_EVALS_REAL_PROVIDER") != "1":
        raise RuntimeError("real-provider opt-in is required")

    root = options.root.resolve()
    eval_home = options.eval_home.resolve()
    destination = root / "eval_experiments" / EXPERIMENT
    parent = root / "eval_experiments" / PARENT
    frozen_before = frozen_hashes(root, destination, parent)
    before = database_counts(eval_home / "evals.db")
    if before["r2Trials"] or before["r2Slots"] or before["r2Plans"] not in (0, 2):
        raise RuntimeError("EXP-002R2 already has slot/Trial records; refusing duplicate execution")

    with tempfile.TemporaryDirectory(prefix="exp002r2-execution-suites-") as raw:
        suites, tasks, conditions, plans = load_frozen_inputs(root, Path(raw))
        combined = json.loads((destination / "experiment-plan.json").read_text())
        verify_combined_order(combined, plans)
        if controlled_projection(conditions["midpoint"][0].manifest) != controlled_projection(
            conditions["midpoint"][1].manifest
        ):
            raise RuntimeError("Control/Recovery contains a second independent variable")

        old_home, old_root = os.environ.get("CANGJIE_HOME"), os.environ.get("CANGJIE_SDK_ROOT")
        os.environ["CANGJIE_HOME"] = str(options.sdk_root.resolve())
        os.environ["CANGJIE_SDK_ROOT"] = str(options.sdk_root.resolve())
        runner = EvalRunner(eval_home)
        try:
            gates = preflight(runner, conditions["midpoint"])
            write_json(destination / "real-execution-preflight.json", {
                "schemaVersion": "exp-002r2-real-execution-preflight-v1",
                "experimentId": EXPERIMENT,
                "checkedAt": utc_now(),
                "credentialRotationGate": {
                    "status": "Verified", "source": "user", "secret": False,
                    "previousCredentialRevoked": True, "replacementAcknowledged": True,
                    "previousCredentialNoLongerValid": True, "credentialInspected": False,
                },
                "frozenExperimentIntegrityGate": "Pass",
                "controlledVariableProof": "Pass",
                "onlyIndependentVariable": "ModelStreamRecoveryPolicy",
                "binaryDigest": BINARY, "runtimeClosureDigest": RUNTIME,
                "executableRuntimeCompatibilityDigest": COMPATIBILITY,
                "providerExecutionDigest": PROVIDER,
                "providerSettingsClosureDigest": SETTINGS,
                "conditionFingerprints": list(CONDITIONS), "policyDigests": list(POLICIES),
                "taskFingerprints": TASKS, "snapshotDigests": SNAPSHOTS,
                "plannedSlots": 12, "frozenExecutionWindowOrder": combined["frozenExecutionWindowOrder"],
                "gates": gates, "frozenPlanCanonicalMatch": "Pass",
                "executableExperimentReady": True, "databaseBefore": before,
                "providerRequests": 0, "modelCalls": 0, "credentialReads": 0,
            })
            if options.preflight_only:
                print(json.dumps({
                    "credentialRotationGate": "Verified", "frozenExperimentIntegrityGate": "Pass",
                    "controlledVariableProof": "Pass", "frozenPlanCanonicalMatch": "Pass",
                    "executableExperimentReady": True, "database": before, "gates": gates,
                }, separators=(",", ":")))
                return 0
            persist_frozen_plans(runner, suites, tasks, conditions, plans)
            execute_window(runner, combined, tasks, conditions, plans)
        finally:
            runner.close()
            restore_env("CANGJIE_HOME", old_home)
            restore_env("CANGJIE_SDK_ROOT", old_root)

    if frozen_hashes(root, destination, parent) != frozen_before:
        raise RuntimeError("frozen EXP-002R/EXP-002R2 artifacts changed during execution")
    after = database_counts(eval_home / "evals.db")
    print(json.dumps({
        "experimentId": EXPERIMENT, "planned": 12, "executed": after["r2Trials"],
        "databaseBefore": before, "databaseAfter": after,
        "frozenIntegrity": "Pass", "extraTrials": max(0, after["r2Trials"] - 12),
    }, separators=(",", ":")))
    return 0


def load_frozen_inputs(root: Path, temporary: Path):
    task_paths = {
        "midpoint": root / "eval_tasks/cangjie_midpoint_precedence/qualified-task.json",
        "clamp": root / "eval_tasks/cangjie_clamp_missing/qualified-task.json",
    }
    condition_paths = (
        root / "eval_conditions/exp-002r2-model-stream-recovery-control.json",
        root / "eval_conditions/exp-002r2-model-stream-recovery-v1.json",
    )
    suites, tasks, conditions, plans = {}, {}, {}, {}
    for label, task_path in task_paths.items():
        task_value = json.loads(task_path.read_text())
        suite_path = temporary / label / "suite.json"
        suite_path.parent.mkdir(parents=True)
        write_json(suite_path, {
            "id": f"exp-002r2-{label}", "version": "1", "kind": "Research",
            "metadata": {"experiment": "EXP-002R2", "task": label},
            "tasks": [{"id": task_value["id"], "version": task_value["version"],
                       "taskFingerprint": task_value["taskFingerprint"],
                       "qualifiedTask": str(task_path)}],
        })
        suite, qualified = load_suite(suite_path)
        if len(qualified) != 1 or qualified[0].task_fingerprint != TASKS[label]:
            raise RuntimeError(f"{label} task fingerprint drift")
        task_conditions = tuple(build_condition(path, qualified[0], Path("/unused"), None)
                                for path in condition_paths)
        if tuple(item.fingerprint for item in task_conditions) != CONDITIONS:
            raise RuntimeError(f"{label} condition fingerprint drift")
        plan = experiment_plan_from_mapping(json.loads(
            (root / "eval_experiments" / EXPERIMENT / f"experiment-plan-{label}.json").read_text()
        ))
        validate_experiment_plan_inputs(suite, qualified, task_conditions, plan)
        snapshot = invariant_snapshot_digest(build_experiment_invariant_snapshot(
            qualified, task_conditions, paired=True
        ))
        if snapshot != SNAPSHOTS[label] or plan.invariant_snapshot_digest != SNAPSHOTS[label]:
            raise RuntimeError(f"{label} canonical invariant snapshot drift")
        manifests = [item.manifest for item in task_conditions]
        if {item["providerExecutionDigest"] for item in manifests} != {PROVIDER}:
            raise RuntimeError("ProviderExecutionDigest drift")
        if {item["providerSettingsClosureDigest"] for item in manifests} != {SETTINGS}:
            raise RuntimeError("ProviderSettingsClosureDigest drift")
        if {item["agentBinaryDigest"] for item in manifests} != {BINARY}:
            raise RuntimeError("binary digest drift")
        if {item["runtimeClosureDigest"] for item in manifests} != {RUNTIME}:
            raise RuntimeError("RuntimeClosure drift")
        if {item.runtime_closure["executable_runtime_compatibility_digest"]
                for item in task_conditions} != {COMPATIBILITY}:
            raise RuntimeError("ExecutableRuntimeCompatibility drift")
        if tuple(item["modelStreamRecoveryPolicyDigest"] for item in manifests) != POLICIES:
            raise RuntimeError("recovery policy drift")
        suites[label], tasks[label], conditions[label], plans[label] = suite, qualified[0], task_conditions, plan
    return suites, tasks, conditions, plans


def preflight(runner: EvalRunner, conditions) -> dict:
    result = {}
    for label, condition in zip(("Control", "RecoveryV1"), conditions):
        linkage = runner.preflight_condition_model_path_dynamic_link(condition)
        runtime = runner.preflight_condition_runtime(condition)
        tools = runner.preflight_condition_tool_execution(condition)
        provider = runner.preflight_condition_provider_settings(condition)
        values = {
            "runtimeClosureValidation": "Pass" if linkage.static_dependency_closure else "Fail",
            "symbolVersionValidation": "Pass" if linkage.symbol_version_validation else "Fail",
            "modelPathDynamicLinkReadiness": linkage.readiness.value,
            "sandboxEquivalence": "Pass" if (
                linkage.sandbox_process_started and linkage.model_path_initialized
                and linkage.protocol_ready and linkage.clean_shutdown and not linkage.residual_process
            ) else "Fail",
            "runtimeReadiness": runtime.readiness.value,
            "toolSandboxReadiness": tools.readiness.value,
            "providerSettingsCompatibility": provider.readiness.value,
            "providerRequests": 0, "modelCalls": 0, "credentialReads": 0,
        }
        required = ("Pass", "Pass", "Pass", "Pass", "Ready", "Ready", "Ready")
        observed = tuple(values[key] for key in (
            "runtimeClosureValidation", "symbolVersionValidation", "modelPathDynamicLinkReadiness",
            "sandboxEquivalence", "runtimeReadiness", "toolSandboxReadiness",
            "providerSettingsCompatibility",
        ))
        if observed != required:
            raise RuntimeError(f"{label} readiness failed: {values}")
        result[label] = values
    return result


def persist_frozen_plans(runner, suites, tasks, conditions, plans) -> None:
    for label in ("midpoint", "clamp"):
        plan = plans[label]
        exists = runner.database.has_experiment(plan.id)
        if exists and runner.database.experiment(plan.id) != jsonable(plan):
            raise RuntimeError(f"persisted frozen plan drift: {plan.id}")
        runner.database.save_suite(jsonable(suites[label]))
        runner.database.save_task(jsonable(tasks[label]))
        if runner.database.task_record(tasks[label].task_fingerprint)["lifecycle"] == TaskLifecycle.RETIRED.value:
            raise RuntimeError(f"Retired task cannot be executed: {tasks[label].id}")
        for condition in conditions[label]:
            runner.database.save_condition(jsonable(condition))
        if not exists:
            runner.database.save_experiment(jsonable(plan))
        for scheduled in plan.order:
            runner.database.update_experiment_trial(
                plan.id, scheduled.ordinal, scheduled.task_fingerprint,
                scheduled.condition_fingerprint, scheduled.repetition_index, None, None,
            )


def execute_window(runner, combined, tasks, conditions, plans) -> None:
    for scheduled in combined["frozenExecutionWindowOrder"]:
        label, ordinal = scheduled["subplan"], int(scheduled["ordinal"])
        frozen = plans[label].order[ordinal]
        rows = {int(row["ordinal"]): row for row in runner.database.experiment_trials(plans[label].id)}
        if rows[ordinal].get("trial_id") is not None:
            raise RuntimeError(f"slot already executed: {plans[label].id}/{ordinal}")
        condition = next(item for item in conditions[label]
                         if item.fingerprint == frozen.condition_fingerprint)
        trial_id = grading_id = None
        try:
            trial, candidate, grading, result = runner.run(
                tasks[label], Path(condition.agent_binary), settings_source=None,
                repetition_index=frozen.repetition_index, condition=condition,
                experiment_id=plans[label].id,
            )
            trial_id, grading_id = trial.id, grading.id
            enforce_live_recovery_safety(runner, condition, candidate.id)
            progress = {
                "windowOrdinal": scheduled["windowOrdinal"], "task": label,
                "condition": condition.id, "trialId": trial.id,
                "termination": trial.termination.value, "validity": trial.validity.value,
                "verdict": result.verdict.value,
            }
        except InvalidTrialError as error:
            trial_id = error.trial_id
            progress = {
                "windowOrdinal": scheduled["windowOrdinal"], "task": label,
                "condition": condition.id, "trialId": trial_id,
                "validity": error.validity.value, "infrastructureInvalid": True,
            }
        runner.database.update_experiment_trial(
            plans[label].id, frozen.ordinal, frozen.task_fingerprint,
            frozen.condition_fingerprint, frozen.repetition_index, trial_id, grading_id,
        )
        print(json.dumps(progress, separators=(",", ":")), flush=True)
        if progress.get("validity") in ("InvalidEnvironmentInfrastructure", "InvalidAgentInfrastructure"):
            raise RuntimeError("shared execution substrate invalid; stopping frozen experiment")


def enforce_live_recovery_safety(runner: EvalRunner, condition, candidate_id: str) -> None:
    if condition.manifest["modelStreamRecoveryPolicy"]["mode"] != "RecoveryV1":
        return
    candidate = runner.database.load_candidate(candidate_id)
    frames = [json.loads(line) for line in runner.artifacts.get_bytes(
        candidate["trajectory_ref"]
    ).decode().splitlines() if line.strip()]
    events = [frame.get("event", {}) for frame in frames if isinstance(frame.get("event"), dict)]
    abandoned = [event for event in events if event.get("code") == "model.attempt_abandoned"]
    retries = [event for event in events if event.get("code") == "model.auto_retry_start"]
    if any(item.get("tool_call_observed") is True and item.get("retry_scheduled") is True
           for item in abandoned):
        raise RuntimeError("hard safety violation: tool-bearing attempt retried")
    if len(retries) > len(abandoned) or any(item.get("attempt", 0) > 2 for item in abandoned):
        raise RuntimeError("hard safety violation: recovery retry count overflow")


def verify_combined_order(combined, plans) -> None:
    order = combined.get("frozenExecutionWindowOrder", [])
    if len(order) != 12 or combined.get("futureRealTrials") != 12:
        raise RuntimeError("combined frozen slot count drift")
    if [item.get("windowOrdinal") for item in order] != list(range(12)):
        raise RuntimeError("combined frozen window ordinals drift")
    for item in order:
        scheduled = plans[item["subplan"]].order[int(item["ordinal"])]
        if jsonable(scheduled) != {key: item[key] for key in (
            "ordinal", "task_fingerprint", "condition_fingerprint", "repetition_index",
            "trial_id", "grading_run_id",
        )}:
            raise RuntimeError(f"combined/subplan mismatch at {item['windowOrdinal']}")


def controlled_projection(value: dict) -> dict:
    omitted = {"id", "arguments", "modelStreamRecoveryPolicy", "modelStreamRecoveryPolicyDigest"}
    return {key: item for key, item in value.items() if key not in omitted}


def database_counts(path: Path) -> dict:
    connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
    try:
        prefix = EXPERIMENT + "%"
        tables = {
            "agentTrials": "agent_trials", "candidateSnapshots": "candidate_snapshots",
            "gradingRuns": "grading_runs", "experimentPlans": "experiment_plans",
            "experimentTrials": "experiment_trials",
        }
        result = {key: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                  for key, table in tables.items()}
        result.update({
            "r2Plans": connection.execute("SELECT COUNT(*) FROM experiment_plans WHERE id LIKE ?", (prefix,)).fetchone()[0],
            "r2Slots": connection.execute("SELECT COUNT(*) FROM experiment_trials WHERE experiment_id LIKE ?", (prefix,)).fetchone()[0],
            "r2Trials": connection.execute(
                "SELECT COUNT(*) FROM agent_trials WHERE json_extract(trial_json,'$.plan.experiment_id') LIKE ?",
                (prefix,),
            ).fetchone()[0],
        })
        return result
    finally:
        connection.close()


def frozen_hashes(root: Path, destination: Path, parent: Path) -> dict[str, str]:
    paths = [destination / name for name in FROZEN_R2_FILES]
    paths.extend((
        root / "eval_conditions/exp-002r2-model-stream-recovery-control.json",
        root / "eval_conditions/exp-002r2-model-stream-recovery-v1.json",
        root / "eval_tasks/cangjie_midpoint_precedence/qualified-task.json",
        root / "eval_tasks/cangjie_clamp_missing/qualified-task.json",
    ))
    paths.extend(path for path in sorted(parent.rglob("*")) if path.is_file())
    if any(not path.is_file() for path in paths):
        raise RuntimeError("frozen artifact missing")
    return {str(path.relative_to(root)): hash_file(path) for path in paths}


def restore_env(name: str, value: str | None) -> None:
    if value is None:
        os.environ.pop(name, None)
    else:
        os.environ[name] = value


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(value) + b"\n")


if __name__ == "__main__":
    raise SystemExit(main())
