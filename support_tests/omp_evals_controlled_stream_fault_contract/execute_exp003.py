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


EXPERIMENT = "EXP-003-controlled-incomplete-stream-recovery"
PARENTS = (
    "EXP-002R-final-response-attempt-recovery",
    "EXP-002R2-runtime-closure-refreeze",
)
TASK = "e51c014cac5c54dfe5894478aeda6a8cc6ae04d4d53acb04d8e80dce51d735b7"
CONDITIONS = (
    "cc497bd9f90cf614b77abf083fe3d273d9a4763be981ec3745ecf7b94d06be81",
    "2374fba452268032e0c53d818cce0ff589c141864ed996552d15179510fc61f4",
)
SNAPSHOT = "0f218d1d106b232721f14249365b41a7bd8812f1fb940db6c84663e8986c9535"
BINARY = "9245057a542d6f6d10899e3b7e1de278b6c32e4b173e4917d1663577c6fa91b7"
RUNTIME = "1a7f7c46fbad06b04fde1eb8a6825ff9ce832bb9822588e8598a74b073dc985d"
COMPATIBILITY = "938fe111981e7b3ec7b5e2f3d7d9aae4b1de0cf80a8a6a79e41c104d44304745"
PROVIDER = "1221830a53f1058a07e335c2012b63f2b8b71aeb41e11386b52f107158fd6626"
SETTINGS = "885fc4654a7e722a4dd1cf54bc625b77d012f5da6d892851ba10242f2be1240b"
FAULT = "b1d96b63ff89752cd4ed46f56da3b6f6818a14fd6d84cea7ea557294859eef1e"
POLICIES = (
    "600bea645c4c5e3023e7932fa55a2304f3e3fa61f8a23c6d0f1112790a7d8725",
    "a7e876f037dbb453dfeefd5cb7c11aa7e2ceeec70908a1c273fd307f3e46c1b3",
)
FROZEN_FILES = (
    "condition-a.json", "condition-b.json", "controlled-variables.json", "decision.json",
    "design-decision.json", "endpoints.json", "experiment-plan.json", "fault-profile.json",
    "freeze-manifest.json", "invariant-snapshot.json", "manifest.json", "parent-evidence.json",
    "qualification.json", "recovery-contract-evidence.json",
    "recovery-contract-investigation.json", "runtime-closure.json", "runtime-readiness.json",
    "security.json", "task-ref.json", "task-selection.json",
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

    root, eval_home = options.root.resolve(), options.eval_home.resolve()
    destination = root / "eval_experiments" / EXPERIMENT
    frozen_before = frozen_hashes(root, destination)
    historical_before = historical_hashes(root)
    before = database_counts(eval_home / "evals.db")
    if before["exp003Trials"] or before["exp003Slots"] or before["exp003Plans"]:
        raise RuntimeError("EXP-003 already has persistent slot/Trial records; refusing duplicate execution")

    with tempfile.TemporaryDirectory(prefix="exp003-execution-suite-") as raw:
        suite, task, conditions, plan = load_frozen_inputs(root, Path(raw))
        if controlled_projection(conditions[0].manifest) != controlled_projection(conditions[1].manifest):
            raise RuntimeError("Control/Recovery contains a second independent variable")
        if arguments_without_policy(conditions[0].manifest["arguments"]) != \
                arguments_without_policy(conditions[1].manifest["arguments"]):
            raise RuntimeError("Control/Recovery CLI arguments contain a second independent variable")

        previous_home = os.environ.get("CANGJIE_HOME")
        previous_root = os.environ.get("CANGJIE_SDK_ROOT")
        os.environ["CANGJIE_HOME"] = str(options.sdk_root.resolve())
        os.environ["CANGJIE_SDK_ROOT"] = str(options.sdk_root.resolve())
        runner = EvalRunner(eval_home)
        try:
            gates = preflight(runner, conditions)
            write_json(destination / "real-execution-preflight.json", {
                "schemaVersion": "exp-003-real-execution-preflight-v1",
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
                "faultProfileDigest": FAULT,
                "conditionFingerprints": list(CONDITIONS),
                "policyDigests": list(POLICIES), "taskFingerprint": TASK,
                "snapshotDigest": SNAPSHOT, "plannedSlots": 10,
                "frozenOrder": [item.condition_fingerprint for item in plan.order],
                "gates": gates, "faultProfileCanonicalMatch": "Pass",
                "frozenPlanCanonicalMatch": "Pass", "executableExperimentReady": True,
                "databaseBefore": before,
                "providerRequests": 0, "realModelCalls": 0, "credentialReads": 0,
            })
            if options.preflight_only:
                print(json.dumps({
                    "credentialRotationGate": "Verified",
                    "frozenExperimentIntegrityGate": "Pass",
                    "controlledVariableProof": "Pass",
                    "faultProfileCanonicalMatch": "Pass",
                    "frozenPlanCanonicalMatch": "Pass",
                    "executableExperimentReady": True,
                    "database": before, "gates": gates,
                }, separators=(",", ":")))
                return 0
            persist_plan(runner, suite, task, conditions, plan)
            execute_slots(runner, task, conditions, plan)
        finally:
            runner.close()
            restore_env("CANGJIE_HOME", previous_home)
            restore_env("CANGJIE_SDK_ROOT", previous_root)

    if frozen_hashes(root, destination) != frozen_before:
        raise RuntimeError("frozen EXP-003 artifacts changed during execution")
    if historical_hashes(root) != historical_before:
        raise RuntimeError("historical EXP-002R/R2 artifacts changed during execution")
    after = database_counts(eval_home / "evals.db")
    print(json.dumps({
        "experimentId": EXPERIMENT, "planned": 10, "executed": after["exp003Trials"],
        "databaseBefore": before, "databaseAfter": after,
        "frozenIntegrity": "Pass", "historicalIntegrity": "Pass",
        "extraTrials": max(0, after["exp003Trials"] - 10),
    }, separators=(",", ":")))
    return 0


def load_frozen_inputs(root: Path, temporary: Path):
    destination = root / "eval_experiments" / EXPERIMENT
    task_path = root / "eval_tasks/cangjie_clamp_missing/qualified-task.json"
    task_value = json.loads(task_path.read_text())
    suite_path = temporary / "suite.json"
    write_json(suite_path, {
        "id": "exp-003-clamp", "version": "1", "kind": "Research",
        "metadata": {"experiment": "EXP-003", "task": "clamp"},
        "tasks": [{"id": task_value["id"], "version": task_value["version"],
                   "taskFingerprint": task_value["taskFingerprint"],
                   "qualifiedTask": str(task_path)}],
    })
    suite, qualified = load_suite(suite_path)
    if len(qualified) != 1 or qualified[0].task_fingerprint != TASK:
        raise RuntimeError("Clamp task fingerprint drift")
    paths = (
        root / "eval_conditions/exp-003-controlled-incomplete-stream-control.json",
        root / "eval_conditions/exp-003-controlled-incomplete-stream-recovery-v1.json",
    )
    conditions = tuple(build_condition(path, qualified[0], Path("/unused"), None) for path in paths)
    if tuple(item.fingerprint for item in conditions) != CONDITIONS:
        raise RuntimeError("EXP-003 condition fingerprint drift")
    plan = experiment_plan_from_mapping(json.loads((destination / "experiment-plan.json").read_text()))
    validate_experiment_plan_inputs(suite, qualified, conditions, plan)
    calculated = invariant_snapshot_digest(build_experiment_invariant_snapshot(
        qualified, conditions, paired=True
    ))
    if calculated != SNAPSHOT or plan.invariant_snapshot_digest != SNAPSHOT:
        raise RuntimeError("EXP-003 canonical invariant snapshot drift")
    manifests = [item.manifest for item in conditions]
    required_sets = {
        "agentBinaryDigest": {BINARY}, "runtimeClosureDigest": {RUNTIME},
        "providerExecutionDigest": {PROVIDER}, "providerSettingsClosureDigest": {SETTINGS},
        "modelStreamFaultProfileDigest": {FAULT},
    }
    for key, expected in required_sets.items():
        if {item[key] for item in manifests} != expected:
            raise RuntimeError(f"{key} drift")
    if {item.runtime_closure["executable_runtime_compatibility_digest"] for item in conditions} != {COMPATIBILITY}:
        raise RuntimeError("ExecutableRuntimeCompatibility drift")
    if tuple(item["modelStreamRecoveryPolicyDigest"] for item in manifests) != POLICIES:
        raise RuntimeError("recovery policy drift")
    if len(plan.order) != 10 or [item.ordinal for item in plan.order] != list(range(10)) or \
            any(item.trial_id is not None for item in plan.order):
        raise RuntimeError("frozen slot ownership/order drift")
    return suite, qualified[0], conditions, plan


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
            "providerRequests": 0, "realModelCalls": 0, "credentialReads": 0,
        }
        observed = tuple(values[key] for key in (
            "runtimeClosureValidation", "symbolVersionValidation",
            "modelPathDynamicLinkReadiness", "sandboxEquivalence",
            "runtimeReadiness", "toolSandboxReadiness", "providerSettingsCompatibility",
        ))
        if observed != ("Pass", "Pass", "Pass", "Pass", "Ready", "Ready", "Ready"):
            raise RuntimeError(f"{label} readiness failed: {values}")
        result[label] = values
    return result


