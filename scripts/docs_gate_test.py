#!/usr/bin/env python3

import contextlib
import io
import pathlib
import tempfile
import tomllib
import unittest
from unittest import mock

import docs_gate


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DocumentationAuthoritiesTest(unittest.TestCase):
    def test_primary_architecture_documents_exist(self) -> None:
        for path in (
            "docs/architecture.md",
            "docs/runtime-capabilities.md",
            "docs/cj-tui-dependency.md",
        ):
            self.assertTrue((ROOT / path).is_file(), path)

    def test_vendored_cjtui_provenance_exists(self) -> None:
        self.assertTrue((ROOT / "vendor/cj_tui/PROVENANCE.json").is_file())


class DocumentationGateRegressionTest(unittest.TestCase):
    """Exercise the real gate against isolated, explicit repository fixtures."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.write("README.md", "# Fixture\n")
        self.write("docs/architecture.md", "schema v28\n")
        self.write(
            "docs/compatibility.md",
            "schema v28\n/inspect [run-id] [before-operation-cursor]\n",
        )
        self.write("agent_store/src/database.cj", "if (version == 28) { return }\n")
        self.write(
            "agent_cli/src/commands.cj",
            '\"inspect\", \"Inspect\", usage: \"/inspect [run-id] [before-operation-cursor]\"',
        )
        self.write("agent_minimal/cjpm.toml", '[package]\nname = "agent_minimal"\n')
        self.write(
            "cjpm.toml",
            '[workspace]\nmembers = ["agent_minimal"]\n'
            'build-members = ["agent_minimal"]\ntest-members = ["agent_minimal"]\n',
        )

    def write(self, relative: str, content: str) -> None:
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def run_gate(self) -> tuple[int, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(docs_gate, "ROOT", self.root):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = docs_gate.main()
        return result, stderr.getvalue()

    def assert_gate_passes(self) -> None:
        result, errors = self.run_gate()
        self.assertEqual(result, 0, errors)
        self.assertEqual(errors, "")

    def assert_gate_fails(self, message: str) -> None:
        result, errors = self.run_gate()
        self.assertEqual(result, 1, errors)
        self.assertIn(message, errors)

    def test_consistent_fixture_passes(self) -> None:
        self.assert_gate_passes()

    def test_existing_literal_authority_passes(self) -> None:
        self.write("README.md", "`agent_minimal/cjpm.toml`\n")
        self.assert_gate_passes()

    def test_missing_literal_authority_fails(self) -> None:
        self.write("README.md", "`agent_minimal/missing.cj`\n")
        self.assert_gate_fails("missing authority agent_minimal/missing.cj")

    def test_matching_star_authority_passes(self) -> None:
        self.write("support_tests/legacy_sdk/cjpm.toml", "")
        self.write("README.md", "`support_tests/legacy_*`\n")
        self.assert_gate_passes()

    def test_unmatched_glob_fails_even_when_truncated_prefix_exists(self) -> None:
        self.write("support_tests/legacy_/unrelated.cj", "")
        self.write("README.md", "`support_tests/legacy_*/missing.cj`\n")
        self.assert_gate_fails("missing authority support_tests/legacy_*/missing.cj")

    def test_question_mark_authority_passes(self) -> None:
        self.write("support_tests/legacy_1/fixture.cj", "")
        self.write("README.md", "`support_tests/legacy_?/fixture.cj`\n")
        self.assert_gate_passes()

    def test_character_class_authority_passes(self) -> None:
        self.write("support_tests/legacy_2/fixture.cj", "")
        self.write("README.md", "`support_tests/legacy_[12]/fixture.cj`\n")
        self.assert_gate_passes()

    def test_invalid_recursive_glob_fails_without_crashing(self) -> None:
        self.write("README.md", "`support_tests/**suffix/fixture.cj`\n")
        self.assert_gate_fails("missing authority support_tests/**suffix/fixture.cj")

    def test_source_selector_keeps_literal_authority_check(self) -> None:
        self.write("README.md", "`agent_store/src/database.cj:Database`\n")
        self.assert_gate_passes()

    def test_missing_markdown_link_still_fails(self) -> None:
        self.write("README.md", "[missing](docs/not-present.md#section)\n")
        self.assert_gate_fails("missing link docs/not-present.md#section")

    def test_external_and_fragment_links_are_not_local_authorities(self) -> None:
        self.write("README.md", "[web](https://example.com) [section](#heading)\n")
        self.assert_gate_passes()

    def test_schema_drift_still_fails_for_either_document(self) -> None:
        for document in ("docs/architecture.md", "docs/compatibility.md"):
            with self.subTest(document=document):
                original = (self.root / document).read_text(encoding="utf-8")
                self.write(document, original.replace("schema v28", "schema v27"))
                self.assert_gate_fails("schema documentation drift")
                self.write(document, original)

    def test_inspect_usage_drift_still_fails(self) -> None:
        self.write("docs/compatibility.md", "schema v28\n/inspect [run-id]\n")
        self.assert_gate_fails("CLI documentation drift")

    def test_missing_build_member_still_fails(self) -> None:
        manifest = (self.root / "cjpm.toml").read_text(encoding="utf-8")
        self.write("cjpm.toml", manifest.replace('build-members = ["agent_minimal"]', 'build-members = []'))
        self.assert_gate_fails("workspace.build-members differs from workspace.members")

    def test_missing_test_member_still_fails(self) -> None:
        manifest = (self.root / "cjpm.toml").read_text(encoding="utf-8")
        self.write("cjpm.toml", manifest.replace('test-members = ["agent_minimal"]', 'test-members = []'))
        self.assert_gate_fails("workspace.test-members differs from workspace.members")

    def test_missing_member_manifest_still_fails(self) -> None:
        (self.root / "agent_minimal/cjpm.toml").unlink()
        self.assert_gate_fails("member lacks manifest: agent_minimal")


class WorkspaceMembershipTest(unittest.TestCase):
    def test_every_workspace_member_is_built_and_tested(self) -> None:
        workspace = tomllib.loads((ROOT / "cjpm.toml").read_text(encoding="utf-8"))["workspace"]
        self.assertIn("agent_minimal", workspace["members"])
        for field in ("build-members", "test-members"):
            with self.subTest(field=field):
                self.assertEqual(workspace[field], workspace["members"])


if __name__ == "__main__":
    unittest.main()
