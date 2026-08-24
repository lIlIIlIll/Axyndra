from __future__ import annotations

import copy
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Mapping

from .grading import GradingEngine, bundle_fingerprint
from .model import (
    AgentTaskView, CacheMode, CachePolicy, CapabilityTag, GraderStatus,
    QualifiedEvalTask, ResourcePolicy, SuiteKind, TaskCategory, TaskLifecycle, jsonable,
)
from .storage import ArtifactStore
from .util import hash_json
from .workspace import manifest_and_digest


class QualificationFailure(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def load_draft_task(path: Path) -> tuple[dict[str, Any], Path]:
    task_path = path / "task.json" if path.is_dir() else path
    value = json.loads(task_path.read_text())
    if not isinstance(value, dict):
        raise QualificationFailure("FixtureInvalid", "task.json must contain an object")
    return value, task_path.parent.resolve()


def qualify_task(path: Path, engine: GradingEngine) -> tuple[dict[str, Any], dict[str, Any]]:
    draft, root = load_draft_task(path)
    _validate_draft(draft, root)
    fixture = (root / draft["fixture"]).resolve()
    grader_bundle = (root / draft["graderBundle"]).resolve()
    graders = tuple(_normalized_grader(item) for item in draft["graders"])
    _, fixture_digest = manifest_and_digest(fixture)
    qualification_results: dict[str, Any] = {}
    with tempfile.TemporaryDirectory(prefix="omp-evals-qualify-") as temporary:
        temp = Path(temporary)
        baseline = temp / "baseline"
        no_op = temp / "no-op"
        reference = temp / "reference"
        shutil.copytree(fixture, baseline)
        shutil.copytree(fixture, no_op)
        shutil.copytree(fixture, reference)
        targeted = [item for item in graders if item.get("qualificationRole") == "targeted"]
        if not targeted:
            raise QualificationFailure("GraderInvalid", "at least one targeted grader is required")
        baseline_run = engine.grade("qualification-baseline", baseline, grader_bundle, targeted)
        qualification_results["baseline"] = _summary(baseline_run.grader_results)
        if any(item.status == GraderStatus.ERROR for item in baseline_run.grader_results):
            raise QualificationFailure("GraderInvalid", "targeted grader infrastructure failed on baseline")
        if any(item.status == GraderStatus.PASS for item in baseline_run.grader_results):
            raise QualificationFailure("BaselineDoesNotFail", "baseline targeted grader unexpectedly passed")
        no_op_run = engine.grade("qualification-no-op", no_op, grader_bundle, targeted)
        qualification_results["noOp"] = _summary(no_op_run.grader_results)
        if any(item.status == GraderStatus.ERROR for item in no_op_run.grader_results):
            raise QualificationFailure("GraderInvalid", "targeted grader infrastructure failed on no-op")
        if any(item.status == GraderStatus.PASS for item in no_op_run.grader_results):
            raise QualificationFailure("NoOpUnexpectedlyPasses", "no-op targeted grader unexpectedly passed")
        patch_path = (root / draft["referencePatch"]).resolve()
        applied = subprocess.run(
            ["patch", "-p1", "-i", str(patch_path)], cwd=reference,
            text=True, capture_output=True,
        )
        if applied.returncode != 0:
            raise QualificationFailure("FixtureInvalid", f"reference patch did not apply: {applied.stderr}")
        reference_run = engine.grade("qualification-reference", reference, grader_bundle, graders)
        qualification_results["reference"] = _summary(reference_run.grader_results)
        if any(item.status == GraderStatus.ERROR for item in reference_run.grader_results):
            raise QualificationFailure("GraderInvalid", "grader infrastructure failed on reference")
        if any(item.status != GraderStatus.PASS for item in reference_run.grader_results):
            raise QualificationFailure("ReferenceDoesNotPass", "reference did not pass every grader")
        qualification_results["leakage"] = _leakage_qualification(draft, root)
        portable_store = ArtifactStore(temp / "portable-cas")
        reference_artifact = portable_store.put_directory(reference)
        reference_manifest, reference_digest = manifest_and_digest(reference)
        shutil.rmtree(reference)
        portable_v1 = temp / "portable-v1"
        portable_store.extract_directory(reference_artifact, portable_v1)
        portable_v1_run = engine.grade("qualification-portable-v1", portable_v1, grader_bundle, graders)
        if any(item.status != GraderStatus.PASS for item in portable_v1_run.grader_results):
            raise QualificationFailure("PortableRegradeFailed", "restored reference failed grader bundle v1")
        equivalent_name = draft.get("semanticEquivalentGraderBundle")
        if not equivalent_name:
            raise QualificationFailure(
                "PortableGraderMissing", "semanticEquivalentGraderBundle is required for portable regrade qualification"
            )
        equivalent_bundle = (root / str(equivalent_name)).resolve()
        equivalent_config = json.loads((equivalent_bundle / "bundle.json").read_text())
        equivalent_graders = tuple(_normalized_grader(item) for item in equivalent_config["graders"])
        portable_v2 = temp / "portable-v2"
        portable_store.extract_directory(reference_artifact, portable_v2)
        portable_v2_run = engine.grade(
            "qualification-portable-v2", portable_v2, equivalent_bundle, equivalent_graders,
            int(equivalent_config.get("processLimit", 128)),
        )
        if any(item.status != GraderStatus.PASS for item in portable_v2_run.grader_results):
            raise QualificationFailure("PortableRegradeFailed", "restored reference failed semantic-equivalent graders")
        restored_manifest, restored_digest = manifest_and_digest(portable_v2)
        if reference_manifest != restored_manifest or reference_digest != restored_digest:
            raise QualificationFailure("ArtifactIntegrityFailed", "reference CAS restore changed workspace content")
        qualification_results["portableRegrade"] = {
            "workspaceArtifactRef": reference_artifact,
            "workspaceDigest": reference_digest,
            "sourceWorkspaceDestroyed": True,
            "v1": _summary(portable_v1_run.grader_results),
            "v2": _summary(portable_v2_run.grader_results),
            "artifactIntegrity": "Pass",
        }
    task_body = copy.deepcopy(draft)
    task_body["graders"] = list(graders)
    task_body.pop("lifecycle", None)
    task_body["fixtureDigest"] = fixture_digest
    task_body["bundleRoot"] = "."
    task_body["graderBundleFingerprint"] = bundle_fingerprint(grader_bundle, graders)
    task_body["semanticEquivalentGraderBundleFingerprint"] = bundle_fingerprint(
        equivalent_bundle, equivalent_graders
    )
    task_body["referencePatchDigest"] = hashlib.sha256(patch_path.read_bytes()).hexdigest()
    task_fingerprint = hash_json(task_body)
    qualification = {
        "status": "Qualified", "checks": qualification_results,
        "taskFingerprint": task_fingerprint,
        "qualificationFingerprint": hash_json(qualification_results),
    }
    qualified = copy.deepcopy(task_body)
    qualified["lifecycle"] = TaskLifecycle.QUALIFIED.value
    qualified["taskFingerprint"] = task_fingerprint
    qualified["qualification"] = qualification
    return qualified, qualification


def parse_qualified_task(path: Path) -> QualifiedEvalTask:
    value = json.loads(path.read_text())
    qualification = value.get("qualification", {})
    if qualification.get("status") != "Qualified":
        raise QualificationFailure("TaskNotQualified", "formal runner accepts only QualifiedEvalTask")
    expected = value.get("taskFingerprint", "")
    task_body = {
        key: item for key, item in value.items()
        if key not in ("taskFingerprint", "qualification", "lifecycle")
    }
    if hash_json(task_body) != expected or qualification.get("taskFingerprint") != expected:
        raise QualificationFailure("QualificationStale", "qualified task fingerprint does not match task contents")
    resource = value.get("resourcePolicy", {})
    cache = value.get("cachePolicy", {})
    return QualifiedEvalTask(
        id=value["id"], version=value["version"], category=value["category"],
        prompt=value["prompt"], fixture=value["fixture"], fixture_digest=value["fixtureDigest"],
        base_revision=value.get("baseRevision", ""),
        visible_constraints=tuple(value.get("visibleConstraints", [])),
        resource_policy=ResourcePolicy(
            cpu_guaranteed=resource.get("cpuGuaranteed"), cpu_limit=resource.get("cpuLimit"),
            memory_guaranteed_bytes=resource.get("memoryGuaranteed"),
            memory_limit_bytes=resource.get("memoryLimit"), disk_limit_bytes=resource.get("diskLimit"),
            process_limit=int(resource.get("processLimit", 128)),
            agent_wall_time_seconds=float(resource.get("agentWallTime", 900)),
            quiesce_time_seconds=float(resource.get("quiesceTime", 10)),
            grader_time_seconds=float(resource.get("graderTime", 300)),
            cleanup_time_seconds=float(resource.get("cleanupTime", 10)),
            model_call_limit=resource.get("modelCallLimit"),
            tool_call_limit=resource.get("toolCallLimit"),
            input_token_limit=resource.get("inputTokenLimit"),
            cost_limit_micros=resource.get("costLimitMicros"),
        ),
        cache_policy=CachePolicy(
            CacheMode(cache.get("dependencyCache", "Isolated")),
            CacheMode(cache.get("buildCache", "Isolated")),
            CacheMode(cache.get("agentCache", "Cold")),
        ),
        network_policy=value.get("networkPolicy", "Denied"), graders=tuple(value["graders"]),
        grader_bundle=value["graderBundle"],
        task_fingerprint=expected,
        qualification_fingerprint=qualification["qualificationFingerprint"],
        bundle_root=str((path.parent / value["bundleRoot"]).resolve()), agent=value.get("agent", {}),
        lifecycle=TaskLifecycle(value.get("lifecycle", "Qualified")),
        capabilities=tuple(CapabilityTag(item) for item in value.get("capabilities", [])),
        benchmark_kind=SuiteKind(value.get("benchmarkKind", "Capability")),
        semantic_equivalent_grader_bundle=value.get("semanticEquivalentGraderBundle"),
    )


def _validate_draft(value: Mapping[str, Any], root: Path) -> None:
    for name in ("id", "version", "category", "prompt", "fixture", "graderBundle", "referencePatch", "graders"):
        if name not in value:
            raise QualificationFailure("FixtureInvalid", f"missing task field: {name}")
    for name in ("fixture", "graderBundle", "referencePatch", "semanticEquivalentGraderBundle"):
        if name not in value:
            continue
        path = (root / str(value[name])).resolve()
        if root not in (path, *path.parents) or not path.exists():
            raise QualificationFailure("FixtureInvalid", f"invalid task path: {name}")
    _task_category(value["category"])
    for item in value.get("capabilities", []):
        CapabilityTag(item)
    lifecycle = TaskLifecycle(value.get("lifecycle", "Draft"))
    if lifecycle not in (TaskLifecycle.DRAFT, TaskLifecycle.QUALIFIED):
        raise QualificationFailure("FixtureInvalid", "draft task lifecycle must be Draft or Qualified")


def _summary(results: tuple) -> list[dict[str, str]]:
    return [
        {"graderId": item.grader_id, "status": item.status.value,
         "outcome": item.outcome_requirement.value, "version": item.grader_version}
        for item in results
    ]


def _task_category(value: str) -> TaskCategory:
    aliases = {"bugfix": "BugFix", "feature": "Feature", "refactor": "Refactor",
               "investigation": "Investigation", "performance": "Performance"}
    return TaskCategory(aliases.get(value, value))


def _normalized_grader(spec: Mapping[str, Any]) -> dict[str, Any]:
    value = copy.deepcopy(dict(spec))
    if "outcome" not in value:
        kind = str(value.get("type", "CommandGrader"))
        grader_id = str(value.get("id", "")).lower()
        if value.get("qualificationRole") == "targeted" or "targeted" in grader_id:
            value["outcome"] = "TargetedBehavior"
        elif kind == "RegressionGrader" or "regression" in grader_id:
            value["outcome"] = "Regression"
        elif kind in ("FileStateGrader", "NoGeneratedArtifactGrader") or "artifact" in grader_id:
            value["outcome"] = "ArtifactIntegrity"
        else:
            value["outcome"] = "HardConstraints"
    return value


def _leakage_qualification(draft: Mapping[str, Any], root: Path) -> dict[str, Any]:
    view = AgentTaskView(
        prompt=str(draft["prompt"]),
        visible_constraints=tuple(str(item) for item in draft.get("visibleConstraints", [])),
        metadata={"id": str(draft["id"]), "version": str(draft["version"]),
                  "category": _task_category(str(draft["category"])).value},
    )
    public = json.dumps(jsonable(view), sort_keys=True, ensure_ascii=False)
    private_paths = [str(draft["referencePatch"]), str(draft["graderBundle"])]
    if draft.get("semanticEquivalentGraderBundle"):
        private_paths.append(str(draft["semanticEquivalentGraderBundle"]))
    for private_path in private_paths:
        if private_path and private_path in public:
            raise QualificationFailure("LeakageDetected", f"AgentTaskView exposes private path: {private_path}")
    private_contents: list[str] = []
    for name in private_paths:
        path = (root / name).resolve()
        files = [path] if path.is_file() else [item for item in path.rglob("*") if item.is_file()]
        for item in files:
            try:
                text = item.read_text().strip()
            except UnicodeDecodeError:
                continue
            if len(text) >= 24:
                private_contents.append(text)
    if any(content in public for content in private_contents):
        raise QualificationFailure("LeakageDetected", "AgentTaskView contains private artifact content")
    agent_config = json.dumps(draft.get("agent", {}), sort_keys=True)
    if any(name in agent_config for name in private_paths):
        raise QualificationFailure("LeakageDetected", "Agent configuration references private task artifacts")
    return {
        "status": "Pass",
        "agentTaskView": jsonable(view),
        "privatePathsAbsent": True,
        "privateContentsAbsent": True,
        "agentConfigPrivatePathsAbsent": True,
        "runnerPayload": "AgentTaskView.prompt only",
        "fingerprintExposure": "sha256 digest only",
    }
