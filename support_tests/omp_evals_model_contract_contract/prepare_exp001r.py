from __future__ import annotations

import argparse
import difflib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from omp_evals.benchmark import _experiment_invariants, _experiment_order, build_condition
from omp_evals.model import jsonable
from omp_evals.storage import ArtifactStore
from omp_evals.task import parse_qualified_task
from omp_evals.util import canonical_json, hash_file, hash_json


TASK_FINGERPRINT = "0714cb4d0506359e55a75aa167540bc91ac7dbb3dceda5a545043995f6ab1d1d"
SEED = 1001

CURRENT_DESCRIPTOR = '''                "Apply an atomic hashline patch after approval. Start with the exact [path#TAG] " +
                    "header returned by read; use SWAP N or SWAP N..=M followed by + replacement " +
                    "lines, DEL N or DEL N..=M, or INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N followed " +
                    "by + inserted lines. Unified-diff @@ syntax is not accepted.",'''

A2_DESCRIPTOR = '''                "Apply an atomic hashline patch after approval. Start with the exact [path#TAG] " +
                    "header returned by read. Grammar: SWAP N or SWAP N..=M followed by + replacement " +
                    "lines; DEL N or DEL N..=M; INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N followed by + " +
                    "inserted lines. Examples: [path#TAG]\\nSWAP N\\n+replacement and [path#TAG]\\n" +
                    "INS.POST N\\n+inserted. Unified-diff @@ syntax is not accepted.",'''

B2_DESCRIPTOR = A2_DESCRIPTOR.replace("SWAP N or SWAP N..=M", "SWAP N: or SWAP N..=M:").replace(
    "INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N", "INS.HEAD:/INS.TAIL:/INS.PRE N:/INS.POST N:"
).replace("\\nSWAP N\\n", "\\nSWAP N:\\n").replace("\\nINS.POST N\\n", "\\nINS.POST N:\\n")
B2_DESCRIPTOR = B2_DESCRIPTOR.replace('"INS.POST N\\n+inserted', '"INS.POST N:\\n+inserted')

CURRENT_ERROR = '''        message + "; expected [path#TAG] followed by SWAP N or SWAP N..=M plus + rows, " +
            "DEL N or DEL N..=M, or INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N plus + rows"'''

A2_ERROR = '''        message + "; expected [path#TAG] followed by SWAP N or SWAP N..=M plus + rows, " +
            "DEL N or DEL N..=M, or INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N plus + rows; " +
            "examples: [path#TAG]\\nSWAP N\\n+replacement and [path#TAG]\\nINS.POST N\\n+inserted"'''

