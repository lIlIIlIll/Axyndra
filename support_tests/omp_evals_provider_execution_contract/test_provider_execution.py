from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from omp_evals.benchmark import (
    build_condition, build_experiment_plan, load_suite, validate_experiment_plan_inputs,
)
from omp_evals.experiment_invariants import ExperimentInvariantMismatch
from omp_evals.provider_execution import (
    canonical_provider_execution_spec, materialize_provider_settings,
    provider_execution_digest,
)
from omp_evals.util import hash_file


def spec(**changes):
    value = {
        "schemaVersion": "omp-evals-provider-execution-v1",
        "adapterIdentity": "openai",
        "protocol": "completions",
        "baseUrl": "https://api.deepseek.com",
        "wireModel": "deepseek-v4-flash",
        "authentication": "api-key",
        "credentialSlot": "DEEPSEEK_API_KEY",
        "timeoutMillis": 120000,
        "messagesFastMode": False,
        "capabilities": {
            "toolCalling": True, "parallelToolCalling": True, "reasoning": True,
            "vision": False, "structuredOutput": False, "promptCache": False,
            "contextWindowTokens": 128000, "maxOutputTokens": 16384,
        },
        "requestSettings": {}, "reasoningSettings": {}, "providerOptions": {},
    }
    value.update(changes)
    return value


class ProviderExecutionContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[2]
        self.settings = self.root / "support_tests/omp_evals_real_integration/settings"
        self.task = load_suite(
            self.root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
        )[1][0]

    def test_alias_is_not_semantic_identity(self) -> None:
        first = provider_execution_digest(spec())
        second = provider_execution_digest(spec())
        self.assertEqual(first, second)

    def test_chat_completions_alias_canonicalizes(self) -> None:
        self.assertEqual(
            provider_execution_digest(spec(protocol="completions")),
            provider_execution_digest(spec(protocol="chat-completions")),
        )

    def test_semantic_mutations_change_digest(self) -> None:
        baseline = provider_execution_digest(spec())
        mutations = (
            spec(baseUrl="https://example.invalid"),
            spec(adapterIdentity="anthropic"),
            spec(wireModel="other-model"),
            spec(requestSettings={"temperature": 0.2}),
        )
        self.assertTrue(all(provider_execution_digest(item) != baseline for item in mutations))

    def test_credential_value_is_not_part_of_spec_or_digest(self) -> None:
        value = spec()
        encoded = json.dumps(canonical_provider_execution_spec(value), sort_keys=True)
        self.assertNotIn("secret-A", encoded)
        self.assertEqual(provider_execution_digest(value), provider_execution_digest(value))
        with self.assertRaisesRegex(ValueError, "secret-bearing"):
            canonical_provider_execution_spec({**value, "apiKeyValue": "secret-A"})

    def test_credential_rotation_does_not_change_identity(self) -> None:
        import os
        from unittest.mock import patch
        with patch.dict(os.environ, {"DEEPSEEK_API_KEY": "secret-A"}):
            first = provider_execution_digest(spec())
        with patch.dict(os.environ, {"DEEPSEEK_API_KEY": "secret-B"}):
            second = provider_execution_digest(spec())
        self.assertEqual(first, second)

    def test_endpoint_with_embedded_credentials_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "embed credentials"):
            canonical_provider_execution_spec(spec(baseUrl="https://user:pass@example.com"))

    def test_round_trip_materialization_is_ambient_independent(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            destination = Path(raw)
            result = materialize_provider_settings(spec(), destination, "frozen-provider")
            self.assertEqual(result["providerExecutionDigest"], provider_execution_digest(spec()))
            self.assertIn("frozen-provider/deepseek-v4-flash", (destination / "config.yml").read_text())
            self.assertIn("https://api.deepseek.com", (destination / "providers.yml").read_text())
            self.assertNotIn("secret", "".join(p.read_text() for p in destination.iterdir()).lower())

    def test_condition_reconstruction_ignores_ambient_provider_semantics(self) -> None:
        condition_path = self.root / "eval_conditions/exp-001r5-edit-model-contract-a5.json"
        if not condition_path.exists():
            self.skipTest("R5 immutable condition has not been frozen yet")
        baseline = build_condition(condition_path, self.task, Path("/unused"), self.settings)
        with tempfile.TemporaryDirectory() as raw:
            ambient = Path(raw)
            (ambient / "config.yml").write_text("default_model: unrelated/other\n")
            (ambient / "providers.yml").write_text("providers: []\n")
            (ambient / "models.yml").write_text("models: []\n")
            replay = build_condition(condition_path, self.task, Path("/unused"), ambient)
        self.assertEqual(replay.fingerprint, baseline.fingerprint)
        self.assertEqual(replay.provider_execution_spec, baseline.provider_execution_spec)

    def test_provider_semantic_mutation_is_rejected_pre_trial(self) -> None:
        paths = (
            self.root / "eval_conditions/exp-001r5-edit-model-contract-a5.json",
            self.root / "eval_conditions/exp-001r5-edit-model-contract-b5.json",
        )
        if not all(path.exists() for path in paths):
            self.skipTest("R5 immutable conditions have not been frozen yet")
        suite, tasks = load_suite(
            self.root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
        )
        conditions = tuple(build_condition(path, tasks[0], Path("/unused"), self.settings) for path in paths)
        plan = build_experiment_plan("fixture", "PairedAB", suite, tasks, conditions, 3, 1005,
                                     "2026-08-13T00:00:00Z")
        changed_spec = spec(baseUrl="https://example.invalid")
        changed_digest = provider_execution_digest(changed_spec)
        changed_manifest = dict(conditions[0].manifest)
        changed_manifest["providerExecutionDigest"] = changed_digest
        changed = replace(
            conditions[0], manifest=changed_manifest,
            provider_execution_spec=changed_spec, provider_execution_digest=changed_digest,
        )
        with self.assertRaises(ExperimentInvariantMismatch):
            validate_experiment_plan_inputs(suite, tasks, (changed, conditions[1]), plan)

    def test_exp001r4_artifacts_are_immutable(self) -> None:
        experiment = self.root / "eval_experiments/EXP-001R4-canonical-experiment-invariants-refreeze"
        expected = {
            "invariant-snapshot.json": "d4db2fd8b2ad9ec63e5ae9695dfb7e50dccf35ad84518359ef9f3fcd8864d730",
            "experiment-plan.json": "7864e85ff5de69fc9940e83d1c4bd8269e16e6fbcd44c8dc172d916161a69a4f",
            "decision.json": "6a0574e4543a3b3e78253e308cdd5ad26316f4b903d45374d3db6be510611789",
        }
        self.assertEqual({name: hash_file(experiment / name) for name in expected}, expected)


if __name__ == "__main__":
    unittest.main()
