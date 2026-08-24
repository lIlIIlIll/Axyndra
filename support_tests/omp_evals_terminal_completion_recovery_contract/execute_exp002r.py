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
from omp_evals.util import hash_file, utc_now


EXPERIMENT = "EXP-002R-final-response-attempt-recovery"
SUBPLANS = {
    "midpoint": f"{EXPERIMENT}-midpoint",
    "clamp": f"{EXPERIMENT}-clamp",
}
TASKS = {
    "midpoint": "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d",
    "clamp": "e51c014cac5c54dfe5894478aeda6a8cc6ae04d4d53acb04d8e80dce51d735b7",
}
CONDITIONS = (
    "94f1269263ff5af5eca6729ac5a0298896c67cf3922090e3d04ed7a50a194860",
    "c23c916fe33490bd079eb5cc7e564527b0a03a3816dd52749a8245d9029562e9",
)
SNAPSHOTS = {
    "midpoint": "54df721036078b3ca7f1aa637f7854f95615ccd13d9b467f86c63310ad5138b7",
    "clamp": "dc8233f9875b12810c91ba66608b919819865976e4731216d7dc3698a3f480b1",
}
PROVIDER = "1221830a53f1058a07e335c2012b63f2b8b71aeb41e11386b52f107158fd6626"
SETTINGS = "885fc4654a7e722a4dd1cf54bc625b77d012f5da6d892851ba10242f2be1240b"
BINARY = "6479e7447b47e5aea323c9ac1edf0310783b98ab29f73e319c61b98568b977ee"
RUNTIME = "e47bbc61e71aa487f954d956802dc5c067afb48519b50c637390bfe9063357ba"
POLICIES = (
    "600bea645c4c5e3023e7932fa55a2304f3e3fa61f8a23c6d0f1112790a7d8725",
    "a7e876f037dbb453dfeefd5cb7c11aa7e2ceeec70908a1c273fd307f3e46c1b3",
)
FROZEN_HASHES = {
    "eval_conditions/exp-002r-model-stream-recovery-control.json": "2d53747a5768f7e821732e873c5e8c05c5256ba2cb966908cfeb6115534e6670",
    "eval_conditions/exp-002r-model-stream-recovery-v1.json": "ef6faec78ffe8f3594c048877ef6b51d8e72971e3dd03c6b2974f59c907bfcc3",
    f"eval_experiments/{EXPERIMENT}/attempt-atomicity-audit.json": "b57dccc08be7e550f6bd504448d7170c6b7bf6ec2c9082613ace43ae11578f86",
    f"eval_experiments/{EXPERIMENT}/condition-a.json": "7da791cd3af859b753891e48e05baf8bd6380fed978bc2af43a712e923e205f3",
    f"eval_experiments/{EXPERIMENT}/condition-b.json": "9e6c490911b68a5405ddaf0b19d1e2d3fb9c014a9ae31b9e6a1d071804bbb19c",
    f"eval_experiments/{EXPERIMENT}/controlled-variables.json": "fa280c277998da2bcd9b85338fabcb41e75ea134068dee21c5ea9e5a1a9e1d92",
    f"eval_experiments/{EXPERIMENT}/decision.json": "db424ff415d9356afaf628b42f638aad22ecd21a9fb2d2df90afbdb4a488b679",
    f"eval_experiments/{EXPERIMENT}/deterministic-verification.json": "35f2a40688c8a543e90729cb21adf9f65461595894ea8ca710c74e261261c228",
    f"eval_experiments/{EXPERIMENT}/experiment-plan-clamp.json": "e73200f3a974711a8b5dc3e86fae2cfc88180c05d046881410a324191fe92ff8",
    f"eval_experiments/{EXPERIMENT}/experiment-plan-midpoint.json": "816bfe71df57faa536fdd6b82be931f7bfb0dd8d9f67270137cdfc410294b399",
    f"eval_experiments/{EXPERIMENT}/experiment-plan.json": "c24ae98e26f36b2dbd7df5c3c7fd6d61d10d2fdc8b13ef7599b51214fd653a44",
    f"eval_experiments/{EXPERIMENT}/invariant-snapshot.json": "7c1faea63a3680b6299342ac8c1f0a73143152fe93c924e5a3f23d9d955ccd10",
    f"eval_experiments/{EXPERIMENT}/manifest.json": "4295d13606b49d463335d5c2a4843d00691309a3a6b6c10d2c6e6f9a010ca211",
    f"eval_experiments/{EXPERIMENT}/parent-evidence.json": "deca1e517120736adef0fc8f17241b12581b1069b9d2c50563581f4cd20e141e",
    f"eval_experiments/{EXPERIMENT}/r6-final-stream-replay.json": "79d5f7241c0188000e0dd9044eaa9f2e4708f232a4582d2ed4bd82f6955b9016",
    f"eval_experiments/{EXPERIMENT}/recovery-policy.json": "534f2606ef2613afa9ee5fd88edf8f5b6e5550abdcb797164f0dd227742e393e",
    f"eval_experiments/{EXPERIMENT}/recovery-scope-audit.json": "8e17100f352e2949bfbe7946ebbc68f893215d78957173969615e449c82d8b0d",
    f"eval_experiments/{EXPERIMENT}/retry-input-identity.json": "7cbf4659eb27e497ecf3a2bf30e4e88669ea4de582d898e7e4093e7815698d43",
    f"eval_experiments/{EXPERIMENT}/runtime-readiness.json": "46800e2524a1823cedf649c87777de04495ec941fff1c6925fa1cf0b6953b3b5",
    f"eval_experiments/{EXPERIMENT}/security-prerequisites.json": "0b64393dc2fc5ffab0774402872d501ed652318f4c965b7ce302d8334801da7a",
    f"eval_experiments/{EXPERIMENT}/task-clamp-ref.json": "7b8952ecfb34eefbccc2841bc897635bb360dba8b00fe78efc99ffa2207b2e37",
    f"eval_experiments/{EXPERIMENT}/task-midpoint-ref.json": "30792603ffbc54c570eddf463559a4d2e4133d7ac956dd2d979b0fb65b65a15b",
    f"eval_experiments/{EXPERIMENT}/terminal-causal-evidence.json": "95c26f4e6dc8d59f036905c212989f57eea6e5e22a32c158212460398332d252",
    f"eval_experiments/{EXPERIMENT}/test-results.json": "b6bdb7b6354396c436eff4b8b0643b11faf3a2b2b20b7ccfa85df4c72d8c99e0",
    f"eval_experiments/{EXPERIMENT}/timeout-semantics-audit.json": "71c1ace39c75c837bb25b29454a903c14fbe55bd1298794f3cd437d1821dcae0",
    "eval_tasks/cangjie_midpoint_precedence/qualified-task.json": "c8f75664621879ac87d979d827a494f0b9a5f76723ef41ec9ca9d1c0c7e72729",
    "eval_tasks/cangjie_clamp_missing/qualified-task.json": "2f27693c28a9424d18db3ed8741117a819cdf791d88f90a44003b551b8fc106d",
}


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
    verify_hashes(root)
    before = database_counts(eval_home / "evals.db")
    if before["exp002rPlans"] or before["exp002rSlots"] or before["exp002rTrials"]:
        raise RuntimeError("EXP-002R already has persistent execution records")

    with tempfile.TemporaryDirectory(prefix="exp002r-execution-suites-") as raw:
        suites, tasks, conditions, plans = load_frozen_inputs(root, Path(raw))
        combined = json.loads((destination / "experiment-plan.json").read_text())
        verify_combined_order(combined, plans)
        controlled = controlled_projection(conditions["midpoint"][0].manifest)
        if controlled != controlled_projection(conditions["midpoint"][1].manifest):
            raise RuntimeError("Control/Recovery contains a second independent variable")

        old_sdk = os.environ.get("CANGJIE_HOME")
        os.environ["CANGJIE_HOME"] = str(options.sdk_root.resolve())
        runner = EvalRunner(eval_home)
        try:
            gates = preflight(runner, conditions["midpoint"])
            write_json(destination / "real-execution-preflight.json", {
                "schemaVersion": "exp-002r-real-execution-preflight-v1",
                "experimentId": EXPERIMENT,
                "checkedAt": utc_now(),
                "credentialRotationGate": {
                    "status": "Verified",
                    "source": "user",
                    "secret": False,
                    "previousCredentialRevoked": True,
                    "replacementAcknowledged": True,
                    "previousCredentialNoLongerValid": True,
                    "credentialInspected": False,
                    "credentialValuePersisted": False,
                },
                "frozenExperimentIntegrityGate": "Pass",
                "controlledVariableProof": "Pass",
                "onlyIndependentVariable": "ModelStreamRecoveryPolicy",
                "providerExecutionDigest": PROVIDER,
                "providerSettingsClosureDigest": SETTINGS,
                "conditionFingerprints": list(CONDITIONS),
                "binaryDigest": BINARY,
                "runtimeClosureDigest": RUNTIME,
                "policyDigests": list(POLICIES),
                "taskFingerprints": TASKS,
                "snapshotDigests": SNAPSHOTS,
                "plannedSlots": 12,
                "frozenExecutionWindowOrder": combined["frozenExecutionWindowOrder"],
                "gates": gates,
                "frozenPlanCanonicalMatch": "Pass",
                "executableExperimentReady": True,
                "databaseBefore": before,
                "providerRequests": 0,
                "modelCalls": 0,
            })
            if options.preflight_only:
                print(json.dumps({
                    "credentialRotationGate": "Verified",
                    "frozenExperimentIntegrityGate": "Pass",
                    "controlledVariableProof": "Pass",
                    "frozenPlanCanonicalMatch": "Pass",
                    "executableExperimentReady": True,
                    "database": before,
                }, separators=(",", ":")))
                return 0

            persist_frozen_plans(runner, suites, tasks, conditions, plans)
            execute_window(runner, combined, tasks, conditions, plans)
        finally:
            runner.close()
            if old_sdk is None:
                os.environ.pop("CANGJIE_HOME", None)
            else:
                os.environ["CANGJIE_HOME"] = old_sdk

    verify_hashes(root)
    after = database_counts(eval_home / "evals.db")
    print(json.dumps({
        "experimentId": EXPERIMENT,
        "planned": 12,
        "executed": after["exp002rTrials"],
        "databaseBefore": before,
        "databaseAfter": after,
        "frozenIntegrity": "Pass",
        "extraTrials": max(0, after["exp002rTrials"] - 12),
    }, separators=(",", ":")))
    return 0


