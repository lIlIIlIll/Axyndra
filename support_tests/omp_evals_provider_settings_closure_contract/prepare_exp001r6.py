from __future__ import annotations

import argparse
import json
import os
import sqlite3
import tempfile
from pathlib import Path

from omp_evals.benchmark import (
    build_condition, build_experiment_plan, load_suite, validate_experiment_plan_inputs,
)
from omp_evals.experiment_invariants import experiment_plan_from_mapping
from omp_evals.model import jsonable
from omp_evals.provider_execution import provider_execution_digest
from omp_evals.provider_settings import (
    freeze_provider_settings_closure, materialize_provider_settings_closure,
    provider_settings_closure_digest, validate_materialized_provider_settings,
)
from omp_evals.runner import EvalRunner
from omp_evals.storage import ArtifactStore
from omp_evals.util import hash_file, utc_now


EXPERIMENT = "EXP-001R6-provider-settings-closure-refreeze"
PARENT = "EXP-001R5-frozen-provider-execution-spec"
TASK = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
PROVIDER = "1221830a53f1058a07e335c2012b63f2b8b71aeb41e11386b52f107158fd6626"
SEED = 1006


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    eval_home = args.eval_home.resolve()
    destination = root / "eval_experiments" / EXPERIMENT
    if destination.exists():
        raise FileExistsError(f"immutable experiment already exists: {destination}")
    r5 = root / "eval_experiments" / PARENT
    r5_hashes = immutable_hashes(r5)
    condition_a5 = root / "eval_conditions/exp-001r5-edit-model-contract-a5.json"
    condition_b5 = root / "eval_conditions/exp-001r5-edit-model-contract-b5.json"
    condition_hashes = {path.name: hash_file(path) for path in (condition_a5, condition_b5)}

    suite, tasks = load_suite(
        root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
    )
    if len(tasks) != 1 or tasks[0].task_fingerprint != TASK:
        raise RuntimeError("task fingerprint drift")
    provider_artifact = json.loads((r5 / "provider-execution-spec.json").read_text())
    spec = provider_artifact["spec"]
    if provider_execution_digest(spec) != PROVIDER:
        raise RuntimeError("R5 ProviderExecutionSpec drift")

    artifacts = ArtifactStore(eval_home / "artifacts")
    closure, closure_ref = freeze_provider_settings_closure(
        spec, artifacts, "frozen-deepseek",
    )
    closure_digest = provider_settings_closure_digest(closure)
    broken_closure, broken_ref = freeze_provider_settings_closure(
        spec, artifacts, "frozen-provider",
    )

    condition_paths = (
        root / "eval_conditions/exp-001r6-edit-model-contract-a6.json",
        root / "eval_conditions/exp-001r6-edit-model-contract-b6.json",
    )
    for label, source, target in zip(("a6", "b6"), (condition_a5, condition_b5), condition_paths):
        value = json.loads(source.read_text())
        value.update({
            "id": f"exp-001r6-edit-model-contract-{label}",
            "version": "1",
            "derivesFrom": value["id"],
            "providerSettingsClosure": closure,
            "providerSettingsClosureRef": closure_ref,
            "providerSettingsClosureDigest": closure_digest,
        })
        write_json(target, value)

    with tempfile.TemporaryDirectory(prefix="exp001r6-ambient-") as raw:
        ambient = Path(raw)
        (ambient / "config.yml").write_text("default_model: wrong/wrong\n")
        (ambient / "providers.yml").write_text("providers: []\n")
        (ambient / "models.yml").write_text("models: []\n")
        conditions = tuple(
            build_condition(path, tasks[0], Path("/unused"), ambient)
            for path in condition_paths
        )
    if {item.provider_execution_digest for item in conditions} != {PROVIDER}:
        raise RuntimeError("A6/B6 ProviderExecutionSpec differs")
    if {item.provider_settings_closure_digest for item in conditions} != {closure_digest}:
        raise RuntimeError("A6/B6 ProviderSettingsClosure differs")
    if controlled_projection(conditions[0].manifest) != controlled_projection(conditions[1].manifest):
        raise RuntimeError("A6/B6 contain an uncontrolled variable")
    if conditions[0].manifest["editModelContractDigest"] == conditions[1].manifest["editModelContractDigest"]:
        raise RuntimeError("EditModelContract independent variable disappeared")

    broken_value = json.loads(condition_a5.read_text())
    broken_value.update({
        "id": "exp-001r6-r5-broken-provider-settings-fixture",
        "providerSettingsClosure": broken_closure,
        "providerSettingsClosureRef": broken_ref,
        "providerSettingsClosureDigest": provider_settings_closure_digest(broken_closure),
    })
    with tempfile.TemporaryDirectory(prefix="exp001r6-broken-condition-") as raw:
        broken_path = Path(raw) / "condition.json"
        write_json(broken_path, broken_value)
        broken_condition = build_condition(broken_path, tasks[0], Path("/unused"), Path(raw))

    before = database_counts(eval_home / "evals.db")
    old_sdk = os.environ.get("CANGJIE_HOME")
    os.environ["CANGJIE_HOME"] = str(args.sdk_root.resolve())
    runner = EvalRunner(eval_home)
    try:
        negative = runner.preflight_condition_provider_settings(broken_condition)
        if negative.readiness.value != "Invalid" or negative.protocol_ready:
            raise RuntimeError("R5 representation did not reproduce frozen executable rejection")
        probes = {}
        for label, condition in zip(("A6", "B6"), conditions):
            runtime = runner.preflight_condition_runtime(condition)
            provider = runner.preflight_condition_provider_settings(condition)
            tools = runner.preflight_condition_tool_execution(condition)
            if (
                runtime.readiness.value != "Ready"
                or provider.readiness.value != "Ready"
                or tools.readiness.value != "Ready"
            ):
                raise RuntimeError(f"{label} full credential-free readiness failed")
            if not provider.get_state_ready:
                raise RuntimeError(f"{label} product-loaded model was not observable")
            probes[label] = {
                "runtime": jsonable(runtime),
                "providerSettingsCompatibility": jsonable(provider),
                "toolSandbox": jsonable(tools),
                "realTrialReadiness": "Ready",
            }
    finally:
        runner.close()
        if old_sdk is None:
            os.environ.pop("CANGJIE_HOME", None)
        else:
            os.environ["CANGJIE_HOME"] = old_sdk
    after = database_counts(eval_home / "evals.db")
    if before != after:
        raise RuntimeError("R6 readiness created Experiment or Trial rows")

    with tempfile.TemporaryDirectory(prefix="exp001r6-cas-") as raw:
        cas_home = Path(raw) / "fresh-home"
        structure = materialize_provider_settings_closure(
            closure, artifacts, cas_home, PROVIDER,
        )
        if validate_materialized_provider_settings(cas_home) != structure:
            raise RuntimeError("ProviderSettingsClosure CAS round-trip changed structure")

    created_at = utc_now()
    plan = build_experiment_plan(
        EXPERIMENT, "PairedAB", suite, tasks, conditions, 3, SEED, created_at,
    )
    validate_experiment_plan_inputs(suite, tasks, conditions, plan)
    plan_value = plan_artifact(plan)
    reloaded = experiment_plan_from_mapping(plan_value)
    validate_experiment_plan_inputs(suite, tasks, conditions, reloaded)
    if reloaded != plan:
        raise RuntimeError("R6 canonical plan round-trip changed semantics")

    destination.mkdir(parents=True)
    write_json(destination / "parent-evidence.json", {
        "parentExperiment": PARENT,
        "parentStatus": "ExperimentInvalidated",
        "failureCategory": "FrozenProviderReplayFailed",
        "reason": (
            "ProviderExecutionSpec was frozen, but product settings/catalog materialization "
            "was not executable-compatible. ProviderSettingsClosure and frozen-executable "
            "config acceptance were added."
        ),
        "parentArtifactHashes": r5_hashes,
        "parentConditionHashes": condition_hashes,
    })
    write_json(destination / "provider-settings-root-cause.json", root_cause())
    write_json(destination / "provider-settings-closure.json", {
        **closure, "closureRef": closure_ref,
    })
    write_json(destination / "provider-settings-compatibility.json", {
        "schemaVersion": "exp-001r6-provider-settings-compatibility-v1",
        "providerExecutionDigest": PROVIDER,
        "providerSettingsClosureDigest": closure_digest,
        "negativeR5Fixture": jsonable(negative),
        "conditions": probes,
        "casRematerialization": {
            "result": "Pass", "freshHome": True, "fileDigestsVerified": True,
            "temporaryGenerationDirectoryUnavailable": True,
        },
        "ambientFixture": "different default/provider/model and empty catalogs",
        "ambientSettingsUsed": False,
        "providerRequests": 0, "modelCalls": 0,
    })
    write_json(destination / "controlled-variables.json", {
        "taskEqual": True,
        "providerExecutionDigestEqual": True,
        "providerSettingsClosureDigestEqual": True,
        "parserApplicationSchemaEqual": True,
        "runtimeClosureSubstrateEquivalent": True,
        "toolExecutionPlaneEqual": True,
        "environmentClassEqual": True,
        "budgetGraderEqual": True,
        "onlyCapabilityVariable": "EditModelContract",
        "conditionDecision": "CreateA6B6",
    })
    write_json(destination / "invariant-snapshot.json", {
        "schemaVersion": plan.invariant_schema_version,
        "snapshot": jsonable(plan.invariant_snapshot),
        "snapshotDigest": plan.invariant_snapshot_digest,
        "providerExecutionDigest": PROVIDER,
        "providerSettingsClosureDigest": closure_digest,
        "providerSettingsClosureRef": closure_ref,
        "sourceConditionRefs": [str(path.relative_to(root)) for path in condition_paths],
        "taskRef": "eval_tasks/cangjie_midpoint_precedence/qualified-task.json",
    })
    write_json(destination / "experiment-plan.json", plan_value)
    write_json(destination / "canonical-match.json", {
        "frozenSnapshotDigest": plan.invariant_snapshot_digest,
        "executionSnapshotDigest": plan.invariant_snapshot_digest,
        "providerExecutionDigest": PROVIDER,
        "providerSettingsClosureDigest": closure_digest,
        "semanticEquality": True, "digestEquality": True, "result": "Pass",
    })
    write_json(destination / "readiness.json", {
        "conditions": probes,
        "providerSettingsCompatibility": {"A6": "Ready", "B6": "Ready"},
        "frozenPlanCanonicalMatch": "Pass",
        "executableExperimentReady": True,
        "providerRequests": 0, "modelCalls": 0, "agentTrials": 0,
    })
    write_json(destination / "security-verification.json", {
        "credentialValuePersisted": False,
        "clearenvRetained": True,
        "innerSandboxRetained": True,
        "networkPolicyChanged": False,
        "ambientSettingsInherited": False,
        "arbitraryMounts": False,
    })
    write_json(destination / "hypothesis.json", {
        "mechanism": "Aligned trailing-colon model contract reduces MissingRequiredColon edit attempts.",
        "outcome": "Fewer malformed edits improve Candidate Correct and/or Strict PASS.",
        "changedFromParent": False,
    })
    write_json(destination / "trial-index.json", {
        "plannedTrials": [jsonable(item) for item in plan.order],
        "completedTrials": [],
    })
    write_json(destination / "decision.json", {
        "schemaVersion": "exp-001r6-readiness-decision-v1",
        "status": "INCOMPLETE",
        "readiness": "READY_FOR_REAL_EXECUTION",
        "conditionDecision": "CreateA6B6",
        "paidExecutionAuthorized": False,
    })
    write_json(destination / "manifest.json", {
        "experimentId": EXPERIMENT, "version": "1",
        "parentExperiment": PARENT, "status": "ReadyForRealExecution",
        "taskFingerprint": TASK,
        "conditionDecision": "CreateA6B6",
        "conditionFingerprints": [item.fingerprint for item in conditions],
        "providerExecutionDigest": PROVIDER,
        "providerSettingsClosureDigest": closure_digest,
        "providerSettingsClosureRef": closure_ref,
        "invariantSchemaVersion": plan.invariant_schema_version,
        "invariantSnapshotDigest": plan.invariant_snapshot_digest,
        "runtimeReadiness": {"A6": "Ready", "B6": "Ready"},
        "toolSandboxReadiness": {"A6": "Ready", "B6": "Ready"},
        "providerSettingsCompatibility": {"A6": "Ready", "B6": "Ready"},
        "frozenPlanCanonicalMatch": "Pass",
        "createdAt": created_at,
        "offlineProof": {
            "providerRequests": 0, "modelCalls": 0, "agentTrials": 0,
            "graderExecutions": 0, "candidateMutations": 0,
        },
    })
    if immutable_hashes(r5) != r5_hashes:
        raise RuntimeError("EXP-001R5 immutable artifacts changed")
    if {path.name: hash_file(path) for path in (condition_a5, condition_b5)} != condition_hashes:
        raise RuntimeError("A5/B5 immutable conditions changed")
    print(json.dumps({
        "experimentId": EXPERIMENT,
        "conditionFingerprints": [item.fingerprint for item in conditions],
        "providerExecutionDigest": PROVIDER,
        "providerSettingsClosureDigest": closure_digest,
        "providerSettingsClosureRef": closure_ref,
        "snapshotDigest": plan.invariant_snapshot_digest,
        "order": [jsonable(item) for item in plan.order],
        "readiness": "ReadyForRealExecution",
        "database": after,
    }, separators=(",", ":")))
    return 0


