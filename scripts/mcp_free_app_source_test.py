import hashlib
import json
from pathlib import Path
import tempfile
import tomllib
import unittest
from unittest.mock import patch

from mcp_free_app_source import materialize, package_closure, SourceBoundaryError


class McpFreeAppSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        self.package("agent_app", 'core = { path = "../core" }')
        self.package("core")

    def package(self, name, dependencies=""):
        p = self.root / name
        p.mkdir(parents=True, exist_ok=True)
        (p / "src").mkdir(exist_ok=True)
        (p / "src/main.cj").write_text("package " + name.replace("/", "_") + "\n", encoding="utf-8")
        (p / "cjpm.toml").write_text('[package]\nname = "' + name.rsplit("/", 1)[-1] + '"\n[dependencies]\n' + dependencies + '\n', encoding="utf-8")
        return p

    def test_exact_transitive_closure_excludes_optional_sources_and_binary_cache(self):
        self.package("libs/mcp4cj")
        self.package("plugins/mcp")
        (self.root / "core/target").mkdir()
        (self.root / "core/target/stale.cj").write_text("stale")
        (self.root / "core/libold.so").write_bytes(b"binary")
        (self.root / "core/cjpm.lock").write_text("old optional graph")
        (self.root / "core/src/fixture_test.cj").write_text("package core\n")
        report = materialize(self.root, self.base / "minimal")
        workspace = tomllib.loads((self.base / "minimal/cjpm.toml").read_text()) ["workspace"]
        self.assertEqual(set(workspace["build-members"]), set(report["packages"]))
        self.assertEqual(workspace["test-members"], ["core"])
        self.assertTrue(set(workspace["test-members"]).issubset(workspace["build-members"]))
        self.assertEqual(set(report["packages"]), {"agent_app", "core"})
        self.assertEqual(report["status"], "SOURCE_INPUT_ONLY_NOT_BUILT")
        self.assertFalse((self.base / "minimal/libs").exists())
        self.assertFalse((self.base / "minimal/core/target").exists())
        self.assertFalse((self.base / "minimal/core/libold.so").exists())
        self.assertFalse((self.base / "minimal/core/cjpm.lock").exists())
        for item in report["files"]:
            data = (self.base / "minimal" / item["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"])

    def test_transitive_optional_dependency_rejected_before_output_creation(self):
        self.package("core", 'mcp4cj = { path = "../libs/mcp4cj" }')
        self.package("libs/mcp4cj")
        out = self.base / "minimal"
        with self.assertRaisesRegex(SourceBoundaryError, "forbidden"):
            materialize(self.root, out)
        self.assertFalse(out.exists())

    def test_aliased_optional_source_cannot_escape_name_check(self):
        self.package("core", 'foreign = { path = "../plugins/foreign" }')
        self.package("plugins/foreign")
        with self.assertRaisesRegex(SourceBoundaryError, "optional"):
            package_closure(self.root)

    def test_relative_path_escape_and_name_confusion_are_rejected(self):
        self.package("core", 'outside = { path = "../../outside" }')
        (self.base / "outside").mkdir()
        with self.assertRaises(SourceBoundaryError):
            package_closure(self.root)
        self.package("core", 'wrong = { path = "../agent_app" }')
        with self.assertRaisesRegex(SourceBoundaryError, "identity"):
            package_closure(self.root)

    def test_existing_output_is_never_reused_or_deleted(self):
        out = self.base / "existing"
        out.mkdir()
        marker = out / "target-old"
        marker.write_bytes(b"keep")
        with self.assertRaisesRegex(SourceBoundaryError, "never reused"):
            materialize(self.root, out)
        self.assertEqual(marker.read_bytes(), b"keep")

    def test_changed_input_has_new_recorded_hash(self):
        before = materialize(self.root, self.base / "before")
        (self.root / "core/src/main.cj").write_text("package changed\n")
        after = materialize(self.root, self.base / "after")
        def digest(report):
            return next(item["sha256"] for item in report["files"] if item["path"] == "core/src/main.cj")
        self.assertNotEqual(digest(before), digest(after))


    def test_optional_source_import_without_manifest_edge_is_rejected(self):
        (self.root / "core/src/main.cj").write_text("package core\nimport mcp4cj.*\n", encoding="utf-8")
        with self.assertRaisesRegex(SourceBoundaryError, "forbidden source import"):
            materialize(self.root, self.base / "minimal")

    def test_mcp_implementation_packages_never_enter_app_closure(self):
        for package in ["agent_mcp", "mcp_extension", "mcp4cj", "mcp_client_plugin", "mcp_server_plugin"]:
            with self.subTest(package=package):
                self.package("core", package + ' = { path = "../' + package + '" }')
                self.package(package)
                with self.assertRaisesRegex(SourceBoundaryError, "forbidden"):
                    package_closure(self.root)

    def test_branch_only_external_pin_cannot_claim_reproducible_source(self):
        self.package("core", 'remote = { git = "https://invalid.example/repo", branch = "main" }')
        with self.assertRaisesRegex(SourceBoundaryError, "branch-only"):
            package_closure(self.root)

    def test_extensionless_executable_and_native_stamp_are_not_copied(self):
        (self.root / "core/stale-worker").write_bytes(b"\x7fELF" + b"x"*32)
        (self.root / "core/libold.so.compiler-id").write_text("stale")
        materialize(self.root, self.base / "minimal")
        self.assertFalse((self.base / "minimal/core/stale-worker").exists())
        self.assertFalse((self.base / "minimal/core/libold.so.compiler-id").exists())

    def test_build_drivers_share_source_total_limit_before_output_creation(self):
        scripts=self.root / "scripts";scripts.mkdir()
        (scripts / "pinned_cangjie").write_bytes(b"x"*1024)
        output=self.base / "minimal"
        with patch("mcp_free_app_source.MAX_TOTAL_BYTES",1024):
            with self.assertRaisesRegex(SourceBoundaryError,"bounded total"):
                materialize(self.root,output)
        self.assertFalse(output.exists())

    def test_target_specific_optional_dependency_is_also_rejected(self):
        manifest=self.root / "core/cjpm.toml"
        with manifest.open('a',encoding='utf-8') as stream:
            stream.write('\n[target.x86_64-unknown-linux-gnu.dependencies]\nmcp4cj = { git = "https://invalid.example/program", tag = "1.0.0" }\n')
        with self.assertRaisesRegex(SourceBoundaryError,"forbidden host dependency"):
            materialize(self.root,self.base / "minimal")

    def test_full_app_business_graph_is_explicitly_distinct_from_strict_minimal(self):
        self.package("core", 'agent_product = { path = "../agent_product" }')
        self.package("agent_product", 'model_adapters = { path = "../model_adapters" }')
        self.package("model_adapters")
        report = materialize(self.root, self.base / "full-app")
        self.assertEqual(report["entry"], "agent_app")
        self.assertEqual(set(report["packages"]), {"agent_app", "core", "agent_product", "model_adapters"})
        self.assertFalse((self.base / "full-app/agent_minimal").exists())

    def test_actual_legacy_program_layout_can_enter_only_full_app_source_input(self):
        self.package("core", 'program_language = { path = "../plugins/program/language" }')
        language = self.package("plugins/program/language")
        manifest = language / "cjpm.toml"
        manifest.write_text(manifest.read_text().replace('name = "language"', 'name = "program_language"'))
        report = materialize(self.root, self.base / "legacy-program-app")
        self.assertEqual(set(report["packages"]), {"agent_app", "core", "plugins/program/language"})
        self.assertEqual(report["packages"]["plugins/program/language"]["name"], "program_language")
        self.assertTrue((self.base / "legacy-program-app/plugins/program/language/src/main.cj").is_file())
        self.assertFalse((self.base / "legacy-program-app/plugins/mcp").exists())

if __name__ == "__main__":
    unittest.main()
