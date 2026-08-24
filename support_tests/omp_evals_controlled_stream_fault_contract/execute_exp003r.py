from __future__ import annotations

import json
import tempfile
from pathlib import Path

from omp_evals.benchmark import build_condition, load_suite, validate_experiment_plan_inputs
from omp_evals.experiment_invariants import (
    build_experiment_invariant_snapshot,
    experiment_plan_from_mapping,
    invariant_snapshot_digest,
)
from omp_evals.util import hash_file

from support_tests.omp_evals_controlled_stream_fault_contract import execute_exp003 as base


ROOT = Path(__file__).resolve().parents[2]
EXPERIMENT = "EXP-003R-controlled-incomplete-stream-recovery-replication"
DESTINATION = ROOT / "eval_experiments" / EXPERIMENT
TASK = "e51c014cac5c54dfe5894478aeda6a8cc6ae04d4d53acb04d8e80dce51d735b7"
CONDITIONS = (
    "7d9203644ca1150ac02464b9ca0c1e748bbc702ab571855aa1dcf3f26331e49d",
    "44207e9dbc5111148c61a9815d25d5266e5df44effb58988f825b8b25a8f2d95",
)
SNAPSHOT = "09117948e960ff0de81b4a3422bcbb5b6a44d5e7d42a627eacd42ce2968b7fd5"
BINARY = "e6209d3769aa7031233ba80908fe5ff031ae1b5024b6631fb8a35626a7d529fb"
RUNTIME = "f6bf41700f98abf8faba8696f682021a5173405f1484da517c05c23f8737e9ed"
COMPATIBILITY = "ecec81ebde1d6d3045cda24f141e2682b3892ec7e765a234da9ccf17b6881976"
PROVIDER = "1221830a53f1058a07e335c2012b63f2b8b71aeb41e11386b52f107158fd6626"
SETTINGS = "885fc4654a7e722a4dd1cf54bc625b77d012f5da6d892851ba10242f2be1240b"
FAULT = "b1d96b63ff89752cd4ed46f56da3b6f6818a14fd6d84cea7ea557294859eef1e"
POLICIES = (
    "600bea645c4c5e3023e7932fa55a2304f3e3fa61f8a23c6d0f1112790a7d8725",
    "a7e876f037dbb453dfeefd5cb7c11aa7e2ceeec70908a1c273fd307f3e46c1b3",
)
PARENTS = (
    "EXP-002R-final-response-attempt-recovery",
    "EXP-002R2-runtime-closure-refreeze",
    "EXP-003-controlled-incomplete-stream-recovery",
)


def load_frozen_inputs(root: Path, temporary: Path):
    task_path = root / "eval_tasks/cangjie_clamp_missing/qualified-task.json"
    task_value = json.loads(task_path.read_text())
    suite_path = temporary / "suite.json"
    base.write_json(suite_path, {
        "id": "exp-003r-clamp", "version": "1", "kind": "Research",
        "metadata": {"experiment": "EXP-003R", "task": "clamp"},
        "tasks": [{"id": task_value["id"], "version": task_value["version"],
                   "taskFingerprint": task_value["taskFingerprint"],
                   "qualifiedTask": str(task_path)}],
    })
    suite, qualified = load_suite(suite_path)
    if len(qualified) != 1 or qualified[0].task_fingerprint != TASK:
        raise RuntimeError("Clamp task fingerprint drift")
    paths = (
        root / "eval_conditions/exp-003r-controlled-incomplete-stream-control.json",
        root / "eval_conditions/exp-003r-controlled-incomplete-stream-recovery-v1.json",
    )
    conditions = tuple(build_condition(path, qualified[0], Path("/unused"), None) for path in paths)
    if tuple(item.fingerprint for item in conditions) != CONDITIONS:
        raise RuntimeError("EXP-003R condition fingerprint drift")
    plan = experiment_plan_from_mapping(json.loads((DESTINATION / "experiment-plan.json").read_text()))
    validate_experiment_plan_inputs(suite, qualified, conditions, plan)
    calculated = invariant_snapshot_digest(build_experiment_invariant_snapshot(
        qualified, conditions, paired=True
    ))
    if calculated != SNAPSHOT or plan.invariant_snapshot_digest != SNAPSHOT:
        raise RuntimeError("EXP-003R invariant snapshot drift")
    manifests = [item.manifest for item in conditions]
    required = {
        "agentBinaryDigest": BINARY,
        "runtimeClosureDigest": RUNTIME,
        "providerExecutionDigest": PROVIDER,
        "providerSettingsClosureDigest": SETTINGS,
        "modelStreamFaultProfileDigest": FAULT,
    }
    for key, expected in required.items():
        if {item[key] for item in manifests} != {expected}:
            raise RuntimeError(f"{key} drift")
    if {item.runtime_closure["executable_runtime_compatibility_digest"] for item in conditions} != {COMPATIBILITY}:
        raise RuntimeError("ExecutableRuntimeCompatibility drift")
    if tuple(item["modelStreamRecoveryPolicyDigest"] for item in manifests) != POLICIES:
        raise RuntimeError("Recovery policy drift")
    if len(plan.order) != 10 or [item.ordinal for item in plan.order] != list(range(10)) or \
            any(item.trial_id is not None for item in plan.order):
        raise RuntimeError("Frozen slot ownership/order drift")
    return suite, qualified[0], conditions, plan


def frozen_hashes(root: Path, destination: Path) -> dict[str, str]:
    verification = json.loads((destination / "frozen-integrity-verification.json").read_text())
    values = {
        str((destination / name).relative_to(root)): hash_file(destination / name)
        for name in verification["frozenFiles"]
    }
    values[str((destination / "frozen-integrity-verification.json").relative_to(root))] = \
        hash_file(destination / "frozen-integrity-verification.json")
    for path in (
        root / "eval_conditions/exp-003r-controlled-incomplete-stream-control.json",
        root / "eval_conditions/exp-003r-controlled-incomplete-stream-recovery-v1.json",
        root / "eval_tasks/cangjie_clamp_missing/qualified-task.json",
    ):
        values[str(path.relative_to(root))] = hash_file(path)
    expected = verification["frozenFiles"]
    if any(values[str((destination / name).relative_to(root))] != digest
           for name, digest in expected.items()):
        raise RuntimeError("EXP-003R frozen hash mismatch")
    return values


def main() -> int:
    base.EXPERIMENT = EXPERIMENT
    base.PARENTS = PARENTS
    base.TASK = TASK
    base.CONDITIONS = CONDITIONS
    base.SNAPSHOT = SNAPSHOT
    base.BINARY = BINARY
    base.RUNTIME = RUNTIME
    base.COMPATIBILITY = COMPATIBILITY
    base.PROVIDER = PROVIDER
    base.SETTINGS = SETTINGS
    base.FAULT = FAULT
    base.POLICIES = POLICIES
    base.load_frozen_inputs = load_frozen_inputs
    base.frozen_hashes = frozen_hashes
    return base.main()


if __name__ == "__main__":
    raise SystemExit(main())