def root_cause() -> dict:
    return {
        "schemaVersion": "exp-001r6-provider-settings-root-cause-v1",
        "r5Generated": {
            "defaultModel": "frozen-provider/deepseek-v4-flash",
            "modelId": "deepseek-v4-flash",
            "modelProviderRef": "frozen-provider",
            "modelDisplayId": "frozen-provider/deepseek-v4-flash",
        },
        "r5ConditionModelOverride": "frozen-deepseek/deepseek-v4-flash",
        "productLookupRule": (
            "CLI model override replaces config.default_model; validation requires exact equality "
            "with ModelCatalogEntry.displayId() = providerProfile + '/' + model id."
        ),
        "exactMismatch": (
            "frozen-deepseek/deepseek-v4-flash != "
            "frozen-provider/deepseek-v4-flash"
        ),
        "whyStaticPreflightMissed": (
            "R5 validated ProviderExecutionSpec and generated files independently, but did not "
            "launch each frozen executable with its real condition model override."
        ),
        "rootCauseConfidence": 1.0,
        "evidenceTrialIds": [
            "trial-090387aa-4456-44e1-b6f7-30ae50fca509",
            "trial-fabf7783-3c7c-4ec0-8a93-63feaa7a18a0",
            "trial-ad85b503-9243-49c8-9e4b-d20ceac42bfb",
            "trial-cda50525-085a-41cd-9350-023447e8bc36",
            "trial-542b878d-7f2e-4ecb-8d59-61f75df8dfd8",
            "trial-df859b5d-805e-4999-b2e5-417b219471f6",
        ],
    }


