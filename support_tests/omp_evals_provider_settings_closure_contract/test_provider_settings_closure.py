from __future__ import annotations

import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from omp_evals.benchmark import BenchmarkRunner, build_condition, load_suite
from omp_evals.experiment_invariants import experiment_plan_from_mapping
from omp_evals.model import (
    AgentTermination, ConditionRuntimeReadiness, ExperimentalCondition, TrialValidity,
)
from omp_evals.provider_execution import provider_execution_digest
from omp_evals.provider_settings import (
    PROVIDER_SETTINGS_MATERIALIZER_VERSION, freeze_provider_settings_closure,
    materialize_provider_settings_closure, provider_settings_closure_digest,
    validate_materialized_provider_settings, validate_provider_settings_closure,
)
from omp_evals.runner import EvalRunner, InvalidTrialError
from omp_evals.storage import ArtifactStore
from omp_evals.util import hash_file, sha256_bytes
from omp_evals.worker import WorkerResult


class ProviderSettingsClosureContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[2]
        self.experiment = self.root / "eval_experiments/EXP-001R6-provider-settings-closure-refreeze"
        self.spec = json.loads((
            self.root / "eval_experiments/EXP-001R5-frozen-provider-execution-spec/provider-execution-spec.json"
        ).read_text())["spec"]

    def _freeze(self, artifacts: ArtifactStore, profile: str = "frozen-deepseek"):
        return freeze_provider_settings_closure(self.spec, artifacts, profile)

    def _mutate_file(self, closure: dict, artifacts: ArtifactStore, name: str, text: str) -> dict:
        changed = json.loads(json.dumps(closure))
        entry = next(item for item in changed["files"] if item["logicalPath"] == name)
        data = text.encode()
        entry.update({
            "digest": sha256_bytes(data), "size": len(data),
            "contentRef": artifacts.put_bytes(data),
        })
        changed["closureDigest"] = provider_settings_closure_digest(changed)
        return changed

    def test_materialization_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            first = self._freeze(artifacts)
            second = self._freeze(artifacts)
            self.assertEqual(first, second)

    def test_referential_integrity_and_semantic_projection(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            home = Path(raw) / "home"
            projection = materialize_provider_settings_closure(
                closure, artifacts, home, provider_execution_digest(self.spec),
            )
            self.assertEqual(projection["defaultModelRef"], "frozen-deepseek/deepseek-v4-flash")
            self.assertEqual(projection["semanticProjection"]["adapterIdentity"], "openai")
            self.assertEqual(validate_materialized_provider_settings(home), projection)

    def test_wrong_default_model_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            broken = self._mutate_file(
                closure, artifacts, "config.yml", "default_model: missing/model\n",
            )
            with self.assertRaisesRegex(ValueError, "resolve to exactly one"):
                materialize_provider_settings_closure(broken, artifacts, Path(raw) / "home")

    def test_missing_provider_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            broken = self._mutate_file(closure, artifacts, "providers.yml", "providers: []\n")
            with self.assertRaisesRegex(ValueError, "provider profiles"):
                materialize_provider_settings_closure(broken, artifacts, Path(raw) / "home")

    def test_missing_model_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            broken = self._mutate_file(closure, artifacts, "models.yml", "models: []\n")
            with self.assertRaisesRegex(ValueError, "model entries"):
                materialize_provider_settings_closure(broken, artifacts, Path(raw) / "home")

    def test_ambient_catalog_cannot_rescue_broken_closure(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            broken = self._mutate_file(closure, artifacts, "models.yml", "models: []\n")
            ambient = Path(raw) / "ambient"
            ambient.mkdir()
            (ambient / "models.yml").write_text(
                "models:\n  - id: deepseek-v4-flash\n    provider: frozen-deepseek\n"
            )
            with self.assertRaisesRegex(ValueError, "model entries"):
                materialize_provider_settings_closure(broken, artifacts, Path(raw) / "home")

    def test_secret_value_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            original = artifacts.get_bytes(closure["files"][1]["contentRef"]).decode()
            broken = self._mutate_file(
                closure, artifacts, "providers.yml", original + "    api_key: forbidden-secret\n",
            )
            with self.assertRaisesRegex(ValueError, "secret value"):
                materialize_provider_settings_closure(broken, artifacts, Path(raw) / "home")

    def test_materializer_version_is_frozen(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            changed = dict(closure)
            changed["materializerVersion"] = "future-v2"
            changed["closureDigest"] = provider_settings_closure_digest(changed)
            with self.assertRaisesRegex(ValueError, "materializer version"):
                validate_provider_settings_closure(changed)

    def test_frozen_closure_does_not_call_future_materializer(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            artifacts = ArtifactStore(Path(raw) / "cas")
            closure, _ = self._freeze(artifacts)
            with patch("omp_evals.provider_settings.materialize_provider_settings", side_effect=AssertionError):
                result = materialize_provider_settings_closure(
                    closure, artifacts, Path(raw) / "home", provider_execution_digest(self.spec),
                )
            self.assertEqual(result["defaultModelRef"], "frozen-deepseek/deepseek-v4-flash")

    def test_a6_b6_share_one_settings_closure(self) -> None:
        a = json.loads((self.root / "eval_conditions/exp-001r6-edit-model-contract-a6.json").read_text())
        b = json.loads((self.root / "eval_conditions/exp-001r6-edit-model-contract-b6.json").read_text())
        self.assertEqual(a["providerSettingsClosureDigest"], b["providerSettingsClosureDigest"])
        self.assertEqual(a["providerSettingsClosureRef"], b["providerSettingsClosureRef"])
        self.assertEqual(a["providerSettingsClosure"], b["providerSettingsClosure"])
        self.assertNotEqual(a["editModelContractDigest"], b["editModelContractDigest"])

    def test_frozen_executable_acceptance_artifact_covers_a_and_b(self) -> None:
        value = json.loads((self.experiment / "provider-settings-compatibility.json").read_text())
        self.assertEqual(value["negativeR5Fixture"]["readiness"], "Invalid")
        for name in ("A6", "B6"):
            probe = value["conditions"][name]["providerSettingsCompatibility"]
            self.assertEqual(probe["readiness"], "Ready")
            self.assertTrue(probe["protocol_ready"])
            self.assertTrue(probe["get_state_ready"])
            self.assertEqual((probe["provider_requests"], probe["model_calls"]), (0, 0))

    def test_pretrial_compatibility_failure_cannot_access_database(self) -> None:
        suite, tasks = load_suite(
            self.root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
        )
        paths = (
            self.root / "eval_conditions/exp-001r6-edit-model-contract-a6.json",
            self.root / "eval_conditions/exp-001r6-edit-model-contract-b6.json",
        )
        conditions = tuple(build_condition(path, tasks[0], Path("/unused"), Path("/tmp")) for path in paths)
        plan = experiment_plan_from_mapping(json.loads((self.experiment / "experiment-plan.json").read_text()))

        class ForbiddenDatabase:
            def __getattr__(self, name):
                raise AssertionError(f"database accessed before compatibility gate: {name}")

        class FakeRunner:
            database = ForbiddenDatabase()
            def preflight_condition_runtime(self, condition):
                return SimpleNamespace(readiness=ConditionRuntimeReadiness.READY, diagnostics=())
            def preflight_condition_tool_execution(self, condition):
                return SimpleNamespace(readiness=ConditionRuntimeReadiness.READY, diagnostics=())
            def preflight_condition_provider_settings(self, condition):
                return SimpleNamespace(readiness=ConditionRuntimeReadiness.INVALID,
                                       diagnostics=("typed compatibility failure",))

        with self.assertRaisesRegex(ValueError, "provider settings are not compatible"):
            BenchmarkRunner(FakeRunner()).execute_plan(
                suite, tasks, conditions, plan, Path("/unused"), Path("/tmp"),
            )

    def test_intrial_startup_failure_is_directly_invalid_environment(self) -> None:
        class StartupFailureWorker:
            def run(self, *args, **kwargs):
                return WorkerResult(
                    pid=123, termination=AgentTermination.CRASHED, exit_code=1,
                    frames=(), usage={}, final_answer="", diagnostics=("typed startup failure",),
                    duration_millis=1, quiesce_millis=0, startup_ready=False,
                    infrastructure_failure="ConditionStartupInfrastructureFailure",
                )

        with tempfile.TemporaryDirectory() as raw:
            base = Path(raw)
            runner = EvalRunner(base / "eval-home", worker=StartupFailureWorker())
            try:
                closure, closure_ref = self._freeze(runner.artifacts)
                condition = ExperimentalCondition(
                    id="synthetic", version="1", fingerprint="synthetic-condition",
                    manifest={"id": "synthetic"},
                    agent={"model": "frozen-deepseek/deepseek-v4-flash", "arguments": []},
                    agent_binary=sys.executable,
                    provider_execution_spec=self.spec,
                    provider_execution_digest=provider_execution_digest(self.spec),
                    provider_settings_closure=closure,
                    provider_settings_closure_ref=closure_ref,
                    provider_settings_closure_digest=provider_settings_closure_digest(closure),
                )
                task = load_suite(
                    self.root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
                )[1][0]
                with self.assertRaises(InvalidTrialError) as caught:
                    runner.run(task, Path(sys.executable), condition=condition)
                trial = runner.database.load_trial(caught.exception.trial_id)
                self.assertEqual(trial["validity"], TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE.value)
                self.assertIsNone(trial["candidate_snapshot_id"])
            finally:
                runner.close()

    def test_historical_r5_raw_and_effective_validity_remain_distinct(self) -> None:
        aggregate = json.loads((
            self.root / "eval_experiments/EXP-001R5-frozen-provider-execution-spec/aggregate-result.json"
        ).read_text())
        self.assertEqual(aggregate["storedValid"], 6)
        self.assertEqual(aggregate["capabilityValid"], 0)
        self.assertEqual(aggregate["infrastructureInvalid"], 6)
        self.assertEqual(aggregate["strictCapabilityDenominator"], 0)

    def test_historical_r5_artifacts_match_parent_hashes(self) -> None:
        parent = json.loads((self.experiment / "parent-evidence.json").read_text())
        root = self.root / "eval_experiments/EXP-001R5-frozen-provider-execution-spec"
        self.assertEqual(
            {name: hash_file(root / name) for name in parent["parentArtifactHashes"]},
            parent["parentArtifactHashes"],
        )

    def test_readiness_created_no_trials(self) -> None:
        readiness = json.loads((self.experiment / "readiness.json").read_text())
        manifest = json.loads((self.experiment / "manifest.json").read_text())
        self.assertTrue(readiness["executableExperimentReady"])
        self.assertEqual(
            (readiness["providerRequests"], readiness["modelCalls"], readiness["agentTrials"]),
            (0, 0, 0),
        )
        self.assertEqual(manifest["offlineProof"]["agentTrials"], 0)

    def test_security_and_materializer_identity(self) -> None:
        closure = json.loads((self.experiment / "provider-settings-closure.json").read_text())
        security = json.loads((self.experiment / "security-verification.json").read_text())
        self.assertEqual(closure["materializerVersion"], PROVIDER_SETTINGS_MATERIALIZER_VERSION)
        self.assertFalse(security["credentialValuePersisted"])
        encoded = json.dumps(closure, sort_keys=True)
        self.assertNotIn("Authorization", encoded)
        self.assertNotIn("forbidden-secret", encoded)


if __name__ == "__main__":
    unittest.main()