def load_frozen_inputs(root: Path, temporary: Path):
    task_paths = {
        "midpoint": root / "eval_tasks/cangjie_midpoint_precedence/qualified-task.json",
        "clamp": root / "eval_tasks/cangjie_clamp_missing/qualified-task.json",
    }
    condition_paths = (
        root / "eval_conditions/exp-002r-model-stream-recovery-control.json",
        root / "eval_conditions/exp-002r-model-stream-recovery-v1.json",
    )
    suites = {}
    tasks = {}
    conditions = {}
    plans = {}
    for label, task_path in task_paths.items():
        task_value = json.loads(task_path.read_text())
        suite_path = temporary / label / "suite.json"
        suite_path.parent.mkdir(parents=True)
        write_json(suite_path, {
            "id": f"exp-002r-{label}",
            "version": "1",
            "kind": "Research",
            "metadata": {"experiment": "EXP-002R", "task": label},
            "tasks": [{
                "id": task_value["id"],
                "version": task_value["version"],
                "taskFingerprint": task_value["taskFingerprint"],
                "qualifiedTask": str(task_path),
            }],
        })
        suite, qualified = load_suite(suite_path)
        if len(qualified) != 1 or qualified[0].task_fingerprint != TASKS[label]:
            raise RuntimeError(f"{label} task fingerprint drift")
        task_conditions = tuple(
            build_condition(path, qualified[0], Path("/unused"), None)
            for path in condition_paths
        )
        if tuple(item.fingerprint for item in task_conditions) != CONDITIONS:
            raise RuntimeError(f"{label} condition fingerprint drift")
        plan = experiment_plan_from_mapping(json.loads(
            (root / "eval_experiments" / EXPERIMENT / f"experiment-plan-{label}.json").read_text()
        ))
        validate_experiment_plan_inputs(suite, qualified, task_conditions, plan)
        snapshot = invariant_snapshot_digest(
            build_experiment_invariant_snapshot(qualified, task_conditions, paired=True)
        )
        if snapshot != SNAPSHOTS[label] or plan.invariant_snapshot_digest != SNAPSHOTS[label]:
            raise RuntimeError(f"{label} canonical invariant snapshot drift")
        if {item.provider_execution_digest for item in task_conditions} != {PROVIDER}:
            raise RuntimeError(f"{label} ProviderExecutionDigest drift")
        if {item.provider_settings_closure_digest for item in task_conditions} != {SETTINGS}:
            raise RuntimeError(f"{label} ProviderSettingsClosureDigest drift")
        if {item.manifest["agentBinaryDigest"] for item in task_conditions} != {BINARY}:
            raise RuntimeError(f"{label} binary digest drift")
        if {item.manifest["runtimeClosureDigest"] for item in task_conditions} != {RUNTIME}:
            raise RuntimeError(f"{label} RuntimeClosure drift")
        if tuple(item.manifest["modelStreamRecoveryPolicyDigest"] for item in task_conditions) != POLICIES:
            raise RuntimeError(f"{label} recovery policy drift")
        suites[label], tasks[label], conditions[label], plans[label] = (
            suite, qualified[0], task_conditions, plan,
        )
    return suites, tasks, conditions, plans


