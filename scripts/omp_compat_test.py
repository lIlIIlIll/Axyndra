#!/usr/bin/env python3

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("omp_compat.py")
SPEC = importlib.util.spec_from_file_location("omp_compat", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
omp_compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(omp_compat)


class CandidateToolSchemaCompatibilityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.baseline = {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        }

    def test_exact_baseline_matches_without_extensions(self) -> None:
        self.assertEqual(
            omp_compat.candidate_tool_schema_compatibility(
                "read", self.baseline, self.baseline
            ),
            (True, []),
        )

    def test_read_allows_only_typed_optional_artifact_extensions(self) -> None:
        candidate = {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "offset": omp_compat.manifest_schema_type("number | null"),
                "limit": omp_compat.manifest_schema_type("number | null"),
                "destination": {"type": "string"},
            },
            "required": ["path"],
        }
        self.assertEqual(
            omp_compat.candidate_tool_schema_compatibility(
                "read", self.baseline, candidate
            ),
            (True, ["offset", "limit", "destination"]),
        )

    def test_extension_cannot_become_required(self) -> None:
        candidate = {
            "type": "object",
            "properties": {
                **self.baseline["properties"],
                "destination": {"type": "string"},
            },
            "required": ["path", "destination"],
        }
        self.assertFalse(
            omp_compat.candidate_tool_schema_compatibility(
                "read", self.baseline, candidate
            )[0]
        )

    def test_wrong_type_or_unlisted_extension_fails(self) -> None:
        for field, schema in [
            ("destination", {"type": "number"}),
            ("surprise", {"type": "string"}),
        ]:
            candidate = {
                "type": "object",
                "properties": {
                    **self.baseline["properties"],
                    field: schema,
                },
                "required": ["path"],
            }
            self.assertFalse(
                omp_compat.candidate_tool_schema_compatibility(
                    "read", self.baseline, candidate
                )[0]
            )

    def test_other_tools_still_require_exact_equality(self) -> None:
        candidate = {
            "type": "object",
            "properties": {
                **self.baseline["properties"],
                "destination": {"type": "string"},
            },
            "required": ["path"],
        }
        self.assertFalse(
            omp_compat.candidate_tool_schema_compatibility(
                "write", self.baseline, candidate
            )[0]
        )

    def test_grep_count_and_glob_pattern_are_not_schema_extensions(self) -> None:
        cases = [
            (
                "grep",
                {
                    "type": "object",
                    "properties": {"pattern": {"type": "string"}},
                    "required": ["pattern"],
                },
                "count",
                {"type": "boolean"},
            ),
            (
                "glob",
                {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": [],
                },
                "pattern",
                {"type": "string"},
            ),
        ]
        for tool, baseline, field, schema in cases:
            with self.subTest(tool=tool):
                candidate = {
                    "type": "object",
                    "properties": {
                        **baseline["properties"],
                        field: schema,
                    },
                    "required": baseline["required"],
                }
                self.assertFalse(
                    omp_compat.candidate_tool_schema_compatibility(
                        tool, baseline, candidate
                    )[0]
                )


if __name__ == "__main__":
    unittest.main()
