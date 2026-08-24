from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from omp_evals.benchmark import BenchmarkRunner, build_condition, load_suite
from omp_evals.model import ExperimentPlan, ExperimentTrial
from omp_evals.runner import EvalRunner


EXPERIMENT_ID = "EXP-001R2-edit-aci-runtime-closure-refreeze"
TASK_FINGERPRINT = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
CONDITION_A = "406822b32906023f713d72bf36c403dd5355eda9ce6067041dcc1f841bc9ec9b"
CONDITION_B = "b86e1eb2a6c8db30d3f460cb5764cb5d59f67daae49145b25eb79f7f3e50d28e"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    options = parser.parse_args()
    if os.environ.get("OMP_EVALS_REAL_PROVIDER") != "1":
        raise RuntimeError("real-provider opt-in is required")
    if not os.environ.get("DEEPSEEK_API_KEY"):
        raise RuntimeError("required credential DEEPSEEK_API_KEY is absent")

    root = options.root.resolve()
    experiment_root = root / "eval_experiments/EXP-001R2-edit-aci-runtime-closure-refreeze"
    frozen = json.loads((experiment_root / "experiment-plan.json").read_text())
    if frozen["experimentId"] != EXPERIMENT_ID:
        raise RuntimeError("frozen experiment identity drift")
    suite, tasks = load_suite(root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json")
    if len(tasks) != 1 or tasks[0].task_fingerprint != TASK_FINGERPRINT:
        raise RuntimeError("frozen task fingerprint drift")
    condition_paths = (
        root / "eval_conditions/exp-001r2-edit-model-contract-a2-prime.json",
        root / "eval_conditions/exp-001r2-edit-model-contract-b2-prime.json",
    )
    conditions = tuple(
        build_condition(path, tasks[0], Path("/unused"), options.settings)
        for path in condition_paths
    )
    if tuple(item.fingerprint for item in conditions) != (CONDITION_A, CONDITION_B):
        raise RuntimeError("frozen condition fingerprint drift")
    order = tuple(ExperimentTrial(**item) for item in frozen["order"])
    plan = ExperimentPlan(
        id=frozen["experimentId"], kind=frozen["kind"], suite_fingerprint=suite.fingerprint,
        condition_fingerprints=tuple(frozen["conditionFingerprints"]),
        trials_per_task=frozen["trialsPerCondition"], seed=frozen["seed"], order=order,
        created_at=json.loads((experiment_root / "manifest.json").read_text())["createdAt"],
        invariants=frozen["invariants"],
    )
    runner = EvalRunner(options.eval_home)
    try:
        BenchmarkRunner(runner).execute_plan(
            suite, tasks, conditions, plan, Path(conditions[0].agent_binary), options.settings,
        )
        rows = runner.database.experiment_trials(plan.id)
        print(json.dumps({
            "experimentId": plan.id,
            "planned": len(plan.order),
            "executed": sum(row["trial_id"] is not None for row in rows),
            "slots": [{
                "ordinal": row["ordinal"], "conditionFingerprint": row["condition_fingerprint"],
                "trialId": row["trial_id"], "gradingRunId": row["grading_run_id"],
            } for row in rows],
        }, separators=(",", ":")))
    finally:
        runner.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
