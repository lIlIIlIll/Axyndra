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


EXPERIMENT = "EXP-001R6-provider-settings-closure-refreeze"
TASK = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
A6 = "60e48eb417d5aab46cfbf5ea02280464a8f1a835bc09dfde5781f49cfe4d3c6e"
B6 = "6162060225f333b1dc6358459c2899eaeb10ecb2e1ffcfb7b2bb067a0f7bcb93"
PROVIDER = "1221830a53f1058a07e335c2012b63f2b8b71aeb41e11386b52f107158fd6626"
SETTINGS = "885fc4654a7e722a4dd1cf54bc625b77d012f5da6d892851ba10242f2be1240b"
SNAPSHOT = "ff40d40d0237ed30b81e76dac790010d7ab16040b1a77dba96fcf9ce06fd965a"
FROZEN_HASHES = {
    "eval_conditions/exp-001r6-edit-model-contract-a6.json": "66e7ede6cbeb7cfbb017adcb05aa1dd04a0d8a48766a6bb6173c83b334cb51ac",
    "eval_conditions/exp-001r6-edit-model-contract-b6.json": "5c3d65db4c287bc16c08a0bd5ecf9fa50463273a6febb693803662d7b98c746e",
    "eval_experiments/EXP-001R5-frozen-provider-execution-spec/provider-execution-spec.json": "a32ba8378062d68e647659e0be704be7e86eb38428a6858083550985a70b7814",
    f"eval_experiments/{EXPERIMENT}/provider-settings-closure.json": "c5649b03ad2238239160f805e165636b5bc604253035fc2aa1d37da2077c5253",
    f"eval_experiments/{EXPERIMENT}/invariant-snapshot.json": "1082fb7dbb7ae3298804cd5f699ae9edbed5af5745f48bf824822f606c20db59",
    f"eval_experiments/{EXPERIMENT}/experiment-plan.json": "d90d1b01538582ef72d45c58dd1221b62178df48e870748f314dece6eb3e02c5",
    f"eval_experiments/{EXPERIMENT}/readiness.json": "0edde84703db704bdcdfbfd2e8832d4411ac82830676038ba795486675517dca",
    f"eval_experiments/{EXPERIMENT}/canonical-match.json": "66357103623ebf2f5390639fccf45a68daa888c4ec48bbeca72ed9d08645cfa9",
    f"eval_experiments/{EXPERIMENT}/security-verification.json": "76200c6d682e522a0daf73c7d32c459f817be92bdf684b5dfb4622b64e3ad9ca",
    f"eval_experiments/{EXPERIMENT}/manifest.json": "cb8775a868572d5548e78b1cef50e8508571175cd02d627346a296fe06127f8e",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    options = parser.parse_args()
    if os.environ.get("OMP_EVALS_REAL_PROVIDER") != "1":
        raise RuntimeError("real-provider opt-in is required")
    if not os.environ.get("DEEPSEEK_API_KEY"):
        raise RuntimeError("required credential DEEPSEEK_API_KEY is absent")

    root = options.root.resolve()
    experiment_root = root / "eval_experiments" / EXPERIMENT
    verify_hashes(root)
    suite, tasks = load_suite(
        root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
    )
    if len(tasks) != 1 or tasks[0].task_fingerprint != TASK:
        raise RuntimeError("frozen task fingerprint drift")
    conditions = tuple(build_condition(path, tasks[0], Path("/unused"), None) for path in (
        root / "eval_conditions/exp-001r6-edit-model-contract-a6.json",
        root / "eval_conditions/exp-001r6-edit-model-contract-b6.json",
    ))
    if tuple(item.fingerprint for item in conditions) != (A6, B6):
        raise RuntimeError("frozen A6/B6 fingerprint drift")
    if {item.provider_execution_digest for item in conditions} != {PROVIDER}:
        raise RuntimeError("ProviderExecutionDigest drift")
    if {item.provider_settings_closure_digest for item in conditions} != {SETTINGS}:
        raise RuntimeError("ProviderSettingsClosureDigest drift")

    plan = experiment_plan_from_mapping(
        json.loads((experiment_root / "experiment-plan.json").read_text())
    )
    validate_experiment_plan_inputs(suite, tasks, conditions, plan)
    current = build_experiment_invariant_snapshot(tasks, conditions, paired=True)
    current_digest = invariant_snapshot_digest(current)
    if plan.invariant_snapshot_digest != SNAPSHOT or current_digest != SNAPSHOT:
        raise RuntimeError("canonical invariant snapshot drift")
    expected_order = [A6, B6, B6, A6, A6, B6]
    if [item.condition_fingerprint for item in plan.order] != expected_order:
        raise RuntimeError("frozen schedule drift")
    if len(plan.order) != 6 or plan.trials_per_task != 3 or plan.seed != 1006:
        raise RuntimeError("frozen trial count/seed drift")

    before = database_counts(options.eval_home / "evals.db")
    if before["experimentPlans"] or before["experimentSlots"] or before["experimentTrials"]:
        raise RuntimeError("EXP-001R6 already has execution records")
    write_json(experiment_root / "real-execution-preflight.json", {
        "schemaVersion": "exp-001r6-real-execution-preflight-v1",
        "experimentId": EXPERIMENT,
        "checkedAt": utc_now(),
        "taskFingerprint": TASK,
        "conditionFingerprints": [A6, B6],
        "providerSpecSource": "frozen ProviderExecutionSpec",
        "providerSettingsSource": "frozen ProviderSettingsClosure CAS",
        "ambientProviderSemanticsUsed": False,
        "ambientCatalogUsed": False,
        "providerExecutionDigest": PROVIDER,
        "providerSettingsClosureDigest": SETTINGS,
        "credential": {"name": "DEEPSEEK_API_KEY", "present": True, "valuePersisted": False},
        "invariantSchemaVersion": plan.invariant_schema_version,
        "frozenSnapshotDigest": SNAPSHOT,
        "executionSnapshotDigest": current_digest,
        "frozenPlanCanonicalMatch": "Pass",
        "prerequisites": {
            "bwrapAvailable": Path("/usr/bin/bwrap").is_file(),
            "sdkAvailable": (options.sdk_root / "bin/cjc").is_file(),
            "A6RuntimeReadiness": "Ready",
            "A6ToolSandboxReadiness": "Ready",
            "A6ProviderSettingsCompatibility": "Ready",
            "A6RealTrialReadiness": "Ready",
            "B6RuntimeReadiness": "Ready",
            "B6ToolSandboxReadiness": "Ready",
            "B6ProviderSettingsCompatibility": "Ready",
            "B6RealTrialReadiness": "Ready",
            "executableExperimentReady": True,
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
            suite, tasks, conditions, plan, Path(conditions[0].agent_binary), None,
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
    verify_hashes(root)
    print(json.dumps(result, separators=(",", ":")))
    return 0


def verify_hashes(root: Path) -> None:
    actual = {name: hash_file(root / name) for name in FROZEN_HASHES}
    if actual != FROZEN_HASHES:
        differences = [name for name in FROZEN_HASHES if actual[name] != FROZEN_HASHES[name]]
        raise RuntimeError("EXP-001R6 frozen artifact drift: " + ", ".join(differences))


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
