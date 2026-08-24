from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path

from omp_evals.benchmark import _experiment_invariants, _experiment_order, build_condition, load_suite
from omp_evals.model import ToolSandboxReadiness, jsonable
from omp_evals.runtime_closure import materialize_runtime_closure
from omp_evals.storage import ArtifactStore, EvalDatabase
from omp_evals.util import hash_file, hash_json, utc_now
from omp_evals.worker import ProcessAgentWorker


TASK = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
OLD_A = "406822b32906023f713d72bf36c403dd5355eda9ce6067041dcc1f841bc9ec9b"
OLD_B = "b86e1eb2a6c8db30d3f460cb5764cb5d59f67daae49145b25eb79f7f3e50d28e"
EXPERIMENT = "EXP-001R3-tool-sandbox-readiness-refreeze"
SEED = 1003


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    options = parser.parse_args()
    root = options.root.resolve()
    eval_home = options.eval_home.resolve()
    artifacts = ArtifactStore(eval_home / "artifacts")
    prior = root / "eval_experiments/EXP-001R2-edit-aci-runtime-closure-refreeze"
    destination = root / "eval_experiments" / EXPERIMENT
    if destination.exists():
        raise FileExistsError(f"immutable experiment already exists: {destination}")
    suite, tasks = load_suite(root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json")
    task = tasks[0]
    if task.task_fingerprint != TASK:
        raise RuntimeError("task fingerprint drift")
    old_configs = (
        json.loads((root / "eval_conditions/exp-001r2-edit-model-contract-a2-prime.json").read_text()),
        json.loads((root / "eval_conditions/exp-001r2-edit-model-contract-b2-prime.json").read_text()),
    )
    tool_plane = {
        "schemaVersion": "omp-evals-tool-execution-plane-v1",
        "sandboxBackend": "bubblewrap",
        "outerIsolation": {"clearenv": True, "networkPolicy": "unchanged-per-trial"},
        "composition": {"privateTmpMount": "/tmp", "innerSandboxRetained": True},
        "workspaceGuestPath": "identity-mapped-fresh-trial-workspace",
        "tempGuestPath": "identity-mapped-fresh-trial-tmp",
        "executionEnvironmentClass": "exp-001r3-local-linux-bwrap-tool-plane-v2",
        "evalWorkerDigest": hash_file(root / "omp_evals/worker.py"),
        "sandboxPolicyDigest": hash_file(root / "libs/sandbox4cj/src/sandbox.cj"),
    }
    tool_plane_digest = hash_json(tool_plane)
    condition_paths = []
    configs = []
    for label, old in zip(("a3", "b3"), old_configs):
        config = dict(old)
        config["id"] = f"exp-001r3-edit-model-contract-{label}"
        config["version"] = "1"
        config["environmentClass"] = "exp-001r3-local-linux-x86_64-sdk-20260803-tool-plane-v2"
        config["toolExecutionPlane"] = tool_plane
        config["toolExecutionPlaneDigest"] = tool_plane_digest
        config["derivesFrom"] = old["id"]
        path = root / "eval_conditions" / f"exp-001r3-edit-model-contract-{label}.json"
        write_json(path, config)
        condition_paths.append(path)
        configs.append(config)
    conditions = tuple(build_condition(path, task, Path("/unused"), options.settings) for path in condition_paths)
    if tuple(item.fingerprint for item in conditions) == (OLD_A, OLD_B):
        raise RuntimeError("tool execution environment change did not change condition fingerprints")
    if controlled_projection(conditions[0].manifest) != controlled_projection(conditions[1].manifest):
        raise RuntimeError("A3/B3 have an uncontrolled variable")

    probes = {}
    worker = ProcessAgentWorker()
    for label, config in zip(("A3", "B3"), configs):
        with tempfile.TemporaryDirectory(prefix=f"exp001r3-{label.lower()}-", dir=eval_home) as temporary:
            base = Path(temporary)
            for name in ("workspace", "omp-home", "tmp"):
                (base / name).mkdir()
            (base / "workspace" / "probe.cj").write_text("main(): Int64 { 0 }\n")
            before = hash_file(base / "workspace" / "probe.cj")
            runtime = materialize_runtime_closure(
                config["runtimeClosure"], artifacts, base / "runtime",
                {"CangjieSDK": options.sdk_root.resolve()},
            )
            result = worker.probe_tool_execution_plane(
                runtime, base / "workspace", base / "omp-home", base / "tmp",
            )
            after = hash_file(base / "workspace" / "probe.cj")
            if result.readiness != ToolSandboxReadiness.READY or before != after:
                raise RuntimeError(f"{label} tool execution plane is not ready: {result}")
            probes[label] = {**jsonable(result), "workspaceDigestUnchanged": before == after}

    order = _experiment_order(tasks, conditions, 3, SEED)
    invariants = dict(_experiment_invariants(tasks, conditions, paired=True))
    invariants["toolExecutionPlaneDigest"] = tool_plane_digest
    destination.mkdir(parents=True)
    write_json(destination / "parent-evidence.json", {
        "parentExperiment": "EXP-001R2-edit-aci-runtime-closure-refreeze",
        "reason": "ToolExecutionPlane infrastructure was invalid; nested sandbox readiness and TrialValidity propagation were corrected.",
        "parentDecisionDigest": hash_file(prior / "decision.json"),
        "parentTrialIndexDigest": hash_file(prior / "trial-index.json"),
        "parentConditionFingerprints": [OLD_A, OLD_B],
    })
    write_json(destination / "reproduction-failure.json", {
        "schemaVersion": "exp-001r3-reproduction-v1",
        "tool": "RPC bash process-backed control",
        "outerTopology": {"privateTmpMount": False, "evalHomeClass": "/home/.../.omp-evals"},
        "innerSandboxArgument": ["--tmpfs", "/tmp"],
        "exactFailure": "bwrap: Failed to mount tmpfs: No such file or directory",
        "rootCause": "The outer Eval mount namespace omitted /tmp when trial paths were under /home; the nested sandbox required /tmp as its tmpfs destination.",
        "confidence": 1.0, "credentialNames": [], "modelCalls": 0, "providerRequests": 0,
    })
    write_json(destination / "tool-execution-plane.json", {**tool_plane, "digest": tool_plane_digest})
    write_json(destination / "tool-sandbox-readiness.json", {
        "schemaVersion": "omp-evals-tool-readiness-v1", "probes": probes,
        "realTrialReadiness": "Ready", "modelCalls": 0, "providerRequests": 0,
    })
    for label, condition, old in zip(("a3", "b3"), conditions, (OLD_A, OLD_B)):
        write_json(destination / f"condition-{label}.json", {
            **jsonable(condition), "derivesFrom": old,
            "runtimeReadiness": "Ready", "toolSandboxReadiness": "Ready",
        })
    write_json(destination / "experiment-plan.json", {
        "experimentId": EXPERIMENT, "kind": "PairedAB", "parentExperiment": "EXP-001R2",
        "taskFingerprint": TASK, "conditionFingerprints": [item.fingerprint for item in conditions],
        "trialsPerCondition": 3, "seed": SEED, "invariants": invariants,
        "order": [jsonable(item) for item in order], "status": "ReadyForRealExecution",
    })
    write_json(destination / "manifest.json", {
        "experimentId": EXPERIMENT, "version": "1", "status": "ReadyForRealExecution",
        "parentExperiment": "EXP-001R2-edit-aci-runtime-closure-refreeze",
        "taskFingerprint": TASK, "conditionFingerprints": [item.fingerprint for item in conditions],
        "hypothesisUnchanged": True, "runtimeReadiness": {"A3": "Ready", "B3": "Ready"},
        "toolSandboxReadiness": {"A3": "Ready", "B3": "Ready"},
        "createdAt": utc_now(),
        "offlineProof": {"modelCalls": 0, "agentTrials": 0, "providerRequests": 0,
                         "graderExecutions": 0, "candidateMutations": 0},
    })
    apply_historical_assessments(eval_home / "evals.db", prior)
    print(json.dumps({
        "experimentId": EXPERIMENT, "conditions": [item.fingerprint for item in conditions],
        "toolExecutionPlaneDigest": tool_plane_digest,
        "order": [jsonable(item) for item in order], "readiness": "ReadyForRealExecution",
    }, separators=(",", ":")))
    return 0


def apply_historical_assessments(database_path: Path, prior: Path) -> None:
    database = EvalDatabase(database_path)
    try:
        failure = json.loads((prior / "failure-analysis.json").read_text())
        for item in failure["trials"]:
            value = {
                "id": "validity-exp001r2-" + item["trialId"], "trialId": item["trialId"],
                "version": "tool-sandbox-infrastructure-v1",
                "effectiveValidity": "InvalidEnvironmentInfrastructure",
                "source": "DeterministicTypedEvidence",
                "storedValidity": item["storedValidity"], "evidenceRefs": item["evidenceRefs"],
            }
            try:
                database.save_validity_assessment(value)
            except Exception as error:
                if "UNIQUE constraint failed" not in str(error):
                    raise
    finally:
        database.close()


def controlled_projection(manifest: dict) -> dict:
    omitted = {
        "id", "agentBinaryDigest", "agentBinaryArtifactRef", "editAciContract",
        "editModelContractDigest", "toolDescriptionDigest",
        "runtimeClosureRef", "runtimeClosureDigest",
    }
    # Executable/closure differences are the frozen consequence of the original
    # EditModelContract variable; shared runtime and tool-plane identities are
    # compared by the EXP-001R2 and EXP-001R3 manifests.
    return {key: value for key, value in manifest.items() if key not in omitted}


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