def persist_plan(runner, suite, task, conditions, plan) -> None:
    if runner.database.has_experiment(plan.id):
        raise RuntimeError("EXP-003 plan already persisted; refusing duplicate slot creation")
    runner.database.save_suite(jsonable(suite))
    runner.database.save_task(jsonable(task))
    if runner.database.task_record(task.task_fingerprint)["lifecycle"] == TaskLifecycle.RETIRED.value:
        raise RuntimeError("Retired task cannot be executed")
    for condition in conditions:
        runner.database.save_condition(jsonable(condition))
    runner.database.save_experiment(jsonable(plan))
    for item in plan.order:
        runner.database.update_experiment_trial(
            plan.id, item.ordinal, item.task_fingerprint, item.condition_fingerprint,
            item.repetition_index, None, None,
        )


def execute_slots(runner, task, conditions, plan) -> None:
    for item in plan.order:
        rows = {int(row["ordinal"]): row for row in runner.database.experiment_trials(plan.id)}
        if rows[item.ordinal].get("trial_id") is not None:
            raise RuntimeError(f"slot already executed: {plan.id}/{item.ordinal}")
        condition = next(value for value in conditions if value.fingerprint == item.condition_fingerprint)
        trial_id = grading_id = None
        try:
            trial, candidate, grading, result = runner.run(
                task, Path(condition.agent_binary), settings_source=None,
                repetition_index=item.repetition_index, condition=condition,
                experiment_id=plan.id,
            )
            trial_id, grading_id = trial.id, grading.id
            manipulation = enforce_live_manipulation(runner, condition, candidate.id)
            progress = {
                "slot": item.ordinal, "condition": condition.id, "trialId": trial.id,
                "termination": trial.termination.value, "validity": trial.validity.value,
                "verdict": result.verdict.value, "manipulation": manipulation,
            }
        except InvalidTrialError as error:
            trial_id = error.trial_id
            progress = {
                "slot": item.ordinal, "condition": condition.id, "trialId": trial_id,
                "validity": error.validity.value, "infrastructureInvalid": True,
            }
        runner.database.update_experiment_trial(
            plan.id, item.ordinal, item.task_fingerprint, item.condition_fingerprint,
            item.repetition_index, trial_id, grading_id,
        )
        print(json.dumps(progress, separators=(",", ":")), flush=True)
        if progress.get("infrastructureInvalid") or progress.get("manipulation", {}).get("valid") is False:
            raise RuntimeError("shared execution/manipulation substrate invalid; stopping frozen experiment")


