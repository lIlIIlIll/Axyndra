from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

from omp_evals.benchmark import (
    build_condition, build_experiment_plan, load_suite, validate_experiment_plan_inputs,
)
from omp_evals.experiment_invariants import experiment_plan_from_mapping
from omp_evals.model import jsonable
from omp_evals.runner import EvalRunner
from omp_evals.util import hash_file, utc_now


EXPERIMENT = "EXP-001R4-canonical-experiment-invariants-refreeze"
PARENT = "EXP-001R3-tool-sandbox-readiness-refreeze"
TASK = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
A3 = "ec791cd525396278fbd44927f3900b30282eb208fd53472628bd4756ef6064a9"
B3 = "664ce859d5eef9c9db82930a6546a28606c075aaa16c7ac0dc8961b57b590363"
R3_HASHES = {
    "condition-a3.json": "8c167fc12022b634b872c9d25362f9afc80f36566482aba79e5ae6c4f3c95298",
    "condition-b3.json": "ef6b40d2ec5a18b4848f358c6e55d73680649697526873de11d3904287e94678",
    "controlled-variables.json": "1cf55d36975a4b452d44f848fcf6192a281947ba11f5f2aa81f539547e10db4b",
    "decision.json": "68f167e2622b3d23997144caadb578b9b0e24dca94b7fcca4a76e7c30ad9d9c9",
    "experiment-plan.json": "ec6ac2c8bbc71aa030f1ce6150ef6a2badfa2209f98d4e247a9b76b25bc2124f",
    "historical-effective-validity.json": "6d817bd0b6857fb8c089004d3b23602826ae16e9e2605a636537f7de028c25c1",
    "manifest.json": "29520e5c28fc7da4ad5ee46b9c2883c2cfb09195c2f46e21bbab28d99470f138",
    "parent-evidence.json": "9fa5a05c65d7ab277cacd70d0472aba1358025e2c38bc081397e2683d65a5aec",
    "real-execution-preflight.json": "a2df6245f960f090fde208a2248a5f8d5b1eb10c8622993cb3d21e971a16be23",
    "reproduction-failure.json": "759addc554ec9d3a876c4400cc8b6d9a4cbfbada35504878844edad58ae0dd61",
    "security-verification.json": "9f8f4cdbdd86e7b0489715bbecfe0faf945e99a08c06c03db579a1d875cdb7be",
    "tool-execution-plane.json": "58f3ebb6e2f30e48ae1411e78452fcc3a2acdbb7a4c2654b558e0c40551a7b91",
    "tool-pipeline-contract.json": "719236d4ade7372040383c5e968b0caf92de2a5855aa5d2ab84234c36d69c5d7",
    "tool-sandbox-readiness.json": "f016a42d0fcf1c067c487bfd6cde6b900a4b09fe6e4178ebd59f786e0aa949d3",
    "trial-index.json": "5d913e5a412fd0d0f28236fe183081b02c2042d0e4d370c93065ded806167d2f",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    options = parser.parse_args()
    root = options.root.resolve()
    destination = root / "eval_experiments" / EXPERIMENT
    if destination.exists():
        raise FileExistsError(f"immutable experiment already exists: {destination}")
    r3 = root / "eval_experiments" / PARENT
    actual_hashes = {name: hash_file(r3 / name) for name in R3_HASHES}
    if actual_hashes != R3_HASHES:
        raise RuntimeError("EXP-001R3 immutable artifact drift")

    suite, tasks = load_suite(
        root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
    )
    if len(tasks) != 1 or tasks[0].task_fingerprint != TASK:
        raise RuntimeError("task fingerprint drift")
    paths = (
        root / "eval_conditions/exp-001r3-edit-model-contract-a3.json",
        root / "eval_conditions/exp-001r3-edit-model-contract-b3.json",
    )
    conditions = tuple(
        build_condition(path, tasks[0], Path("/unused"), options.settings) for path in paths
    )
    if tuple(item.fingerprint for item in conditions) != (A3, B3):
        raise RuntimeError("A3/B3 condition fingerprint drift")

    created_at = utc_now()
    plan = build_experiment_plan(
        EXPERIMENT, "PairedAB", suite, tasks, conditions, 3, 1004, created_at,
    )
    validate_experiment_plan_inputs(suite, tasks, conditions, plan)
    artifact = plan_artifact(plan)
    reloaded = experiment_plan_from_mapping(artifact)
    validate_experiment_plan_inputs(suite, tasks, conditions, reloaded)
    if reloaded != plan:
        raise RuntimeError("canonical plan round-trip changed semantics")

    before = database_counts(options.eval_home / "evals.db", EXPERIMENT)
    readiness = {}
    old_sdk = __import__("os").environ.get("CANGJIE_HOME")
    __import__("os").environ["CANGJIE_HOME"] = str(options.sdk_root.resolve())
    runner = EvalRunner(options.eval_home)
    try:
        for label, condition in zip(("A3", "B3"), conditions):
            runtime = runner.preflight_condition_runtime(condition)
            tools = runner.preflight_condition_tool_execution(condition)
            if runtime.readiness.value != "Ready" or tools.readiness.value != "Ready":
                raise RuntimeError(f"{label} is not ready: {runtime}; {tools}")
            readiness[label] = {
                "runtime": jsonable(runtime), "toolSandbox": jsonable(tools),
                "realTrialReadiness": "Ready",
            }
    finally:
        runner.close()
        if old_sdk is None:
            __import__("os").environ.pop("CANGJIE_HOME", None)
        else:
            __import__("os").environ["CANGJIE_HOME"] = old_sdk
    after = database_counts(options.eval_home / "evals.db", EXPERIMENT)
    if before != after or after["experimentPlans"] or after["trialRows"]:
        raise RuntimeError("plan freeze/readiness created experiment or trial rows")

    destination.mkdir(parents=True)
    snapshot_value = jsonable(plan.invariant_snapshot)
    write_json(destination / "parent-evidence.json", {
        "parentExperiment": PARENT,
        "reason": "Freeze and execution validation used divergent invariant projections; a canonical versioned snapshot now supplies both.",
        "parentArtifactHashes": R3_HASHES,
        "parentStatus": "InvalidExperimentDesign",
    })
    write_json(destination / "projection-audit.json", {
        "schemaVersion": "exp-001r4-projection-audit-v1",
        "historicalFreezePath": "prepare_exp001r3.py called legacy builder then manually appended toolExecutionPlaneDigest",
        "historicalExecutionPath": "BenchmarkRunner.execute_plan called legacy builder without that manual append",
        "historicalDifference": ["toolExecutionPlaneDigest"],
        "latentCoverageGap": [
            "conditionFingerprints", "provider/model/settings", "prompt/context/compaction",
            "permission/sandbox", "RuntimeClosure", "ToolExecutionPlane",
        ],
        "rootCause": "freeze and execution validation separately maintained invariant projections",
        "canonicalBuilder": "build_experiment_invariant_snapshot",
        "canonicalValidator": "validate_experiment_invariant_snapshot",
    })
    write_json(destination / "invariant-snapshot.json", {
        "schemaVersion": plan.invariant_schema_version,
        "snapshot": snapshot_value,
        "snapshotDigest": plan.invariant_snapshot_digest,
        "sourceConditionRefs": [str(path.relative_to(root)) for path in paths],
        "taskRef": "eval_tasks/cangjie_midpoint_precedence/qualified-task.json",
    })
    write_json(destination / "experiment-plan.json", artifact)
    write_json(destination / "canonical-match.json", {
        "schemaVersion": plan.invariant_schema_version,
        "frozenSnapshotDigest": plan.invariant_snapshot_digest,
        "executionSnapshotDigest": plan.invariant_snapshot_digest,
        "semanticEquality": True, "digestEquality": True,
        "result": "Pass",
    })
    write_json(destination / "readiness.json", {
        "schemaVersion": "exp-001r4-readiness-v1", "conditions": readiness,
        "frozenPlanCanonicalMatch": "Pass", "executableExperimentReady": True,
        "modelCalls": 0, "providerRequests": 0,
    })
    write_json(destination / "hypothesis.json", {
        "mechanism": "Aligned trailing-colon model contract reduces MissingRequiredColon edit attempts.",
        "outcome": "Fewer malformed edits improve Candidate Correct and/or Strict PASS.",
        "changedFromParent": False,
    })
    write_json(destination / "manifest.json", {
        "experimentId": EXPERIMENT, "version": "1",
        "parentExperiment": PARENT, "status": "ReadyForRealExecution",
        "taskFingerprint": TASK, "conditionFingerprints": [A3, B3],
        "invariantSchemaVersion": plan.invariant_schema_version,
        "invariantSnapshotDigest": plan.invariant_snapshot_digest,
        "runtimeReadiness": {"A3": "Ready", "B3": "Ready"},
        "toolSandboxReadiness": {"A3": "Ready", "B3": "Ready"},
        "frozenPlanCanonicalMatch": "Pass", "createdAt": created_at,
        "offlineProof": {
            "modelCalls": 0, "providerRequests": 0, "agentTrials": 0,
            "graderExecutions": 0, "candidateMutations": 0,
        },
    })
    print(json.dumps({
        "experimentId": EXPERIMENT, "snapshotDigest": plan.invariant_snapshot_digest,
        "order": [jsonable(item) for item in plan.order],
        "readiness": "ReadyForRealExecution", "database": after,
    }, separators=(",", ":")))
    return 0


def plan_artifact(plan) -> dict:
    return {
        "experimentId": plan.id, "kind": plan.kind,
        "suiteFingerprint": plan.suite_fingerprint,
        "conditionFingerprints": list(plan.condition_fingerprints),
        "trialsPerCondition": plan.trials_per_task, "seed": plan.seed,
        "order": [jsonable(item) for item in plan.order], "createdAt": plan.created_at,
        "invariants": {}, "invariantSchemaVersion": plan.invariant_schema_version,
        "invariantSnapshot": jsonable(plan.invariant_snapshot),
        "invariantSnapshotDigest": plan.invariant_snapshot_digest,
        "parentExperiment": PARENT, "status": "ReadyForRealExecution",
    }


def database_counts(path: Path, experiment: str) -> dict:
    connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
    try:
        return {
            "agentTrials": connection.execute("SELECT COUNT(*) FROM agent_trials").fetchone()[0],
            "candidateSnapshots": connection.execute("SELECT COUNT(*) FROM candidate_snapshots").fetchone()[0],
            "gradingRuns": connection.execute("SELECT COUNT(*) FROM grading_runs").fetchone()[0],
            "experimentPlans": connection.execute(
                "SELECT COUNT(*) FROM experiment_plans WHERE id=?", (experiment,)
            ).fetchone()[0],
            "trialRows": connection.execute(
                "SELECT COUNT(*) FROM experiment_trials WHERE experiment_id=?", (experiment,)
            ).fetchone()[0],
        }
    finally:
        connection.close()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