B2_ERROR = A2_ERROR.replace("SWAP N or SWAP N..=M", "SWAP N: or SWAP N..=M:").replace(
    "INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N", "INS.HEAD:/INS.TAIL:/INS.PRE N:/INS.POST N:"
).replace("\\nSWAP N\\n", "\\nSWAP N:\\n").replace("\\nINS.POST N\\n", "\\nINS.POST N:\\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--artifact-store", type=Path, required=True)
    parser.add_argument("--experiment-dir", type=Path, required=True)
    parser.add_argument("--condition-dir", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    arguments = parser.parse_args()
    source = arguments.source.resolve()
    task = parse_qualified_task(source / "eval_tasks/cangjie_midpoint_precedence/qualified-task.json")
    if task.task_fingerprint != TASK_FINGERPRINT:
        raise RuntimeError(f"midpoint task fingerprint changed: {task.task_fingerprint}")
    original_exp = source / "eval_experiments/EXP-001-edit-aci-contract-alignment"
    original_hashes = immutable_exp001_hashes(original_exp)

    with tempfile.TemporaryDirectory(prefix="exp001r-sources-") as temporary:
        temporary_root = Path(temporary)
        a2 = temporary_root / "a2"
        b2 = temporary_root / "b2"
        cj_tui = source.parent / "cj_tui"
        if not cj_tui.is_dir():
            raise RuntimeError(f"required sibling cj_tui source is unavailable: {cj_tui}")
        (temporary_root / "cj_tui").symlink_to(cj_tui, target_is_directory=True)
        copy_source(source, a2)
        copy_source(source, b2)
        apply_contract(a2, A2_DESCRIPTOR, A2_ERROR)
        apply_contract(b2, B2_DESCRIPTOR, B2_ERROR)
        changed_files, source_diff = compare_sources(a2, b2)
        if changed_files != ["agent_product/src/hashline.cj", "agent_product/src/tools.cj"]:
            raise RuntimeError(f"unexpected A2/B2 source differences: {changed_files}")

        digests_a = implementation_digests(a2, A2_DESCRIPTOR, A2_ERROR)
        digests_b = implementation_digests(b2, B2_DESCRIPTOR, B2_ERROR)
        for name in ("parserDigest", "applicationDigest", "toolSchemaDigest"):
            if digests_a[name] != digests_b[name]:
                raise RuntimeError(f"condition implementation mismatch: {name}")
        if digests_a["editModelContractDigest"] == digests_b["editModelContractDigest"]:
            raise RuntimeError("edit model contract digests must differ")

        build(a2, source, arguments.sdk_root)
        build(b2, source, arguments.sdk_root)
        binary_a = a2 / "target/release/bin/agent_app"
        binary_b = b2 / "target/release/bin/agent_app"
        driver_a = a2 / "support_tests/omp_evals_causal_preflight_driver/target/release/bin/main"
        driver_b = b2 / "support_tests/omp_evals_causal_preflight_driver/target/release/bin/main"
        store = ArtifactStore(arguments.artifact_store)
        binary_a_ref = store.put_bytes(binary_a.read_bytes())
        binary_b_ref = store.put_bytes(binary_b.read_bytes())
        driver_a_ref = store.put_bytes(driver_a.read_bytes())
        driver_b_ref = store.put_bytes(driver_b.read_bytes())
        binary_a_cas = artifact_path(arguments.artifact_store, binary_a_ref)
        binary_b_cas = artifact_path(arguments.artifact_store, binary_b_ref)

        common = {
            "version": "1",
            "provider": "settings-resolved",
            "environmentClass": "exp-001r-host-sdk-20260803",
            "baseProductState": f"HEAD:{git_head(source)}+relevant-working-tree:{relevant_state_digest(source)}",
            "harnessRevision": git_head(source),
            "systemPromptDigest": "unsupported",
            "generalPromptDigest": "unsupported",
            "nonEditToolSetDigest": hash_json(["workspace.read", "process.execute"]),
            "budgetDigest": hash_json(jsonable(task.resource_policy)),
            "toolSchemaDigest": digests_a["toolSchemaDigest"],
            "parserDigest": digests_a["parserDigest"],
            "applicationDigest": digests_a["applicationDigest"],
            "agent": {},
        }
        config_a = {
            **common, "id": "exp-001r-edit-model-contract-a2",
            "agentBinary": str(binary_a_cas), "agentBinaryArtifactRef": binary_a_ref,
            "toolDescriptionDigest": digests_a["editModelContractDigest"],
            "editModelContractDigest": digests_a["editModelContractDigest"],
            "editAciContract": contract_manifest("A2", False),
        }
        config_b = {
            **common, "id": "exp-001r-edit-model-contract-b2",
            "agentBinary": str(binary_b_cas), "agentBinaryArtifactRef": binary_b_ref,
            "toolDescriptionDigest": digests_b["editModelContractDigest"],
            "editModelContractDigest": digests_b["editModelContractDigest"],
            "editAciContract": contract_manifest("B2", True),
        }
        arguments.condition_dir.mkdir(parents=True, exist_ok=True)
        path_a = arguments.condition_dir / "exp-001r-edit-model-contract-a2.json"
        path_b = arguments.condition_dir / "exp-001r-edit-model-contract-b2.json"
        write_json(path_a, config_a)
        write_json(path_b, config_b)
        condition_a = build_condition(path_a, task, binary_a_cas, arguments.settings)
        condition_b = build_condition(path_b, task, binary_b_cas, arguments.settings)

        experiment = arguments.experiment_dir
        experiment.mkdir(parents=True, exist_ok=True)
        write_json(experiment / "parent-evidence.json", {
            "parentExperiment": "EXP-001-edit-aci-contract-alignment",
            "parentDecision": "Inconclusive",
            "causalPreflight": "../EXP-001-edit-aci-contract-alignment/causal-preflight.json",
            "causalLinkAssessment": "Contradicted",
            "historicalFailureAnalysis": "../../eval_tasks/cangjie_midpoint_precedence/failure-analysis-v1/report.json",
            "immutableParentArtifactHashes": original_hashes,
        })
        write_json(experiment / "hypothesis.json", {
            "experiment": "EXP-001R",
            "h1Mechanism": "Accurately exposing parser-required trailing-colon grammar reduces MissingRequiredColon edit attempts on cangjie-midpoint-precedence.",
            "h1Outcome": "Reducing malformed edit attempts increases Candidate Correct Rate and/or Strict Pass Rate.",
            "scope": "single-task mechanism experiment; no global capability claim",
        })
        write_json(experiment / "condition-a2.json", condition_artifact(
            condition_a, binary_a_ref, driver_a_ref, contract_manifest("A2", False), digests_a,
            "Mechanism-isolated control: corrected range parser plus colon-omitting model contract.",
        ))
        write_json(experiment / "condition-b2.json", condition_artifact(
            condition_b, binary_b_ref, driver_b_ref, contract_manifest("B2", True), digests_b,
            "Aligned treatment: corrected range parser plus parser-exact colon model contract.",
        ))
        write_json(experiment / "source-diff-manifest.json", {
            "changedFiles": changed_files,
            "allowedSemanticDifference": [
                "model-visible edit grammar and examples",
                "model-visible parser-error recovery grammar",
            ],
            "unifiedDiff": source_diff,
            "parserDigestEqual": digests_a["parserDigest"] == digests_b["parserDigest"],
            "applicationDigestEqual": digests_a["applicationDigest"] == digests_b["applicationDigest"],
            "toolSchemaDigestEqual": digests_a["toolSchemaDigest"] == digests_b["toolSchemaDigest"],
        })
        order = _experiment_order((task,), (condition_a, condition_b), 3, SEED)
        invariants = _experiment_invariants((task,), (condition_a, condition_b), paired=True)
        write_json(experiment / "experiment-plan.json", {
            "experimentId": None, "status": "ReadyForRealExecution", "kind": "PairedAB",
            "blockingGate": "OMP_EVALS_REAL_PROVIDER is not 1",
            "seed": SEED, "trialsPerCondition": 3,
            "conditionFingerprints": [condition_a.fingerprint, condition_b.fingerprint],
            "order": [
                {"ordinal": item.ordinal, "conditionFingerprint": item.condition_fingerprint,
                 "repetitionIndex": item.repetition_index, "trialId": None}
                for item in order
            ],
            "invariants": invariants,
        })
        write_json(experiment / "trial-index.json", {
            "status": "ReadyForRealExecution", "plannedTrials": [
                {"ordinal": item.ordinal, "conditionFingerprint": item.condition_fingerprint,
                 "repetitionIndex": item.repetition_index, "trialId": None}
                for item in order
            ], "completedTrials": [],
        })
        for name, content in {
            "aggregate-result.json": {"status": "Unavailable", "reason": "paid paired trials not executed"},
            "mechanism-analysis.json": {"status": "PreflightOnly", "metric": "MissingRequiredColon Trial Rate", "a2": None, "b2": None},
            "failure-analysis.json": {"status": "Unavailable", "strictFailures": []},
            "decision.json": {
                "version": "1", "decision": "Inconclusive",
                "productCorrectnessDecision": "KeepAlignedContract",
                "reason": "deterministic isolation and contract gates passed; paid paired trials await explicit opt-in",
                "supersedes": None,
            },
        }.items():
            write_json(experiment / name, content)
        write_json(experiment / "manifest.json", {
            "experimentId": "EXP-001R-edit-aci-model-contract-alignment",
            "version": "1", "status": "ReadyForRealExecution",
            "blockingGate": "OMP_EVALS_REAL_PROVIDER is not 1",
            "parentExperiment": "EXP-001-edit-aci-contract-alignment",
            "taskFingerprint": task.task_fingerprint,
            "conditionFingerprints": [condition_a.fingerprint, condition_b.fingerprint],
            "independentVariable": "EditModelContract",
            "primaryMechanismMetric": "MissingRequiredColon Trial Rate",
            "primaryTaskMetric": "Strict Pass Rate",
            "trialsPerCondition": 3, "seed": SEED,
            "offlineProof": {
                "modelCalls": 0, "agentTrials": 0,
                "graderExecutions": 0, "candidateMutations": 0,
            },
        })
    if immutable_exp001_hashes(original_exp) != original_hashes:
        raise RuntimeError("EXP-001 immutable artifacts changed during EXP-001R preparation")
    return 0


def copy_source(source: Path, target: Path) -> None:
    shutil.copytree(source, target, ignore=shutil.ignore_patterns(
        ".git", "target", "__pycache__", ".agent-state", ".mypy_cache", ".pytest_cache",
    ))


def apply_contract(root: Path, descriptor: str, error: str) -> None:
    tools = root / "agent_product/src/tools.cj"
    value = tools.read_text()
    if value.count(CURRENT_DESCRIPTOR) != 1:
        raise RuntimeError("current edit descriptor source did not match exactly once")
    tools.write_text(value.replace(CURRENT_DESCRIPTOR, descriptor))
    hashline = root / "agent_product/src/hashline.cj"
    value = hashline.read_text()
    if value.count(CURRENT_ERROR) != 1:
        raise RuntimeError("current edit recovery source did not match exactly once")
    hashline.write_text(value.replace(CURRENT_ERROR, error))


def build(root: Path, original_source: Path, sdk_root: Path) -> None:
    environment = os.environ.copy()
    environment["CANGJIE_SDK_ROOT"] = str(sdk_root)
    pinned = original_source / "scripts/pinned_cangjie"
    subprocess.run([str(pinned), "cjpm", "build"], cwd=root, env=environment, check=True)
    subprocess.run(
        [str(pinned), "cjpm", "build"],
        cwd=root / "support_tests/omp_evals_causal_preflight_driver",
        env=environment, check=True,
    )


def implementation_digests(root: Path, descriptor: str, error: str) -> dict[str, str]:
    tools = (root / "agent_product/src/tools.cj").read_text()
    hashline = (root / "agent_product/src/hashline.cj").read_text()
    masked_tools = tools.replace(descriptor, "<EDIT_MODEL_DESCRIPTOR>")
    masked_hashline = hashline.replace(error, "<EDIT_RECOVERY_CONTRACT>")
    local = (root / "agent_product/src/local_infrastructure.cj").read_text()
    schema = 'objectSchema([schemaProperty("input", "string")], ["input"])'
    return {
        "parserDigest": hash_json({"hashlineWithoutRecovery": masked_hashline}),
        "applicationDigest": hash_json({
            "hashlineWithoutRecovery": masked_hashline,
            "toolsWithoutDescriptor": masked_tools,
            "localWorkspace": local,
        }),
        "toolSchemaDigest": hash_json(schema),
        "editModelContractDigest": hash_json({"descriptor": descriptor, "recovery": error}),
    }


def compare_sources(a2: Path, b2: Path) -> tuple[list[str], str]:
    files_a = source_hashes(a2)
    files_b = source_hashes(b2)
    changed = sorted(path for path in set(files_a) | set(files_b) if files_a.get(path) != files_b.get(path))
    diffs = []
    for path in changed:
        a = (a2 / path).read_text().splitlines(keepends=True)
        b = (b2 / path).read_text().splitlines(keepends=True)
        diffs.extend(difflib.unified_diff(a, b, f"a2/{path}", f"b2/{path}"))
    return changed, "".join(diffs)


def source_hashes(root: Path) -> dict[str, str]:
    result = {}
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if not path.is_file() or "target" in relative.parts or "__pycache__" in relative.parts:
            continue
        result[relative.as_posix()] = hash_file(path)
    return result


def relevant_state_digest(source: Path) -> str:
    return hash_json({path: hash_file(source / path) for path in (
        "agent_product/src/tools.cj", "agent_product/src/hashline.cj",
        "agent_product/src/local_infrastructure.cj", "agent_product/cjpm.toml",
    )})


def contract_manifest(name: str, aligned: bool) -> dict:
    return {
        "version": f"exp-001r-{name.lower()}-v1",
        "independentVariable": "EditModelContract",
        "rangeParser": "N..=M",
        "parserRequiresColonFor": ["SWAP", "INS.HEAD", "INS.TAIL", "INS.PRE", "INS.POST"],
        "modelContractShowsRequiredColon": aligned,
        "errorRecoveryShowsRequiredColon": aligned,
        "application": "hashline anchored atomic local mutation",
        "historicalBinaryEquivalent": False,
    }


def condition_artifact(condition, binary_ref, driver_ref, contract, digests, note):
    return {
        "id": condition.id, "fingerprint": condition.fingerprint,
        "agentBinaryDigest": condition.manifest["agentBinaryDigest"],
        "agentBinaryArtifactRef": binary_ref, "replayDriverArtifactRef": driver_ref,
        "manifest": condition.manifest, "editAciContract": contract,
        "sourceDigests": digests, "note": note,
    }


def artifact_path(root: Path, reference: str) -> Path:
    digest = reference[7:]
    return (root / digest[:2] / digest[2:]).resolve()


def immutable_exp001_hashes(root: Path) -> dict[str, str]:
    return {path.name: hash_file(path) for path in sorted(root.glob("*.json"))}


def git_head(source: Path) -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=source, text=True, capture_output=True, check=True,
    ).stdout.strip()


def write_json(path: Path, value) -> None:
    path.write_bytes(json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True).encode() + b"\n")


if __name__ == "__main__":
    raise SystemExit(main())
