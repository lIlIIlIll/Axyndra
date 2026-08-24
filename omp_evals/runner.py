from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import replace
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence

from .grading import GradingEngine
from .metrics import derive_trajectory_metrics
from .model import (
    AgentTermination, AgentTrial, CandidateSnapshot, EvalResult, EvalVerdict,
    ExperimentalCondition, FailureClassification, GraderSeverity, GraderStatus,
    ProviderSettingsCompatibilityResult, QualifiedEvalTask, TrialPlan, TrialState,
    TrialValidity, jsonable,
)
from .storage import ArtifactStore, EvalDatabase
from .util import hash_json, host_fingerprint, new_id, utc_now
from .provider_execution import materialize_provider_settings
from .provider_settings import (
    materialize_provider_settings_closure, validate_provider_settings_closure,
)
from .worker import ProcessAgentWorker
from .worker import _settings_entry_excluded
from .workspace import WorkspaceMaterializer, manifest_and_digest, workspace_diff
from .runtime_closure import materialize_runtime_closure


class EvalRunner:
    def __init__(
        self, root: Path, worker: ProcessAgentWorker | None = None,
        grading: GradingEngine | None = None,
    ):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.artifacts = ArtifactStore(self.root / "artifacts")
        self.database = EvalDatabase(self.root / "evals.db")
        self.materializer = WorkspaceMaterializer(self.root / "trials")
        self.worker = worker or ProcessAgentWorker()
        self.grading = grading or GradingEngine()

    def close(self) -> None:
        self.database.close()

    def preflight_condition_runtime(self, condition: ExperimentalCondition):
        if condition.runtime_closure is None:
            from .model import ConditionRuntimeReadiness, RuntimeReadinessResult
            return RuntimeReadinessResult(
                readiness=ConditionRuntimeReadiness.UNVERIFIED, closure_digest="legacy-unverified",
                process_started=False, protocol_ready=False, clean_shutdown=False,
                residual_process=False, model_calls=0, provider_requests=0,
                diagnostics=("legacy binary-only condition has no frozen runtime closure",),
            )
        preflight_root = self.root / "condition-preflight"
        preflight_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="runtime-", dir=preflight_root) as temporary:
            temporary_root = Path(temporary)
            runtime = materialize_runtime_closure(
                condition.runtime_closure, self.artifacts, temporary_root / "condition",
                self._runtime_environment_sources(),
            )
            workspace = temporary_root / "workspace"
            omp_home = temporary_root / "omp-home"
            tmp = temporary_root / "tmp"
            for path in (workspace, omp_home, tmp):
                path.mkdir()
            result = self.worker.probe_startup(runtime, workspace, omp_home, tmp)
            closure_digest = str(
                condition.runtime_closure.get("closure_digest")
                or condition.runtime_closure.get("closureDigest") or ""
            )
            return replace(result, closure_digest=closure_digest)

    def preflight_condition_model_path_dynamic_link(self, condition: ExperimentalCondition):
        from .model import (
            ConditionRuntimeReadiness, ModelPathDynamicLinkReadiness,
            ModelPathDynamicLinkReadinessResult,
        )
        if condition.runtime_closure is None or condition.provider_settings_closure is None:
            return ModelPathDynamicLinkReadinessResult(
                readiness=ModelPathDynamicLinkReadiness.UNSUPPORTED,
                runtime_closure_digest="legacy-unfrozen", executable_digest="unsupported",
                executable_runtime_compatibility_digest=None,
                static_dependency_closure=False, symbol_version_validation=False,
                sandbox_process_started=False, model_path_initialized=False,
                protocol_ready=False, clean_shutdown=False, residual_process=False,
                provider_requests=0, model_calls=0, credential_reads=0,
                diagnostics=("condition lacks frozen runtime/provider settings closure",),
            )
        closure = condition.runtime_closure
        linkage = closure.get("linkage_validation") or closure.get("linkageValidation") or {}
        preflight_root = self.root / "condition-preflight"
        preflight_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="model-linkage-", dir=preflight_root) as raw:
            root = Path(raw)
            runtime = materialize_runtime_closure(
                closure, self.artifacts, root / "condition", self._runtime_environment_sources(),
            )
            runtime = replace(runtime, environment={**runtime.environment, "LD_BIND_NOW": "1"})
            workspace, omp_home, tmp = root / "workspace", root / "omp-home", root / "tmp"
            for path in (workspace, omp_home, tmp):
                path.mkdir()
            materialize_provider_settings_closure(
                condition.provider_settings_closure, self.artifacts, omp_home,
                condition.provider_execution_digest,
            )
            result = self.worker.probe_startup(
                runtime, workspace, omp_home, tmp,
                model=str(condition.agent.get("model", "")),
                extra_arguments=tuple(condition.agent.get("arguments", ())),
            )
        passed = (
            linkage.get("result") == "Pass"
            and linkage.get("requiredObjectsResolvable") is True
            and linkage.get("symbolVersionsResolvable") is True
            and result.readiness == ConditionRuntimeReadiness.READY
            and result.protocol_ready and result.clean_shutdown and not result.residual_process
        )
        return ModelPathDynamicLinkReadinessResult(
            readiness=(
                ModelPathDynamicLinkReadiness.PASS if passed
                else ModelPathDynamicLinkReadiness.FAIL
            ),
            runtime_closure_digest=str(closure.get("closure_digest") or closure.get("closureDigest")),
            executable_digest=str(closure.get("executable", {}).get("digest", "")),
            executable_runtime_compatibility_digest=(
                closure.get("executable_runtime_compatibility_digest")
                or closure.get("executableRuntimeCompatibilityDigest")
            ),
            static_dependency_closure=linkage.get("requiredObjectsResolvable") is True,
            symbol_version_validation=linkage.get("symbolVersionsResolvable") is True,
            sandbox_process_started=result.process_started,
            model_path_initialized=result.protocol_ready and bool(result.protocol_facts.get("effectiveModel")),
            protocol_ready=result.protocol_ready, clean_shutdown=result.clean_shutdown,
            residual_process=result.residual_process, provider_requests=0, model_calls=0,
            credential_reads=0, diagnostics=result.diagnostics,
            evidence={"staticLinkage": linkage, "protocolFacts": result.protocol_facts,
                      "networkPolicy": "Denied", "ldBindNow": True},
        )

    def preflight_condition_tool_execution(self, condition: ExperimentalCondition):
        from .model import ToolExecutionPlaneReadinessResult, ToolSandboxReadiness
        if condition.runtime_closure is None:
            return ToolExecutionPlaneReadinessResult(
                readiness=ToolSandboxReadiness.UNVERIFIED, process_started=False,
                protocol_ready=False, workspace_process_ready=False,
                readonly_shell_ready=False, clean_shutdown=False,
                residual_process=False, model_calls=0, provider_requests=0,
                diagnostics=("legacy binary-only condition has no frozen runtime closure",),
            )
        preflight_root = self.root / "condition-preflight"
        preflight_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="tool-plane-", dir=preflight_root) as temporary:
            temporary_root = Path(temporary)
            runtime = materialize_runtime_closure(
                condition.runtime_closure, self.artifacts, temporary_root / "condition",
                self._runtime_environment_sources(),
            )
            workspace = temporary_root / "workspace"
            omp_home = temporary_root / "omp-home"
            tmp = temporary_root / "tmp"
            for path in (workspace, omp_home, tmp):
                path.mkdir()
            if condition.provider_settings_closure is not None:
                materialize_provider_settings_closure(
                    condition.provider_settings_closure, self.artifacts, omp_home,
                    condition.provider_execution_digest,
                )
            (workspace / "readiness-probe.txt").write_text("tool-plane-ready\n")
            _, before = manifest_and_digest(workspace)
            result = self.worker.probe_tool_execution_plane(
                runtime, workspace, omp_home, tmp,
                model=str(condition.agent.get("model", "")),
                extra_arguments=tuple(condition.agent.get("arguments", ())),
            )
            _, after = manifest_and_digest(workspace)
            if before != after:
                return replace(
                    result, readiness=ToolSandboxReadiness.INVALID,
                    diagnostics=(*result.diagnostics, "tool readiness probe mutated workspace"),
                )
            return result

    def preflight_condition_provider_settings(
        self, condition: ExperimentalCondition,
    ) -> ProviderSettingsCompatibilityResult:
        from .model import ConditionRuntimeReadiness
        if condition.runtime_closure is None or condition.provider_execution_spec is None or (
            condition.provider_settings_closure is None
        ):
            return ProviderSettingsCompatibilityResult(
                readiness=ConditionRuntimeReadiness.UNVERIFIED,
                provider_execution_digest=condition.provider_execution_digest or "legacy-unfrozen",
                provider_settings_closure_digest=(
                    condition.provider_settings_closure_digest or "legacy-unfrozen"
                ),
                settings_materialized=False, referential_integrity=False,
                process_started=False, protocol_ready=False, get_state_ready=False,
                clean_shutdown=False, residual_process=False, model_calls=0,
                provider_requests=0,
                diagnostics=("condition has no frozen ProviderSettingsClosure",),
            )
        preflight_root = self.root / "condition-preflight"
        preflight_root.mkdir(exist_ok=True)
        diagnostics: list[str] = []
        settings_materialized = False
        referential_integrity = False
        result = None
        loaded_structure: Mapping[str, Any] = {}
        with tempfile.TemporaryDirectory(prefix="provider-settings-", dir=preflight_root) as raw:
            temporary_root = Path(raw)
            runtime = materialize_runtime_closure(
                condition.runtime_closure, self.artifacts, temporary_root / "condition",
                self._runtime_environment_sources(),
            )
            workspace = temporary_root / "workspace"
            omp_home = temporary_root / "omp-home"
            tmp = temporary_root / "tmp"
            for path in (workspace, omp_home, tmp):
                path.mkdir()
            try:
                validate_provider_settings_closure(
                    condition.provider_settings_closure, condition.provider_execution_digest,
                )
                referential_integrity = True
                loaded_structure = materialize_provider_settings_closure(
                    condition.provider_settings_closure, self.artifacts, omp_home,
                    condition.provider_execution_digest,
                )
                settings_materialized = True
                result = self.worker.probe_startup(
                    runtime, workspace, omp_home, tmp,
                    model=str(condition.agent.get("model", "")),
                    extra_arguments=tuple(condition.agent.get("arguments", ())),
                )
            except Exception as error:
                diagnostics.append(str(error))
        if result is not None:
            diagnostics.extend(result.diagnostics)
        expected_model = str(condition.agent.get("model", ""))
        effective_model = (
            result.protocol_facts.get("effectiveModel") if result is not None else None
        )
        spec = condition.provider_execution_spec
        capabilities = spec.get("capabilities", {}) if spec is not None else {}
        model_matches = isinstance(effective_model, Mapping) and (
            effective_model.get("provider") == spec.get("adapterIdentity")
            and effective_model.get("id") == spec.get("wireModel")
            and effective_model.get("contextWindow") == capabilities.get("contextWindowTokens")
            and effective_model.get("maxTokens") == capabilities.get("maxOutputTokens")
            and effective_model.get("reasoning") == capabilities.get("reasoning")
        )
        if result is not None and result.protocol_ready and not model_matches:
            diagnostics.append("product-loaded model does not match the frozen condition model")
        ready = (
            result is not None and result.readiness == ConditionRuntimeReadiness.READY
            and settings_materialized and referential_integrity and model_matches
        )
        return ProviderSettingsCompatibilityResult(
            readiness=(
                ConditionRuntimeReadiness.READY if ready else ConditionRuntimeReadiness.INVALID
            ),
            provider_execution_digest=condition.provider_execution_digest or "",
            provider_settings_closure_digest=condition.provider_settings_closure_digest or "",
            settings_materialized=settings_materialized,
            referential_integrity=referential_integrity,
            process_started=result.process_started if result is not None else False,
            protocol_ready=result.protocol_ready if result is not None else False,
            get_state_ready=effective_model is not None,
            clean_shutdown=result.clean_shutdown if result is not None else False,
            residual_process=result.residual_process if result is not None else False,
            model_calls=0, provider_requests=0,
            diagnostics=tuple(diagnostics),
            probe_facts={
                "effectiveModel": effective_model,
                "expectedModel": expected_model,
                "providerExecutionSpec": {
                    key: condition.provider_execution_spec.get(key)
                    for key in ("adapterIdentity", "protocol", "endpoint", "wireModel", "timeoutMillis")
                },
                "loadedSemanticProjection": loaded_structure.get("semanticProjection", {}),
            },
        )

    @staticmethod
    def _runtime_environment_sources() -> Mapping[str, Path]:
        sdk = os.environ.get("CANGJIE_HOME") or os.environ.get("CANGJIE_SDK_ROOT")
        return {"CangjieSDK": Path(sdk).resolve()} if sdk else {}

    def run(
        self, task: QualifiedEvalTask, omp_binary: Path,
        settings_source: Optional[Path] = None, repetition_index: int = 0,
        condition: Optional[ExperimentalCondition] = None,
        experiment_id: Optional[str] = None,
    ) -> tuple[AgentTrial, CandidateSnapshot, Any, EvalResult]:
        trial_id = new_id("trial")
        fixture = (Path(task.bundle_root) / task.fixture).resolve()
        environment = host_fingerprint(omp_binary)
        settings_fingerprint = _settings_fingerprint(settings_source)
        agent_spec = condition.agent if condition else task.agent
        agent_environment = {str(k): str(v) for k, v in agent_spec.get("environment", {}).items()}
        for name in agent_spec.get("inheritEnvironment", []):
            if name in os.environ:
                agent_environment[str(name)] = os.environ[str(name)]
        environment_fingerprint_values = {
            name: hash_json(value) for name, value in agent_environment.items()
        }
        agent_fingerprint = hash_json({
            "binary": environment["ompBinarySha256"], "model": agent_spec.get("model", ""),
            "arguments": agent_spec.get("arguments", []), "settings": settings_fingerprint,
            "tools": agent_spec.get("tools", []), "skills": agent_spec.get("skills", []),
            "environment": environment_fingerprint_values,
        })
        if condition:
            agent_fingerprint = condition.fingerprint
            condition_ref = self.artifacts.put_json(condition.manifest)
            self.database.save_condition(jsonable(condition))
        else:
            condition_ref = self.artifacts.put_json({"legacyAgentFingerprintInput": agent_fingerprint})
        plan = TrialPlan(
            trial_id=trial_id, task_fingerprint=task.task_fingerprint,
            agent_fingerprint=agent_fingerprint,
            environment_fingerprint=hash_json(environment), repetition_index=repetition_index,
            resource_policy=task.resource_policy, cache_policy=task.cache_policy,
            network_policy=task.network_policy,
            timeout_policy={"agent": task.resource_policy.agent_wall_time_seconds,
                            "quiesce": task.resource_policy.quiesce_time_seconds,
                            "grader": task.resource_policy.grader_time_seconds},
            capture_policy={"trajectory": "canonical-jsonl", "workspace": "full", "stderr": True},
            created_at=utc_now(),
            condition_id=condition.id if condition else "default",
            condition_fingerprint=condition.fingerprint if condition else agent_fingerprint,
            experiment_id=experiment_id, condition_manifest_ref=condition_ref,
        )
        self.database.save_plan(trial_id, jsonable(plan))
        self.database.record_state(trial_id, TrialState.CREATED.value)
        started = utc_now()
        self.database.record_state(trial_id, TrialState.MATERIALIZING.value)
        try:
            _, current_fixture_digest = manifest_and_digest(fixture)
            if current_fixture_digest != task.fixture_digest:
                raise RuntimeError("qualified fixture digest changed")
        except Exception as error:
            self._invalid(plan, started, TrialValidity.INVALID_FIXTURE, str(error), AgentTermination.NOT_STARTED)
            raise InvalidTrialError(trial_id, TrialValidity.INVALID_FIXTURE, str(error)) from error
        try:
            directories = self.materializer.materialize(trial_id, fixture)
        except Exception as error:
            self._invalid(plan, started, TrialValidity.INVALID_INFRASTRUCTURE, str(error), AgentTermination.NOT_STARTED)
            raise InvalidTrialError(trial_id, TrialValidity.INVALID_INFRASTRUCTURE, str(error)) from error
        self.database.record_state(trial_id, TrialState.PREFLIGHT.value)
        runtime = None
        if condition and condition.runtime_closure is not None:
            try:
                runtime = materialize_runtime_closure(
                    condition.runtime_closure, self.artifacts, directories.root / "runtime",
                    self._runtime_environment_sources(),
                )
            except Exception as error:
                self._invalid(plan, started, TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE,
                              str(error), AgentTermination.NOT_STARTED)
                raise InvalidTrialError(
                    trial_id, TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE, str(error)
                ) from error
        self.database.record_state(trial_id, TrialState.RUNNING_AGENT.value)
        try:
            execution_settings_source = settings_source
            if condition and condition.provider_settings_closure is not None:
                execution_settings_source = directories.root / "frozen-provider-settings"
                materialize_provider_settings_closure(
                    condition.provider_settings_closure, self.artifacts,
                    execution_settings_source, condition.provider_execution_digest,
                )
            elif condition and condition.provider_execution_spec is not None:
                execution_settings_source = directories.root / "frozen-provider-settings"
                materialize_provider_settings(
                    condition.provider_execution_spec,
                    execution_settings_source,
                    str(condition.manifest.get("frozenProviderProfileId", "frozen-provider")),
                )
            worker_result = self.worker.run(
                omp_binary, directories.workspace, directories.omp_home, directories.tmp, directories.logs,
                task.agent_view().prompt, str(agent_spec.get("model", "")), tuple(agent_spec.get("arguments", [])),
                agent_environment,
                task.resource_policy.agent_wall_time_seconds, task.resource_policy.quiesce_time_seconds,
                settings_source=execution_settings_source,
                network_policy=task.network_policy,
                phase_callback=lambda state: self.database.record_state(trial_id, state),
                runtime=runtime,
            )
            if worker_result.infrastructure_failure is not None:
                diagnostic = "typed worker infrastructure failure: " + worker_result.infrastructure_failure
                self._invalid(
                    plan, started, TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE,
                    diagnostic, worker_result.termination,
                )
                raise InvalidTrialError(
                    trial_id, TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE, diagnostic,
                )
            if condition and condition.provider_settings_closure is not None and (
                not worker_result.startup_ready
            ):
                diagnostic = (
                    "condition startup infrastructure failure before RPC ready: "
                    + "; ".join(worker_result.diagnostics)
                )
                self._invalid(
                    plan, started, TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE,
                    diagnostic, worker_result.termination,
                )
                raise InvalidTrialError(
                    trial_id, TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE, diagnostic,
                )
        except InvalidTrialError:
            raise
        except Exception as error:
            self._invalid(plan, started, TrialValidity.INVALID_INFRASTRUCTURE, str(error), AgentTermination.NOT_STARTED)
            raise InvalidTrialError(trial_id, TrialValidity.INVALID_INFRASTRUCTURE, str(error)) from error
        self.database.record_state(trial_id, TrialState.SNAPSHOTTING.value)
        try:
            trajectory_text = "\n".join(json.dumps(frame, separators=(",", ":")) for frame in worker_result.frames) + "\n"
            manifest, final_digest = manifest_and_digest(directories.workspace)
            diff = workspace_diff(fixture, directories.workspace)
            trajectory_ref = self.artifacts.put_text(trajectory_text)
            manifest_ref = self.artifacts.put_json(manifest)
            diff_ref = self.artifacts.put_text(diff)
            final_answer_ref = self.artifacts.put_text(worker_result.final_answer)
            transcript_ref = self.artifacts.put_json({
                "prompt": task.prompt,
                "finalAnswer": worker_result.final_answer,
                "events": [frame for frame in worker_result.frames if frame.get("type") == "agent_event"],
                "usage": worker_result.usage,
            })
            workspace_ref = self.artifacts.put_directory(directories.workspace)
            self.materializer.freeze(directories.workspace)
        except Exception as error:
            self._invalid(plan, started, TrialValidity.INVALID_RUNNER, str(error), worker_result.termination)
            raise InvalidTrialError(trial_id, TrialValidity.INVALID_RUNNER, str(error)) from error
        candidate = CandidateSnapshot(
            id=new_id("candidate"), trial_id=trial_id,
            base_fixture_digest=task.fixture_digest, final_workspace_digest=final_digest,
            workspace_artifact_ref=workspace_ref, diff_ref=diff_ref,
            filesystem_manifest_ref=manifest_ref, transcript_ref=transcript_ref,
            trajectory_ref=trajectory_ref,
            operation_refs=tuple(_operation_refs(self.artifacts, worker_result.frames)),
            final_answer_ref=final_answer_ref,
            runtime_log_ref=self.artifacts.put_directory(directories.logs),
            usage=dict(worker_result.usage),
            agent_termination=worker_result.termination,
            runtime_diagnostics=worker_result.diagnostics, created_at=utc_now(),
        )
        self.database.save_candidate(candidate)
        try:
            # The CAS snapshot is now the sole candidate authority.  Remove all
            # writable Agent state before a hidden grader process can exist.
            self.materializer.destroy_frozen(directories.workspace)
            shutil.rmtree(directories.omp_home)
            shutil.rmtree(directories.tmp)
            shutil.rmtree(directories.build)
            if runtime is not None:
                shutil.rmtree(runtime.root)
        except Exception as error:
            self._invalid(plan, started, TrialValidity.INVALID_RUNNER,
                          "agent environment cleanup failed: " + str(error), worker_result.termination)
            raise InvalidTrialError(
                trial_id, TrialValidity.INVALID_RUNNER,
                "agent environment cleanup failed: " + str(error)
            ) from error
        self.database.record_state(trial_id, TrialState.GRADING.value)
        grading_run = self.grade_candidate(candidate.id, Path(task.bundle_root) / task.grader_bundle, task.graders,
                                           task.resource_policy.process_limit)
        self.database.record_state(trial_id, TrialState.FINALIZING.value)
        worker_validity = _worker_validity(worker_result.frames)
        verdict, validity = _verdict(worker_result.termination, grading_run.grader_results, worker_validity)
        metrics = derive_trajectory_metrics(worker_result.frames, worker_result.usage)
        trial = AgentTrial(
            id=trial_id, plan=plan, state=TrialState.COMPLETED, started_at=started,
            finished_at=utc_now(), termination=worker_result.termination,
            validity=validity, candidate_snapshot_id=candidate.id,
            diagnostics=worker_result.diagnostics, worker_pid=worker_result.pid,
        )
        result = EvalResult(
            trial_id=trial_id, candidate_snapshot_id=candidate.id,
            verdict=verdict, validity=validity, grader_results=grading_run.grader_results,
            usage=dict(worker_result.usage),
            timing={"agentMillis": worker_result.duration_millis,
                    "quiesceMillis": worker_result.quiesce_millis},
            task_fingerprint=task.task_fingerprint,
            condition_fingerprint=plan.condition_fingerprint,
            failure_classification=_failure_classification(verdict, validity, worker_result.termination),
            trajectory_metrics=jsonable(metrics),
        )
        self.database.record_state(trial_id, TrialState.COMPLETED.value)
        self.database.save_trial(jsonable(trial))
        self.database.save_metrics(trial_id, jsonable(metrics))
        self.database.save_eval_result(trial_id, jsonable(result))
        return trial, candidate, grading_run, result

    def _invalid(
        self, plan: TrialPlan, started: str, validity: TrialValidity,
        diagnostic: str, termination: AgentTermination,
    ) -> None:
        state = TrialState.INVALID if validity in (
            TrialValidity.INVALID_FIXTURE, TrialValidity.INVALID_ENVIRONMENT,
            TrialValidity.INVALID_PROVIDER_INFRASTRUCTURE,
        ) else TrialState.INFRASTRUCTURE_FAILED
        self.database.record_state(plan.trial_id, state.value, diagnostic)
        trial = AgentTrial(
            id=plan.trial_id, plan=plan, state=state, started_at=started,
            finished_at=utc_now(), termination=termination, validity=validity,
            candidate_snapshot_id=None, diagnostics=(diagnostic,), worker_pid=None,
        )
        self.database.save_trial(jsonable(trial))

    def grade_candidate(
        self, candidate_id: str, grader_bundle: Path,
        grader_specs: Sequence[Mapping[str, Any]], process_limit: int = 128,
    ):
        snapshot = self.database.load_candidate(candidate_id)
        grading_root = self.root / "grading" / new_id("sandbox")
        workspace = grading_root / "workspace"
        grading_root.mkdir(parents=True)
        try:
            self.artifacts.extract_directory(snapshot["workspace_artifact_ref"], workspace)
            run = self.grading.grade(candidate_id, workspace, grader_bundle.resolve(), grader_specs, process_limit)
            self.database.save_grading_run(run)
            return run
        finally:
            shutil.rmtree(grading_root, ignore_errors=True)