def enforce_live_manipulation(runner: EvalRunner, condition, candidate_id: str) -> dict:
    candidate = runner.database.load_candidate(candidate_id)
    frames = [json.loads(line) for line in runner.artifacts.get_bytes(
        candidate["trajectory_ref"]
    ).decode().splitlines() if line.strip()]
    events = [frame.get("event", {}) for frame in frames if isinstance(frame.get("event"), dict)]
    faults = [event for event in events if event.get("code") == "model.controlled_fault_injected"]
    timeout = [event for event in events if event.get("code") == "model.request_attempt_completed"
               and event.get("error_code") == "model.stream_idle_timeout"]
    abandoned = [event for event in events if event.get("code") == "model.attempt_abandoned"]
    retries = [event for event in events if event.get("code") == "model.auto_retry_start"]
    mode = condition.manifest["modelStreamRecoveryPolicy"]["mode"]
    valid_fault = len(faults) == 1 and faults[0].get("fault_profile_id") == \
        "IncompleteStreamFaultProfileV1" and faults[0].get("fault_attempt_ordinal") == 1 and len(timeout) == 1
    if not valid_fault:
        return {"valid": False, "reason": "frozen typed fault evidence missing or mismatched"}
    if mode == "Disabled" and (abandoned or retries):
        return {"valid": False, "reason": "Control scheduled recovery"}
    if mode == "RecoveryV1" and (len(abandoned) != 1 or len(retries) != 1):
        return {"valid": False, "reason": "RecoveryV1 did not schedule exactly one typed retry"}
    if any(event.get("tool_call_observed") is True for event in abandoned):
        return {"valid": False, "reason": "tool-bearing attempt retried"}
    return {"valid": True, "faults": len(faults), "typedTimeouts": len(timeout),
            "recoveryTriggers": len(retries), "abandonedAttempts": len(abandoned)}


