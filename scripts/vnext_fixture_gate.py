#!/usr/bin/env python3
"""Validate vNext trajectory fixtures and their Phase 0 traceability."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any


TEST_ID = re.compile(r"^T\d{3}$")
SCENARIO_ID = re.compile(r"^[a-z][a-z0-9_]*$")
RUN_STATES = {
    "Created",
    "Running",
    "WaitingApproval",
    "WaitingExternal",
    "Cancelling",
    "Cancelled",
    "Completed",
    "Failed",
    "RecoveryRequired",
}


def fail(message: str) -> None:
    raise ValueError(message)


def validate_fixture(document: dict[str, Any], plan_text: str) -> dict[str, int]:
    if document.get("version") != 1:
        fail("fixture version must be 1")
    item_kinds = document.get("item_kinds")
    if not isinstance(item_kinds, list) or not item_kinds:
        fail("item_kinds must be a non-empty array")
    known_item_kinds = set(item_kinds)
    if len(known_item_kinds) != len(item_kinds):
        fail("item_kinds must be unique")
    scenarios = document.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        fail("scenarios must be a non-empty array")

    known_tests = set(re.findall(r"\bT\d{3}\b", plan_text))
    scenario_ids: set[str] = set()
    referenced_tests: set[str] = set()
    crash_cases: set[str] = set()
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            fail("each scenario must be an object")
        scenario_id = scenario.get("id")
        if not isinstance(scenario_id, str) or not SCENARIO_ID.fullmatch(scenario_id):
            fail(f"invalid scenario id: {scenario_id!r}")
        if scenario_id in scenario_ids:
            fail(f"duplicate scenario id: {scenario_id}")
        scenario_ids.add(scenario_id)
        if scenario_id.startswith("crash_c"):
            crash_cases.add(scenario_id.split("_", 2)[1])

        tests = scenario.get("test_ids")
        if not isinstance(tests, list) or not tests:
            fail(f"scenario {scenario_id} must reference tests")
        for test_id in tests:
            if not isinstance(test_id, str) or not TEST_ID.fullmatch(test_id):
                fail(f"scenario {scenario_id} has invalid test id {test_id!r}")
            if test_id not in known_tests:
                fail(f"scenario {scenario_id} references unknown {test_id}")
            referenced_tests.add(test_id)

        stimuli = scenario.get("stimuli")
        if not isinstance(stimuli, list) or not stimuli:
            fail(f"scenario {scenario_id} must contain stimuli")
        if not all(isinstance(value, str) and value for value in stimuli):
            fail(f"scenario {scenario_id} stimuli must be non-empty strings")

        expected = scenario.get("expect")
        if not isinstance(expected, dict):
            fail(f"scenario {scenario_id} must contain expect object")
        run_state = expected.get("run_state")
        if run_state not in RUN_STATES:
            fail(f"scenario {scenario_id} has invalid run_state {run_state!r}")
        if expected.get("late_semantic_commits") != 0:
            fail(f"scenario {scenario_id} must assert zero late semantic commits")
        for item_kind in expected.get("item_kinds", []):
            if item_kind not in known_item_kinds:
                fail(f"scenario {scenario_id} uses unknown item kind {item_kind!r}")
        for name, value in expected.items():
            if name.endswith("_count") or name.endswith("_commits") or name.endswith("_retries"):
                if not isinstance(value, int) or value < 0:
                    fail(f"scenario {scenario_id} field {name} must be non-negative")

    expected_crash_cases = {f"c{value}" for value in range(1, 8)}
    if crash_cases != expected_crash_cases:
        fail(
            "fixtures must cover crash cases C1-C7 exactly; got "
            + ", ".join(sorted(crash_cases))
        )
    return {
        "scenario_count": len(scenario_ids),
        "referenced_test_count": len(referenced_tests),
        "crash_case_count": len(crash_cases),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=Path("docs/vnext/trajectory-fixtures.fixture"),
    )
    parser.add_argument(
        "--plan",
        type=Path,
        default=Path("docs/vnext/phase-0-gates.md"),
    )
    args = parser.parse_args()
    try:
        document = json.loads(args.fixtures.read_text(encoding="utf-8"))
        counts = validate_fixture(document, args.plan.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"vNext fixture gate failed: {error}", file=sys.stderr)
        return 1
    print(
        "vNext fixture gate passed "
        f"(scenarios={counts['scenario_count']} "
        f"tests={counts['referenced_test_count']} "
        f"crash_cases={counts['crash_case_count']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