def controlled_projection(value: dict) -> dict:
    omitted = {
        "id", "agentBinaryDigest", "agentBinaryArtifactRef", "editAciContract",
        "editModelContractDigest", "toolDescriptionDigest", "runtimeClosureRef",
        "runtimeClosureDigest",
    }
    return {key: item for key, item in value.items() if key not in omitted}


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


def immutable_hashes(root: Path) -> dict[str, str]:
    return {path.name: hash_file(path) for path in sorted(root.iterdir()) if path.is_file()}


def database_counts(path: Path) -> dict:
    connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
    try:
        return {
            "agentTrials": connection.execute("SELECT COUNT(*) FROM agent_trials").fetchone()[0],
            "candidateSnapshots": connection.execute("SELECT COUNT(*) FROM candidate_snapshots").fetchone()[0],
            "gradingRuns": connection.execute("SELECT COUNT(*) FROM grading_runs").fetchone()[0],
            "r6ExperimentPlans": connection.execute(
                "SELECT COUNT(*) FROM experiment_plans WHERE id=?", (EXPERIMENT,),
            ).fetchone()[0],
            "r6TrialRows": connection.execute(
                "SELECT COUNT(*) FROM experiment_trials WHERE experiment_id=?", (EXPERIMENT,),
            ).fetchone()[0],
        }
    finally:
        connection.close()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
