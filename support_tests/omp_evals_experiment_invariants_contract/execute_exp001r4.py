from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path

from omp_evals.benchmark import (
    BenchmarkRunner, build_condition, load_suite, validate_experiment_plan_inputs,
)
from omp_evals.experiment_invariants import (
    build_experiment_invariant_snapshot, experiment_plan_from_mapping,
    invariant_snapshot_digest,
)
from omp_evals.runner import EvalRunner
from omp_evals.util import hash_file, utc_now


EXPERIMENT = "EXP-001R4-canonical-experiment-invariants-refreeze"
TASK = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
A3 = "ec791cd525396278fbd44927f3900b30282eb208fd53472628bd4756ef6064a9"
B3 = "664ce859d5eef9c9db82930a6546a28606c075aaa16c7ac0dc8961b57b590363"
SNAPSHOT = "18b71e798ef00e2d7324648cec04916a470b1b412e729cf4b53c2c6059ab7486"
FROZEN_HASHES = {
    "experiment-plan.json": "7864e85ff5de69fc9940e83d1c4bd8269e16e6fbcd44c8dc172d916161a69a4f",
    "invariant-snapshot.json": "d4db2fd8b2ad9ec63e5ae9695dfb7e50dccf35ad84518359ef9f3fcd8864d730",
    "manifest.json": "b1cc483837d532ddd2b31a06e28fad7cc23df02b3639e19bd97d5d3158794acb",
    "readiness.json": "1ce51244ade3343b047d9e669c6459bfae56473289e5af8a46ca08bdbdddf8a4",
    "canonical-match.json": "edaa22c12e2a3b16e1c71ad2076caaf00e7434c1e925618bba5da6dfa7c78f34",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    options = parser.parse_args()
    if os.environ.get("OMP_EVALS_REAL_PROVIDER") != "1":
        raise RuntimeError("real-provider opt-in is required")
    if not os.environ.get("DEEPSEEK_API_KEY"):
        raise RuntimeError("required credential DEEPSEEK_API_KEY is absent")

    root = options.root.resolve()
    experiment_root = root / "eval_experiments" / EXPERIMENT
    verify_hashes(experiment_root)
    suite, tasks = load_suite(
        root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
    )
    if len(tasks) != 1 or tasks[0].task_fingerprint != TASK:
        raise RuntimeError("frozen task fingerprint drift")
    conditions = tuple(build_condition(path, tasks[0], Path("/unused"), options.settings) for path in (
        root / "eval_conditions/exp-001r3-edit-model-contract-a3.json",
        root / "eval_conditions/exp-001r3-edit-model-contract-b3.json",
    ))
    if tuple(item.fingerprint for item in conditions) != (A3, B3):
        raise RuntimeError("frozen A3/B3 fingerprint drift")
    plan = experiment_plan_from_mapping(
        json.loads((experiment_root / "experiment-plan.json").read_text())
    )
    validate_experiment_plan_inputs(suite, tasks, conditions, plan)
    current = build_experiment_invariant_snapshot(tasks, conditions, paired=True)
    current_digest = invariant_snapshot_digest(current)
    if plan.invariant_snapshot_digest != SNAPSHOT or current_digest != SNAPSHOT:
        raise RuntimeError("canonical invariant snapshot drift")
    expected_order = [A3, B3, B3, A3, A3, B3]
    if [item.condition_fingerprint for item in plan.order] != expected_order:
        raise RuntimeError("frozen schedule drift")
    if len(plan.order) != 6 or plan.trials_per_task != 3 or plan.seed != 1004:
        raise RuntimeError("frozen trial count/seed drift")

    before = database_counts(options.eval_home / "evals.db")
    if before["experimentPlans"] or before["experimentSlots"] or before["experimentTrials"]:
        raise RuntimeError("EXP-001R4 already has execution records")
    write_json(experiment_root / "real-execution-preflight.json", {
        "schemaVersion": "exp-001r4-real-execution-preflight-v1",
        "experimentId": EXPERIMENT,
        "checkedAt": utc_now(),
        "taskFingerprint": TASK,
        "conditionFingerprints": [A3, B3],
        "invariantSchemaVersion": plan.invariant_schema_version,
        "frozenSnapshotDigest": SNAPSHOT,
        "executionSnapshotDigest": current_digest,
        "frozenPlanCanonicalMatch": "Pass",
        "credential": {"name": "DEEPSEEK_API_KEY", "present": True, "valuePersisted": False},
        "prerequisites": {
            "bwrapAvailable": Path("/usr/bin/bwrap").is_file(),
            "sdkAvailable": (options.sdk_root / "bin/cjc").is_file(),
            "A3RealTrialReadiness": "Ready",
            "B3RealTrialReadiness": "Ready",
        },
        "frozenArtifactHashes": FROZEN_HASHES,
        "databaseBefore": before,
        "plannedSlots": 6,
        "maximumAgentTrials": 6,
    })

    old_sdk = os.environ.get("CANGJIE_HOME")
    os.environ["CANGJIE_HOME"] = str(options.sdk_root.resolve())
    runner = EvalRunner(options.eval_home)
    try:
        BenchmarkRunner(runner).execute_plan(
            suite, tasks, conditions, plan, Path(conditions[0].agent_binary), options.settings,
        )
        rows = runner.database.experiment_trials(EXPERIMENT)
        result = {
            "experimentId": EXPERIMENT,
            "planned": 6,
            "executed": sum(row["trial_id"] is not None for row in rows),
            "slots": [{
                "ordinal": row["ordinal"],
                "conditionFingerprint": row["condition_fingerprint"],
                "trialId": row["trial_id"],
                "gradingRunId": row["grading_run_id"],
            } for row in rows],
        }
    finally:
        runner.close()
        if old_sdk is None:
            os.environ.pop("CANGJIE_HOME", None)
        else:
            os.environ["CANGJIE_HOME"] = old_sdk
    verify_hashes(experiment_root)
    print(json.dumps(result, separators=(",", ":")))
    return 0


def verify_hashes(root: Path) -> None:
    actual = {name: hash_file(root / name) for name in FROZEN_HASHES}
    if actual != FROZEN_HASHES:
        raise RuntimeError("EXP-001R4 frozen artifact drift")


def database_counts(path: Path) -> dict:
    connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
    try:
        return {
            "agentTrials": connection.execute("SELECT COUNT(*) FROM agent_trials").fetchone()[0],
            "candidateSnapshots": connection.execute("SELECT COUNT(*) FROM candidate_snapshots").fetchone()[0],
            "gradingRuns": connection.execute("SELECT COUNT(*) FROM grading_runs").fetchone()[0],
            "experimentPlans": connection.execute(
                "SELECT COUNT(*) FROM experiment_plans WHERE id=?", (EXPERIMENT,)
            ).fetchone()[0],
            "experimentSlots": connection.execute(
                "SELECT COUNT(*) FROM experiment_trials WHERE experiment_id=?", (EXPERIMENT,)
            ).fetchone()[0],
            "experimentTrials": connection.execute(
                "SELECT COUNT(*) FROM agent_trials WHERE json_extract(trial_json,'$.plan.experiment_id')=?",
                (EXPERIMENT,),
            ).fetchone()[0],
        }
    finally:
        connection.close()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
