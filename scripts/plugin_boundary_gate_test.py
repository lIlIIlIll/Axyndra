#!/usr/bin/env python3
"""Mutation checks for capability dependencies hidden from a direct-only gate."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import plugin_boundary_gate as gate


class PluginBoundaryGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "cjpm.toml").write_text('[workspace]\nmembers = ["host"]\n', encoding="utf-8")
        self.policy = {"schema_version": 1, "host_packages": ["host"], "optional_capability_packages": ["mcp"]}
        self.empty_baseline = {"schema_version": 1, "allowed_violations": []}
        self.package("host")

    def package(self, directory, *, name=None, dependencies="", source=""):
        destination = self.root / directory
        (destination / "src").mkdir(parents=True, exist_ok=True)
        (destination / "cjpm.toml").write_text(
            f'[package]\nname = "{name or directory}"\n{dependencies}', encoding="utf-8"
        )
        (destination / "src/main.cj").write_text(source, encoding="utf-8")

    def report(self):
        return gate.inventory(self.root, self.policy)

    def keys(self):
        return {item["key"] for item in self.report()["violations"]}

    def test_clean_host_has_no_capability_dependencies(self):
        self.assertEqual([], gate.check(self.report(), self.empty_baseline, True))

    def test_transitive_aliased_dependency_outside_workspace_members_is_detected(self):
        self.package("host", dependencies='[dependencies]\nhelper = { path = "../bridge" }\n')
        self.package("bridge", dependencies='[dependencies]\ninnocent = { path = "../optional", output-type = "static" }\n')
        self.package("optional", name="mcp")
        report = self.report()
        path = next(item["chain"] for item in report["violations"] if item["key"] == "reachable:host:mcp")
        self.assertEqual(["host", "bridge", "mcp"], path)
        self.assertIn("manifest:bridge:mcp", self.keys())

    def test_independent_ast_plugin_is_inventoried_without_host_edge_and_rejects_added_edge(self):
        self.policy["optional_capability_packages"].append("ast_plugin")
        self.package("plugins/ast", name="ast_plugin")
        report = self.report()
        self.assertEqual(["ast_plugin"], report["independent_plugin_packages"])
        self.assertEqual(2, report["package_count"])
        self.assertEqual([], gate.check(report, self.empty_baseline, False))
        self.package("host", dependencies='[dependencies]\ninnocent = { path = "../plugins/ast" }\n')
        violations = {item["key"] for item in gate.check(self.report(), self.empty_baseline, False)}
        self.assertIn("reachable:host:ast_plugin", violations)
        self.assertIn("manifest:host:ast_plugin", violations)

    def test_new_independent_plugin_requires_explicit_optional_policy(self):
        self.package("plugins/unclassified", name="new_business_plugin")
        with self.assertRaisesRegex(ValueError, "independent plugin missing optional capability policy"):
            self.report()

    def test_target_specific_dependency_is_not_omitted(self):
        self.package("host", dependencies='[target.x86_64-unknown-linux-gnu.dependencies]\nmcp = { git = "https://invalid.example/mcp" }\n')
        self.assertIn("reachable:host:mcp", self.keys())

    def test_undeclared_production_import_still_fails(self):
        self.package("host", source="package host\nimport mcp.client.*\n")
        self.assertIn("import:host/src/main.cj:mcp", self.keys())
        self.assertTrue(gate.check(self.report(), self.empty_baseline, False))

    def test_aliased_import_does_not_hide_undeclared_capability(self):
        self.package("host", source="package host\nimport mcp as unrelated\n")
        self.assertIn("import:host/src/main.cj:mcp", self.keys())

    def test_test_fixture_and_comment_text_do_not_create_production_edges(self):
        self.package("host", source='''package host
// import mcp.*
/* import mcp.* */
let fixture = """
import mcp.*
"""
''')
        (self.root / "host/src/mcp_test.cj").write_text("import mcp.*\n", encoding="utf-8")
        self.assertEqual(set(), self.keys())

    def test_baseline_is_a_ratchet_never_a_minimal_exemption(self):
        self.package("host", source="import mcp.*\n")
        report = self.report()
        baseline = {"schema_version": 1, "allowed_violations": [item["key"] for item in report["violations"]]}
        self.assertEqual([], gate.check(report, baseline, False))
        self.assertTrue(gate.check(report, baseline, True))
        (self.root / "host/src/second.cj").write_text("import mcp.*\n", encoding="utf-8")
        self.assertEqual(["import:host/src/second.cj:mcp"], [item["key"] for item in gate.check(self.report(), baseline, False)])

    def test_missing_local_dependency_fails_before_claiming_minimal(self):
        self.package("host", dependencies='[dependencies]\nmcp = { path = "../missing" }\n')
        with self.assertRaisesRegex(ValueError, "missing package manifest"):
            self.report()

    def test_missing_host_package_cannot_pass_vacuously(self):
        self.policy["host_packages"] = ["does_not_exist"]
        with self.assertRaisesRegex(ValueError, "required host package"):
            self.report()

    def test_empty_policy_cannot_claim_a_clean_boundary(self):
        for field in ("host_packages", "optional_capability_packages"):
            with self.subTest(field=field):
                changed = {**self.policy, field: []}
                with self.assertRaisesRegex(ValueError, "nonempty array"):
                    gate.inventory(self.root, changed)

    def test_duplicate_package_identity_is_rejected(self):
        self.package("host", dependencies='[dependencies]\nother = { path = "../collision" }\n')
        self.package("collision", name="host")
        with self.assertRaisesRegex(ValueError, "duplicate package name"):
            self.report()

    def test_graph_cycles_are_bounded_and_do_not_hide_capability(self):
        graph = {"host": {"bridge"}, "bridge": {"host", "mcp"}}
        self.assertEqual(["host", "bridge", "mcp"], gate.shortest_paths(graph, "host")["mcp"])

    def test_cli_emits_json_report_and_nonzero_for_minimal_violation(self):
        self.package("host", source="import mcp.*\n")
        for filename, value in [("policy.json", self.policy), ("baseline.json", self.empty_baseline)]:
            (self.root / filename).write_text(json.dumps(value), encoding="utf-8")
        report = self.root / "evidence/report.json"
        result = subprocess.run([
            sys.executable, str(Path(gate.__file__)), "--root", str(self.root),
            "--policy", str(self.root / "policy.json"), "--baseline", str(self.root / "baseline.json"),
            "--minimal", "--report", str(report),
        ], text=True, capture_output=True, check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn("reachable:host:mcp", result.stderr)
        self.assertEqual(1, json.loads(report.read_text())["schema_version"])


if __name__ == "__main__":
    unittest.main()