def _verdict(
    termination: AgentTermination, results: Sequence[Any],
    worker_validity: TrialValidity = TrialValidity.VALID,
) -> tuple[EvalVerdict, TrialValidity]:
    if worker_validity != TrialValidity.VALID:
        return EvalVerdict.INVALID, worker_validity
    if any(item.status == GraderStatus.ERROR and item.severity in (GraderSeverity.GATE, GraderSeverity.REQUIRED) for item in results):
        return EvalVerdict.INVALID, TrialValidity.INVALID_GRADER_INFRASTRUCTURE
    if termination != AgentTermination.COMPLETED:
        return EvalVerdict.FAIL, TrialValidity.VALID
    if any(item.status != GraderStatus.PASS and item.severity in (GraderSeverity.GATE, GraderSeverity.REQUIRED) for item in results):
        return EvalVerdict.FAIL, TrialValidity.VALID
    return EvalVerdict.PASS, TrialValidity.VALID


def _worker_validity(frames: Sequence[Mapping[str, Any]]) -> TrialValidity:
    for frame in frames:
        event = frame.get("event")
        if not isinstance(event, dict):
            continue
        code = str(event.get("code", ""))
        kind = str(event.get("kind", ""))
        if kind == "configuration" and code in (
            "sandbox.isolation_unsupported",
            "sandbox.runtime_missing",
            "sandbox.mount_invalid",
        ):
            return TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE
        if code.startswith("provider.") or (kind == "transport" and code.startswith("model.")):
            return TrialValidity.INVALID_PROVIDER_INFRASTRUCTURE
    return TrialValidity.VALID


