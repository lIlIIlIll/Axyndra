from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from omp_evals.edit_causal import EditSyntaxViolation, syntax_violation
from omp_evals.storage import ArtifactStore
from omp_evals.util import hash_file


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--artifact-store", type=Path, required=True)
    parser.add_argument("--pinned-cangjie", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    arguments = parser.parse_args()
    a = json.loads((arguments.experiment_dir / "condition-a2.json").read_text())
    b = json.loads((arguments.experiment_dir / "condition-b2.json").read_text())
    driver_a_artifact = materialize(arguments.artifact_store, a["replayDriverArtifactRef"])
    driver_b_artifact = materialize(arguments.artifact_store, b["replayDriverArtifactRef"])
    # Frozen task evidence and all historical reads identify the baseline tag as EC00.
    tag = "EC00"

    malformed = {
        "swapSingle": f"[src/midpoint.cj#{tag}]\nSWAP 5\n+    replacement",
        "swapRange": f"[src/midpoint.cj#{tag}]\nSWAP 4..=5\n+    replacement",
        "insertPost": f"[src/midpoint.cj#{tag}]\nINS.POST 4\n+    inserted",
    }
    valid = {
        "swapSingle": f"[src/midpoint.cj#{tag}]\nSWAP 5:\n+    replacement",
        "swapRange": f"[src/midpoint.cj#{tag}]\nSWAP 4..=5:\n+    replacement",
        "deleteSingle": f"[src/midpoint.cj#{tag}]\nDEL 5",
        "deleteRange": f"[src/midpoint.cj#{tag}]\nDEL 4..=5",
        "insertHead": f"[src/midpoint.cj#{tag}]\nINS.HEAD:\n+// head",
        "insertTail": f"[src/midpoint.cj#{tag}]\nINS.TAIL:\n+// tail",
        "insertPre": f"[src/midpoint.cj#{tag}]\nINS.PRE 5:\n+// pre",
        "insertPost": f"[src/midpoint.cj#{tag}]\nINS.POST 4:\n+// post",
    }
    verification = {
        "a2MalformedExamples": {}, "b2DocumentedExamples": {},
        "errorRecovery": {}, "securityScan": {},
    }
    with tempfile.TemporaryDirectory(prefix="exp001r-contract-") as temporary:
        temporary_root = Path(temporary)
        driver_a = executable_copy(driver_a_artifact, temporary_root / "driver-a")
        driver_b = executable_copy(driver_b_artifact, temporary_root / "driver-b")
        for name, payload in malformed.items():
            result_a = replay(payload, driver_a, arguments, temporary_root, f"a-{name}")
            result_b = replay(payload, driver_b, arguments, temporary_root, f"b-malformed-{name}")
            violation = syntax_violation(payload, error_code=result_a["errorCode"], error_message=result_a["errorMessage"])
            if result_a["outcome"] != "Rejected" or violation != EditSyntaxViolation.MISSING_REQUIRED_COLON:
                raise RuntimeError(f"A2 malformed example was not rejected as MissingRequiredColon: {name}")
            if result_b["outcome"] != "Rejected":
                raise RuntimeError(f"shared B2 parser unexpectedly accepts malformed command: {name}")
            verification["a2MalformedExamples"][name] = {
                **result_a, "syntaxViolation": violation.value,
            }
            verification["errorRecovery"][name] = {
                "a2": result_a["errorMessage"], "b2": result_b["errorMessage"],
                "a2ShowsRequiredColon": required_colon_visible(result_a["errorMessage"], name),
                "b2ShowsRequiredColon": required_colon_visible(result_b["errorMessage"], name),
            }
        for name, payload in valid.items():
            result = replay(payload, driver_b, arguments, temporary_root, f"b-valid-{name}")
            if result["outcome"] != "Accepted":
                raise RuntimeError(f"B2 documented command rejected: {name}: {result}")
            if syntax_violation(payload) == EditSyntaxViolation.MISSING_REQUIRED_COLON:
                raise RuntimeError(f"properly colonized command falsely flagged: {name}")
            verification["b2DocumentedExamples"][name] = result

    if any(value["a2ShowsRequiredColon"] for value in verification["errorRecovery"].values()):
        raise RuntimeError("A2 recovery unexpectedly shows required colon")
    if not all(value["b2ShowsRequiredColon"] for value in verification["errorRecovery"].values()):
        raise RuntimeError("B2 recovery omits required colon")
    forbidden = ("midpoint", "src/midpoint.cj", "left + right", "right / 2", "hidden test", "reference solution")
    for condition_name, condition in (("A2", a), ("B2", b)):
        source = json.dumps(condition["editAciContract"], sort_keys=True).lower()
        found = [value for value in forbidden if value in source]
        if found:
            raise RuntimeError(f"benchmark-specific contract content in {condition_name}: {found}")
        verification["securityScan"][condition_name] = {"forbiddenTerms": found, "status": "Pass"}

    source_diff = json.loads((arguments.experiment_dir / "source-diff-manifest.json").read_text())
    checks = {
        "parserDigestEqual": a["manifest"]["parserDigest"] == b["manifest"]["parserDigest"],
        "applicationDigestEqual": a["manifest"]["applicationDigest"] == b["manifest"]["applicationDigest"],
        "toolSchemaDigestEqual": a["manifest"]["toolSchemaDigest"] == b["manifest"]["toolSchemaDigest"],
        "generalPromptDigestEqual": a["manifest"]["generalPromptDigest"] == b["manifest"]["generalPromptDigest"],
        "nonEditToolSetDigestEqual": a["manifest"]["nonEditToolSetDigest"] == b["manifest"]["nonEditToolSetDigest"],
        "budgetDigestEqual": a["manifest"]["budgetDigest"] == b["manifest"]["budgetDigest"],
        "editModelContractDigestDifferent": a["manifest"]["editModelContractDigest"] != b["manifest"]["editModelContractDigest"],
        "sourceDiffLimited": source_diff["changedFiles"] == ["agent_product/src/hashline.cj", "agent_product/src/tools.cj"],
    }
    if not all(checks.values()):
        raise RuntimeError(f"condition isolation failed: {checks}")
    verification["controlledVariableChecks"] = checks
    verification["status"] = "Pass"
    (arguments.experiment_dir / "deterministic-verification.json").write_text(
        json.dumps(verification, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    )
    return 0


def replay(payload: str, driver: Path, arguments, temporary_root: Path, label: str) -> dict:
    workspace = temporary_root / f"workspace-{label}"
    shutil.copytree(arguments.fixture, workspace)
    payload_path = temporary_root / f"payload-{label}.txt"
    payload_path.write_text(payload)
    environment = os.environ.copy()
    environment.update({
        "CANGJIE_SDK_ROOT": str(arguments.sdk_root),
        "EDIT_REPLAY_WORKSPACE": str(workspace),
        "EDIT_REPLAY_PAYLOAD_FILE": str(payload_path),
        "EDIT_REPLAY_PARSE_ONLY": "1",
    })
    completed = subprocess.run(
        [str(arguments.pinned_cangjie), str(driver)], cwd=arguments.pinned_cangjie.parent.parent,
        env=environment, text=True, capture_output=True, timeout=30,
    )
    parts = completed.stdout.strip().split("\t", 2)
    if completed.returncode == 0 and parts[0] == "ACCEPTED":
        return {"outcome": "Accepted", "errorCode": None, "errorMessage": None}
    if completed.returncode == 2 and len(parts) == 3 and parts[0] == "REJECT":
        return {"outcome": "Rejected", "errorCode": parts[1], "errorMessage": parts[2]}
    raise RuntimeError(f"unexpected replay rc={completed.returncode}: {completed.stdout!r} {completed.stderr!r}")


def required_colon_visible(message: str | None, name: str) -> bool:
    message = message or ""
    if name == "swapSingle":
        return "SWAP N:" in message
    if name == "swapRange":
        return "SWAP N..=M:" in message
    return "INS.POST N:" in message


def materialize(root: Path, reference: str) -> Path:
    digest = reference[7:]
    path = root / digest[:2] / digest[2:]
    if hash_file(path) != digest:
        raise RuntimeError(f"artifact digest mismatch: {reference}")
    return path


def executable_copy(source: Path, target: Path) -> Path:
    shutil.copy2(source, target)
    target.chmod(0o755)
    return target


if __name__ == "__main__":
    raise SystemExit(main())