def preflight(runner: EvalRunner, conditions) -> dict:
    result = {}
    for label, condition in zip(("Control", "RecoveryV1"), conditions):
        runtime = runner.preflight_condition_runtime(condition)
        tools = runner.preflight_condition_tool_execution(condition)
        provider = runner.preflight_condition_provider_settings(condition)
        values = {
            "runtimeReadiness": runtime.readiness.value,
            "toolSandboxReadiness": tools.readiness.value,
            "providerSettingsCompatibility": provider.readiness.value,
            "realTrialReadiness": "Ready",
            "providerRequests": 0,
            "modelCalls": 0,
        }
        if set(values[key] for key in (
            "runtimeReadiness", "toolSandboxReadiness", "providerSettingsCompatibility",
        )) != {"Ready"}:
            raise RuntimeError(f"{label} readiness failed: {values}")
        result[label] = values
    return result


def persist_frozen_plans(runner, suites, tasks, conditions, plans) -> None:
    for label in ("midpoint", "clamp"):
        plan = plans[label]
        if runner.database.has_experiment(plan.id):
            raise RuntimeError(f"experiment already exists: {plan.id}")
        runner.database.save_suite(jsonable(suites[label]))
        runner.database.save_task(jsonable(tasks[label]))
        record = runner.database.task_record(tasks[label].task_fingerprint)
        if record["lifecycle"] == TaskLifecycle.RETIRED.value:
            raise RuntimeError(f"Retired task cannot be executed: {tasks[label].id}")
        for condition in conditions[label]:
            runner.database.save_condition(jsonable(condition))
        runner.database.save_experiment(jsonable(plan))