def _operation_refs(artifacts: ArtifactStore, frames: Sequence[Mapping[str, Any]]) -> list[str]:
    result: list[str] = []
    for frame in frames:
        event = frame.get("event")
        if not isinstance(event, dict):
            continue
        code = str(event.get("code", ""))
        if code.startswith("tool.") or code.startswith("operation."):
            result.append(artifacts.put_json(frame))
    return result


def _settings_fingerprint(source: Optional[Path]) -> Mapping[str, str]:
    if source is None or not source.exists():
        return {}
    result: dict[str, str] = {}
    import hashlib
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if path.is_file() and not any(_settings_entry_excluded(part) for part in relative.parts):
            result[relative.as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


class InvalidTrialError(RuntimeError):
    def __init__(self, trial_id: str, validity: TrialValidity, message: str):
        super().__init__(message)
        self.trial_id = trial_id
        self.validity = validity


def _failure_classification(
    verdict: EvalVerdict, validity: TrialValidity, termination: AgentTermination
) -> Optional[FailureClassification]:
    if validity != TrialValidity.VALID or verdict == EvalVerdict.PASS:
        return None
    if termination == AgentTermination.BUDGET_EXCEEDED:
        return FailureClassification.BUDGET_EXHAUSTED
    return FailureClassification.UNCLASSIFIED_VALID_FAILURE
