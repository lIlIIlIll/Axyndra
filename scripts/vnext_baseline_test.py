#!/usr/bin/env python3
"""Self-tests for the manifest-driven vNext baseline collector."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "scripts" / "vnext_baseline.py"


def run_collector(manifest: dict) -> tuple[subprocess.CompletedProcess[str], dict]:
    with tempfile.TemporaryDirectory(prefix="axyndra-vnext-baseline-test-") as root:
        temporary = Path(root)
        manifest_path = temporary / "manifest.json"
        output_path = temporary / "result.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(COLLECTOR),
                "--manifest",
                str(manifest_path),
                "--output",
                str(output_path),
                "--repo-root",
                str(ROOT),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        result = (
            json.loads(output_path.read_text(encoding="utf-8"))
            if output_path.exists()
            else {}
        )
        return completed, result


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    success, result = run_collector(
        {
            "version": 1,
            "candidate": "collector-self-test",
            "unavailable": [
                {"name": "retained_heap", "reason": "self-test fixture"}
            ],
            "benchmarks": [
                {
                    "name": "probe",
                    "command": [
                        sys.executable,
                        "-c",
                        "import os; print('isolated=' + str(bool(os.environ.get('AXYNDRA_HOME'))))",
                    ],
                    "warmups": 1,
                    "samples": 3,
                    "expect": {"stdout_contains": "isolated=True"},
                }
            ],
        }
    )
    expect(success.returncode == 0, f"collector failed: {success.stdout}{success.stderr}")
    expect(result["candidate"] == "collector-self-test", "candidate identity is preserved")
    benchmark = result["benchmarks"][0]
    expect(benchmark["sample_count"] == 3, "sample count is preserved")
    expect(len(benchmark["samples_ms"]) == 3, "all raw samples are preserved")
    expect(
        benchmark["p50_ms"] <= benchmark["p95_ms"] <= benchmark["p99_ms"],
        "percentiles are monotonic",
    )
    expect(benchmark["p99_ms"] <= benchmark["max_ms"], "p99 does not exceed max")
    expect(result["unavailable"][0]["name"] == "retained_heap", "unavailable metrics survive")

    invalid, invalid_result = run_collector({"version": 1, "benchmarks": []})
    expect(invalid.returncode != 0, "empty benchmark manifests are rejected")
    expect(not invalid_result, "failed collection does not publish an artifact")
    print("vNext baseline collector tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

