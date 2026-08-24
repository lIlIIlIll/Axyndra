#!/usr/bin/env python3
"""Explicitly replace compatibility baselines after an approved release decision."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    "agent_sdk": ROOT / "compat" / "agent-sdk-v1.api.json",
    "omp_agent_testkit": ROOT / "compat" / "omp-agent-testkit-v1.api.json",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", choices=sorted(TARGETS))
    parser.add_argument(
        "--reviewed-breaking-release",
        action="store_true",
        help="confirm that the baseline replacement is an explicit reviewed release action",
    )
    args = parser.parse_args()
    if not args.reviewed_breaking_release:
        parser.error("baseline updates require --reviewed-breaking-release")
    output = subprocess.check_output(
        ["python3", str(ROOT / "scripts" / "check_sdk_compatibility.py"), "--dump", args.package],
        cwd=ROOT,
        text=True,
    )
    TARGETS[args.package].parent.mkdir(parents=True, exist_ok=True)
    TARGETS[args.package].write_text(output + ("" if output.endswith("\n") else "\n"), encoding="utf-8")
    print(f"updated reviewed compatibility baseline: {TARGETS[args.package].relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