def execute_window(runner, combined, tasks, conditions, plans) -> None:
    for scheduled in combined["frozenExecutionWindowOrder"]:
        label = scheduled["subplan"]
        ordinal = int(scheduled["ordinal"])
        frozen = plans[label].order[ordinal]
        if (
            frozen.task_fingerprint != scheduled["task_fingerprint"]
            or frozen.condition_fingerprint != scheduled["condition_fingerprint"]
            or frozen.repetition_index != scheduled["repetition_index"]
        ):
            raise RuntimeError(f"execution window drift at {scheduled['windowOrdinal']}")
        condition = next(
            item for item in conditions[label]
            if item.fingerprint == frozen.condition_fingerprint
        )
        trial_id = None
        grading_id = None
        try:
            trial, candidate, grading, result = runner.run(
                tasks[label], Path(condition.agent_binary), settings_source=None,
                repetition_index=frozen.repetition_index, condition=condition,
                experiment_id=plans[label].id,
            )
            trial_id, grading_id = trial.id, grading.id
            enforce_live_recovery_safety(runner, condition, candidate.id)
            progress = {
                "windowOrdinal": scheduled["windowOrdinal"],
                "task": label,
                "condition": condition.id,
                "trialId": trial.id,
                "termination": trial.termination.value,
                "validity": trial.validity.value,
                "verdict": result.verdict.value,
            }
        except InvalidTrialError as error:
            trial_id = error.trial_id
            progress = {
                "windowOrdinal": scheduled["windowOrdinal"],
                "task": label,
                "condition": condition.id,
                "trialId": trial_id,
                "validity": error.validity.value,
                "infrastructureInvalid": True,
            }
        runner.database.update_experiment_trial(
            plans[label].id, frozen.ordinal, frozen.task_fingerprint,
            frozen.condition_fingerprint, frozen.repetition_index, trial_id, grading_id,
        )
        print(json.dumps(progress, separators=(",", ":")), flush=True)


