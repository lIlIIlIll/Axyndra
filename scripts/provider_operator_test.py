"""Fixture operator must use the requested real package across distributions."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fixture_provider_operator", ROOT / "support_tests/provider_operator.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProviderOperatorTests(unittest.TestCase):
    def exercise(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            package.mkdir()
            (package / "axyndra.plugin.json").write_text('{"id":"fixture"}')
            digest = module.package_digest(package)
            record = dict(id="fixture", namespace="axyndra:fixture", scope="user",
                          content_digest=digest, enabled=False)
            records = [] if mode == "absent" else [record]
            if mode == "changed":
                record["content_digest"] = "sha256:" + "0" * 64
            if mode == "foreign":
                record["scope"] = "workspace"
            calls = []

            def command(arguments, **kwargs):
                action = arguments[2]
                calls.append(action)
                if action == "inspect":
                    output = json.dumps(dict(id="fixture", namespace="axyndra:fixture"))
                elif action == "list":
                    output = json.dumps(records)
                elif action == "import":
                    records.append(record)
                    output = "import fixture"
                elif action == "enable":
                    record["enabled"] = True
                    output = "enabled fixture"
                else:
                    self.fail("unexpected fixture command")
                return subprocess.CompletedProcess(arguments, 0, output, "")

            with patch.object(module.subprocess, "run", side_effect=command):
                if mode in {"changed", "foreign"}:
                    with self.assertRaises(AssertionError):
                        module.install_package(root / "axyndra", root / "home", root,
                                               package, "axyndra:fixture")
                    self.assertEqual(calls, ["inspect", "list"])
                else:
                    selected = module.install_package(root / "axyndra", root / "home", root,
                                                      package, "axyndra:fixture")
                    self.assertEqual(selected["content_digest"], digest)
                    self.assertTrue(selected["enabled"])
                    self.assertEqual(calls.count("import"), int(mode == "absent"))
                    self.assertEqual(calls.count("enable"), 1)

    def test_absent_package_requires_real_import(self):
        self.exercise("absent")

    def test_bootstrap_package_reuses_exact_record_and_explicit_enable(self):
        self.exercise("present")

    def test_different_content_refuses_before_mutation(self):
        self.exercise("changed")

    def test_another_scope_cannot_substitute_for_user_installation(self):
        self.exercise("foreign")


if __name__ == "__main__":
    unittest.main()
