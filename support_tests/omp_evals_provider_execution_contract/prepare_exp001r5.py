from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path

import yaml

from omp_evals.benchmark import (
    build_condition, build_experiment_plan, load_suite, validate_experiment_plan_inputs,
)
from omp_evals.experiment_invariants import experiment_plan_from_mapping
from omp_evals.model import jsonable
from omp_evals.provider_execution import (
    canonical_provider_execution_spec, materialize_provider_settings,
    provider_execution_digest,
)
from omp_evals.runner import EvalRunner, _settings_fingerprint
from omp_evals.util import hash_file, hash_json, utc_now


EXPERIMENT = "EXP-001R5-frozen-provider-execution-spec"
PARENT = "EXP-001R4-canonical-experiment-invariants-refreeze"
TASK = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
A3 = "ec791cd525396278fbd44927f3900b30282eb208fd53472628bd4756ef6064a9"
B3 = "664ce859d5eef9c9db82930a6546a28606c075aaa16c7ac0dc8961b57b590363"
R4_HASHES = {
    "aggregate-result.json": "a36a6ae84175459f609f50723755392c444d792e618a93866db9294e3b19132f",
    "canonical-match.json": "edaa22c12e2a3b16e1c71ad2076caaf00e7434c1e925618bba5da6dfa7c78f34",
    "decision.json": "6a0574e4543a3b3e78253e308cdd5ad26316f4b903d45374d3db6be510611789",
    "experiment-plan.json": "7864e85ff5de69fc9940e83d1c4bd8269e16e6fbcd44c8dc172d916161a69a4f",
    "failure-analysis.json": "8c3c3281df899782a6a43f5416f85fecb1b645085a2374ca84024f8360380405",
    "hypothesis.json": "50ccaa5eeeec16bb3369046995988d7653764dfa52badb943d1ca2f2f4b707f9",
    "invariant-snapshot.json": "d4db2fd8b2ad9ec63e5ae9695dfb7e50dccf35ad84518359ef9f3fcd8864d730",
    "manifest.json": "b1cc483837d532ddd2b31a06e28fad7cc23df02b3639e19bd97d5d3158794acb",
    "mechanism-analysis.json": "79097d8aab3d4e8cf1a55a95e2188af72894ac740f54744ae135ef04baae9275",
    "parent-evidence.json": "b907e407fac267d95a82d0f619d121efa25379b683b9d50d18505f9b2c6d8c78",
    "projection-audit.json": "bd886e286394331db1259099afd19a432d2cf3c3e19c01f77ba51c44b132ef86",
    "readiness.json": "1ce51244ade3343b047d9e669c6459bfae56473289e5af8a46ca08bdbdddf8a4",
    "real-execution-preflight.json": "e6c0812e3c9b27539819f02d84a39176e933eefb86de5f8a0bbcce11e0ae4b2b",
    "trial-index.json": "215de498b4826057ad3c941e2d87cf610a704e10ac23531af78d09f56ac87867",
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
    r4 = root / "eval_experiments" / PARENT
    if {name: hash_file(r4 / name) for name in R4_HASHES} != R4_HASHES:
        raise RuntimeError("EXP-001R4 immutable artifact drift")

    source_settings = _settings_fingerprint(options.settings)
    full_settings_digest = hash_json(source_settings)
    if full_settings_digest != "e56be75a2a0c1fcf630066ce5d1e6dcf6c668af6a0f5864f252d8d6e5aad32cf":
        raise RuntimeError("current provider settings source drifted during R5 freeze")
    spec, profile_alias = resolve_current_spec(options.settings)
    execution_digest = provider_execution_digest(spec)

    condition_sources = (
        root / "eval_conditions/exp-001r3-edit-model-contract-a3.json",
        root / "eval_conditions/exp-001r3-edit-model-contract-b3.json",
    )
    condition_paths = (
        root / "eval_conditions/exp-001r5-edit-model-contract-a5.json",
        root / "eval_conditions/exp-001r5-edit-model-contract-b5.json",
    )
    for source, target, label in zip(condition_sources, condition_paths, ("a5", "b5")):
        value = json.loads(source.read_text())
        value.update({
            "id": f"exp-001r5-edit-model-contract-{label}",
            "version": "1",
            "derivesFrom": value["id"],
            "provider": "frozen-provider-execution-spec",
            "frozenProviderProfileId": "frozen-deepseek",
            "providerExecutionSpec": spec,
            "providerExecutionDigest": execution_digest,
        })
        write_json(target, value)

    suite, tasks = load_suite(
        root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
    )
    if len(tasks) != 1 or tasks[0].task_fingerprint != TASK:
        raise RuntimeError("task fingerprint drift")
    conditions = tuple(
        build_condition(path, tasks[0], Path("/unused"), options.settings)
        for path in condition_paths
    )
    if conditions[0].provider_execution_digest != conditions[1].provider_execution_digest:
        raise RuntimeError("A5/B5 provider execution semantics differ")
    if conditions[0].manifest["editModelContractDigest"] == conditions[1].manifest["editModelContractDigest"]:
        raise RuntimeError("A5/B5 independent variable disappeared")

    created_at = utc_now()
    plan = build_experiment_plan(EXPERIMENT, "PairedAB", suite, tasks, conditions, 3, 1005, created_at)
    validate_experiment_plan_inputs(suite, tasks, conditions, plan)
    artifact = plan_artifact(plan)
    reloaded = experiment_plan_from_mapping(artifact)
    validate_experiment_plan_inputs(suite, tasks, conditions, reloaded)
    if reloaded != plan:
        raise RuntimeError("R5 plan canonical round-trip changed semantics")

    with __import__("tempfile").TemporaryDirectory() as raw:
        ambient = Path(raw) / "ambient"
        ambient.mkdir()
        (ambient / "config.yml").write_text("default_model: renamed/other-model\n")
        (ambient / "providers.yml").write_text("providers: []\n")
        (ambient / "models.yml").write_text("models: []\n")
        replay = tuple(build_condition(path, tasks[0], Path("/unused"), ambient) for path in condition_paths)
        if tuple(item.fingerprint for item in replay) != tuple(item.fingerprint for item in conditions):
            raise RuntimeError("ambient settings changed frozen condition replay")
        validate_experiment_plan_inputs(suite, tasks, replay, reloaded)
        materialized = Path(raw) / "materialized"
        result = materialize_provider_settings(spec, materialized, "frozen-deepseek")
        if result["providerExecutionDigest"] != execution_digest:
            raise RuntimeError("provider materialization digest mismatch")

    before = database_counts(options.eval_home / "evals.db", EXPERIMENT)
    old_sdk = os.environ.get("CANGJIE_HOME")
    os.environ["CANGJIE_HOME"] = str(options.sdk_root.resolve())
    runner = EvalRunner(options.eval_home)
    readiness = {}
    try:
        for label, condition in zip(("A5", "B5"), conditions):
            runtime = runner.preflight_condition_runtime(condition)
            tools = runner.preflight_condition_tool_execution(condition)
            if runtime.readiness.value != "Ready" or tools.readiness.value != "Ready":
                raise RuntimeError(f"{label} readiness failed")
            readiness[label] = {
                "runtime": jsonable(runtime), "toolSandbox": jsonable(tools),
                "realTrialReadiness": "Ready",
            }
    finally:
        runner.close()
        if old_sdk is None:
            os.environ.pop("CANGJIE_HOME", None)
        else:
            os.environ["CANGJIE_HOME"] = old_sdk
    after = database_counts(options.eval_home / "evals.db", EXPERIMENT)
    if before != after or after["experimentPlans"] or after["trialRows"]:
        raise RuntimeError("R5 freeze/readiness created experiment or Trial rows")

    destination.mkdir(parents=True)
    condition_fingerprints = [item.fingerprint for item in conditions]
    provider_artifact = {
        "schemaVersion": spec["schemaVersion"],
        "spec": spec,
        "providerExecutionDigest": execution_digest,
        "sourceProvenance": {
            "profileAlias": profile_alias,
            "fullSettingsManifestDigest": full_settings_digest,
            "fieldRecovery": "current explicit providers.yml + models.yml + product defaults",
        },
        "credentialSlot": spec["credentialSlot"], "credentialValuePersisted": False,
    }
    write_json(destination / "provider-execution-spec.json", provider_artifact)
    write_json(destination / "provider-drift-audit.json", drift_audit(spec, full_settings_digest))
    write_json(destination / "parent-evidence.json", {
        "parentExperiment": PARENT,
        "reason": "Provider/settings reconstruction depended on mutable ambient profile identity; frozen provider execution semantics are now explicit and materialized.",
        "parentArtifactHashes": R4_HASHES,
        "parentStatus": "FrozenIntegrityFailed",
    })
    write_json(destination / "invariant-snapshot.json", {
        "schemaVersion": plan.invariant_schema_version,
        "snapshot": jsonable(plan.invariant_snapshot),
        "snapshotDigest": plan.invariant_snapshot_digest,
        "providerExecutionDigest": execution_digest,
        "sourceConditionRefs": [str(path.relative_to(root)) for path in condition_paths],
        "taskRef": "eval_tasks/cangjie_midpoint_precedence/qualified-task.json",
    })
    write_json(destination / "experiment-plan.json", artifact)
    write_json(destination / "canonical-match.json", {
        "frozenSnapshotDigest": plan.invariant_snapshot_digest,
        "executionSnapshotDigest": plan.invariant_snapshot_digest,
        "ambientFixture": "different profile/model/empty catalogs",
        "providerExecutionDigest": execution_digest,
        "semanticEquality": True, "digestEquality": True, "result": "Pass",
    })
    write_json(destination / "readiness.json", {
        "conditions": readiness, "frozenPlanCanonicalMatch": "Pass",
        "providerExecutionSpecMaterialization": "Pass",
        "executableExperimentReady": True,
        "providerRequests": 0, "modelCalls": 0, "agentTrials": 0,
    })
    write_json(destination / "controlled-variables.json", {
        "taskEqual": True, "modelProviderEqual": True, "providerExecutionDigestEqual": True,
        "promptEqual": True, "parserApplicationSchemaEqual": True,
        "runtimeClosureSubstrateEquivalent": True, "toolExecutionPlaneEqual": True,
        "environmentClassEqual": True, "budgetGraderEqual": True,
        "onlyCapabilityVariable": "EditModelContract",
        "conditionDecision": "CreateA5B5",
    })
    write_json(destination / "hypothesis.json", {
        "mechanism": "Aligned trailing-colon model contract reduces MissingRequiredColon edit attempts.",
        "outcome": "Fewer malformed edits improve Candidate Correct and/or Strict PASS.",
        "changedFromParent": False,
    })
    write_json(destination / "manifest.json", {
        "experimentId": EXPERIMENT, "version": "1", "parentExperiment": PARENT,
        "status": "ReadyForRealExecution", "taskFingerprint": TASK,
        "conditionDecision": "CreateA5B5", "conditionFingerprints": condition_fingerprints,
        "providerDriftAssessment": "InsufficientEvidence",
        "providerExecutionDigest": execution_digest,
        "invariantSchemaVersion": plan.invariant_schema_version,
        "invariantSnapshotDigest": plan.invariant_snapshot_digest,
        "runtimeReadiness": {"A5": "Ready", "B5": "Ready"},
        "toolSandboxReadiness": {"A5": "Ready", "B5": "Ready"},
        "frozenPlanCanonicalMatch": "Pass", "createdAt": created_at,
        "offlineProof": {"providerRequests": 0, "modelCalls": 0, "agentTrials": 0,
                         "graderExecutions": 0, "candidateMutations": 0},
    })
    print(json.dumps({
        "experimentId": EXPERIMENT, "providerExecutionDigest": execution_digest,
        "conditionFingerprints": condition_fingerprints,
        "snapshotDigest": plan.invariant_snapshot_digest,
        "order": [jsonable(item) for item in plan.order],
        "readiness": "ReadyForRealExecution", "database": after,
    }, separators=(",", ":")))
    return 0


def resolve_current_spec(settings: Path) -> tuple[dict, str]:
    config = yaml.safe_load((settings / "config.yml").read_text())
    profiles = yaml.safe_load((settings / "providers.yml").read_text())["providers"]
    models = yaml.safe_load((settings / "models.yml").read_text())["models"]
    profile_alias, wire_model = str(config["default_model"]).split("/", 1)
    profile = next(item for item in profiles if item["id"] == profile_alias)
    model = next(item for item in models if item["id"] == wire_model and item["provider"] == profile_alias)
    context = int(model.get("context_window", 128000))
    provider = str(profile["provider"])
    protocol = str(profile["protocol"])
    base_url = str(profile["base_url"]).rstrip("/")
    prompt_cache = bool(model.get("prompt_cache", False))
    value = canonical_provider_execution_spec({
        "adapterIdentity": provider, "protocol": protocol, "baseUrl": base_url,
        "wireModel": wire_model, "authentication": profile.get("authentication", "api-key"),
        "credentialSlot": profile["api_key_env"],
        "timeoutMillis": profile.get("timeout_millis", 120000),
        "messagesFastMode": False,
        "capabilities": {
            "toolCalling": True, "parallelToolCalling": True,
            "reasoning": bool(model.get("reasoning", True)),
            "vision": "image" in model.get("input_modalities", []),
            "structuredOutput": bool(model.get("structured_output", False)),
            "promptCache": prompt_cache,
            "contextWindowTokens": context,
            "maxOutputTokens": int(model.get("max_output_tokens", min(context, 16384))),
        },
        "requestSettings": {}, "reasoningSettings": {}, "providerOptions": {},
    })
    return value, profile_alias


def drift_audit(current_spec: dict, full_settings_digest: str) -> dict:
    return {
        "schemaVersion": "exp-001r5-provider-drift-audit-v1",
        "frozen": {
            "profileAlias": "DEEPSEEK", "logicalModel": "DEEPSEEK/deepseek-v4-flash",
            "fullSettingsManifestDigest": "7e236bbe25354bd511acd87bda37cff0ac4919f4a182fdaf15632a755a697718",
            "knownEndpointBase": "https://api.deepseek.com",
            "adapter": "unrecoverable", "protocol": "unrecoverable",
            "credentialSlot": "DEEPSEEK_API_KEY", "capabilities": "unrecoverable",
        },
        "current": {
            "profileAlias": "deepseek-openai",
            "logicalModel": "deepseek-openai/deepseek-v4-flash",
            "fullSettingsManifestDigest": full_settings_digest,
            "canonicalExecutionSpec": current_spec,
        },
        "fieldComparison": [
            {"field": "profileAlias", "frozen": "DEEPSEEK", "current": "deepseek-openai", "semantic": False, "equal": False},
            {"field": "baseUrl", "frozen": "https://api.deepseek.com", "current": current_spec["baseUrl"], "semantic": True, "equal": True},
            {"field": "wireModel", "frozen": "deepseek-v4-flash", "current": current_spec["wireModel"], "semantic": True, "equal": True},
            {"field": "adapterIdentity", "frozen": "unrecoverable", "current": current_spec["adapterIdentity"], "semantic": True, "equal": None},
            {"field": "protocol", "frozen": "unrecoverable", "current": current_spec["protocol"], "semantic": True, "equal": None},
            {"field": "timeoutMillis", "frozen": "unrecoverable", "current": current_spec["timeoutMillis"], "semantic": True, "equal": None},
            {"field": "capabilities", "frozen": "unrecoverable", "current": current_spec["capabilities"], "semantic": True, "equal": None},
        ],
        "providerDriftAssessment": "InsufficientEvidence",
        "reason": "A3/B3 persisted profile/model strings and a settings digest, not the adapter, protocol, timeout, or resolved capability values needed to prove semantic equivalence.",
        "conditionDecision": "CreateA5B5",
    }


def plan_artifact(plan) -> dict:
    return {
        "experimentId": plan.id, "kind": plan.kind, "suiteFingerprint": plan.suite_fingerprint,
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
            "experimentPlans": connection.execute("SELECT COUNT(*) FROM experiment_plans WHERE id=?", (experiment,)).fetchone()[0],
            "trialRows": connection.execute("SELECT COUNT(*) FROM experiment_trials WHERE experiment_id=?", (experiment,)).fetchone()[0],
        }
    finally:
        connection.close()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
