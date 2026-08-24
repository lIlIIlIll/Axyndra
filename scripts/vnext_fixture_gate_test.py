#!/usr/bin/env python3
"""Self-tests for the vNext trajectory fixture gate."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts" / "vnext_fixture_gate.py"
FIXTURES = ROOT / "docs" / "vnext" / "trajectory-fixtures.fixture"
PLAN = ROOT / "docs" / "vnext" / "phase-0-gates.md"


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def invoke(fixtures: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(GATE),
            "--fixtures",
            str(fixtures),
            "--plan",
            str(PLAN),
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    valid = invoke(FIXTURES)
    expect(valid.returncode == 0, f"valid fixtures failed: {valid.stderr}")
    expect("crash_cases=7" in valid.stdout, "all crash cases are reported")

    document = json.loads(FIXTURES.read_text(encoding="utf-8"))
    document["scenarios"][0]["expect"]["late_semantic_commits"] = 1
    with tempfile.TemporaryDirectory(prefix="axyndra-vnext-fixture-test-") as root:
        invalid_path = Path(root) / "invalid.json"
        invalid_path.write_text(json.dumps(document), encoding="utf-8")
        invalid = invoke(invalid_path)
    expect(invalid.returncode != 0, "non-zero late commit fixture is rejected")
    expect("zero late semantic commits" in invalid.stderr, "failure explains invariant")
    print("vNext fixture gate tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