def controlled_projection(value: dict) -> dict:
    omitted = {"id", "arguments", "modelStreamRecoveryPolicy", "modelStreamRecoveryPolicyDigest"}
    return {key: item for key, item in value.items() if key not in omitted}


def arguments_without_policy(arguments: list[str]) -> list[str]:
    result = list(arguments)
    index = result.index("--model-attempt-recovery")
    del result[index:index + 2]
    return result


def database_counts(path: Path) -> dict:
    connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
    try:
        tables = {
            "agentTrials": "agent_trials", "candidateSnapshots": "candidate_snapshots",
            "gradingRuns": "grading_runs", "experimentPlans": "experiment_plans",
            "experimentTrials": "experiment_trials",
        }
        result = {key: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                  for key, table in tables.items()}
        result.update({
            "exp003Plans": connection.execute(
                "SELECT COUNT(*) FROM experiment_plans WHERE id=?", (EXPERIMENT,)
            ).fetchone()[0],
            "exp003Slots": connection.execute(
                "SELECT COUNT(*) FROM experiment_trials WHERE experiment_id=?", (EXPERIMENT,)
            ).fetchone()[0],
            "exp003Trials": connection.execute(
                "SELECT COUNT(*) FROM agent_trials WHERE json_extract(trial_json,'$.plan.experiment_id')=?",
                (EXPERIMENT,),
            ).fetchone()[0],
        })
        return result
    finally:
        connection.close()


def frozen_hashes(root: Path, destination: Path) -> dict[str, str]:
    paths = [destination / name for name in FROZEN_FILES]
    paths.extend((
        root / "eval_conditions/exp-003-controlled-incomplete-stream-control.json",
        root / "eval_conditions/exp-003-controlled-incomplete-stream-recovery-v1.json",
        root / "eval_tasks/cangjie_clamp_missing/qualified-task.json",
    ))
    if any(not path.is_file() for path in paths):
        raise RuntimeError("frozen EXP-003 artifact missing")
    return {str(path.relative_to(root)): hash_file(path) for path in paths}


def historical_hashes(root: Path) -> dict[str, str]:
    paths = []
    for name in PARENTS:
        paths.extend(path for path in sorted((root / "eval_experiments" / name).rglob("*")) if path.is_file())
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