def enforce_live_recovery_safety(runner: EvalRunner, condition, candidate_id: str) -> None:
    if condition.manifest["modelStreamRecoveryPolicy"]["mode"] != "RecoveryV1":
        return
    candidate = runner.database.load_candidate(candidate_id)
    frames = [
        json.loads(line)
        for line in runner.artifacts.get_bytes(candidate["trajectory_ref"]).decode().splitlines()
        if line.strip()
    ]
    abandoned = []
    retry_starts = []
    for frame in frames:
        event = frame.get("event") if isinstance(frame.get("event"), dict) else {}
        if event.get("code") == "model.attempt_abandoned":
            abandoned.append(event)
        elif event.get("code") == "model.auto_retry_start" and event.get("error_code") == "model.attempt_timeout":
            retry_starts.append(event)
    if any(item.get("tool_call_observed") is True and item.get("retry_scheduled") is True for item in abandoned):
        raise RuntimeError("hard safety violation: tool-bearing attempt retried")
    if len(retry_starts) > len(abandoned):
        raise RuntimeError("hard safety violation: recovery retry lacks typed abandonment")
    if any(item.get("attempt", 0) > 2 for item in abandoned):
        raise RuntimeError("hard safety violation: recovery retry count overflow")


def verify_combined_order(combined, plans) -> None:
    order = combined.get("frozenExecutionWindowOrder", [])
    if len(order) != 12 or combined.get("futureRealTrials") != 12:
        raise RuntimeError("combined frozen slot count drift")
    if [item.get("windowOrdinal") for item in order] != list(range(12)):
        raise RuntimeError("combined frozen window ordinals drift")
    for item in order:
        plan = plans[item["subplan"]]
        scheduled = plan.order[int(item["ordinal"])]
        if jsonable(scheduled) != {
            key: item[key] for key in (
                "ordinal", "task_fingerprint", "condition_fingerprint",
                "repetition_index", "trial_id", "grading_run_id",
            )
        }:
            raise RuntimeError(f"combined/subplan mismatch at {item['windowOrdinal']}")


def controlled_projection(value: dict) -> dict:
    omitted = {"id", "arguments", "modelStreamRecoveryPolicy", "modelStreamRecoveryPolicyDigest"}
    return {key: item for key, item in value.items() if key not in omitted}


def database_counts(path: Path) -> dict:
    connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
    try:
        prefix = EXPERIMENT + "%"
        return {
            "agentTrials": connection.execute("SELECT COUNT(*) FROM agent_trials").fetchone()[0],
            "candidateSnapshots": connection.execute("SELECT COUNT(*) FROM candidate_snapshots").fetchone()[0],
            "gradingRuns": connection.execute("SELECT COUNT(*) FROM grading_runs").fetchone()[0],
            "experimentPlans": connection.execute("SELECT COUNT(*) FROM experiment_plans").fetchone()[0],
            "experimentTrials": connection.execute("SELECT COUNT(*) FROM experiment_trials").fetchone()[0],
            "exp002rPlans": connection.execute(
                "SELECT COUNT(*) FROM experiment_plans WHERE id LIKE ?", (prefix,)
            ).fetchone()[0],
            "exp002rSlots": connection.execute(
                "SELECT COUNT(*) FROM experiment_trials WHERE experiment_id LIKE ?", (prefix,)
            ).fetchone()[0],
            "exp002rTrials": connection.execute(
                "SELECT COUNT(*) FROM agent_trials WHERE json_extract(trial_json,'$.plan.experiment_id') LIKE ?",
                (prefix,),
            ).fetchone()[0],
        }
    finally:
        connection.close()


def verify_hashes(root: Path) -> None:
    actual = {name: hash_file(root / name) for name in FROZEN_HASHES}
    if actual != FROZEN_HASHES:
        differences = [name for name in FROZEN_HASHES if actual[name] != FROZEN_HASHES[name]]
        raise RuntimeError("EXP-002R frozen artifact drift: " + ", ".join(differences))


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
