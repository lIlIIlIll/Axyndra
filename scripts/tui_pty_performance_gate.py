#!/usr/bin/env python3
"""Run the instrumented PTY journey and enforce latency/output regressions."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


LIMITS = {
    "cold_start/10000": {"first_frame_wall_ms.p95": 650.0},
    "key_repeat/10000": {
        "total_ms.p95": 30.0,
        "total_ms.max": 60.0,
        "event_queue_length.max": 120.0,
    },
    "stream/10000": {"total_ms.p95": 80.0, "total_ms.max": 120.0},
    "search/10000": {"total_ms.p95": 30.0, "total_ms.max": 60.0},
    "resize/10000": {
        "total_ms.p95": 80.0,
        "total_ms.max": 120.0,
        "write_calls.max": 1.0,
    },
}


def value_at(record: dict, dotted: str) -> float:
    value: object = record
    for part in dotted.split("."):
        if not isinstance(value, dict) or part not in value:
            raise KeyError(dotted)
        value = value[part]
    return float(value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--candidate",
        default="scripts/pinned_cangjie target/release/bin/agent_app --fixture",
    )
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=12.0)
    parser.add_argument("--keep-output", type=Path)
    args = parser.parse_args()
    if args.runs <= 0:
        raise SystemExit("--runs must be positive")

    root = Path(__file__).resolve().parents[1]
    temporary = tempfile.TemporaryDirectory(prefix="axyndra-tui-pty-gate-")
    output = args.keep_output or Path(temporary.name)
    command = [
        "python3",
        str(root / "scripts/tui_pty_bench.py"),
        "--candidate",
        args.candidate,
        "--output",
        str(output),
        "--scenarios",
        "cold_start,key_repeat,stream,search,resize",
        "--data-counts",
        "10000",
        "--runs",
        str(args.runs),
        "--stream-chunks",
        "100",
        "--timeout",
        str(args.timeout),
    ]
    environment = os.environ.copy()
    subprocess.run(command, cwd=root, env=environment, check=True)
    summaries = json.loads((output / "summary.json").read_text())["summaries"]

    failures: list[str] = []
    for scenario, limits in LIMITS.items():
        record = summaries[scenario]
        if record.get("active_stall_count", 0) != 0:
            failures.append(
                f"{scenario} active stalls={record['active_stall_count']} expected=0"
            )
        for metric, limit in limits.items():
            actual = value_at(record, metric)
            if actual > limit:
                failures.append(
                    f"{scenario} {metric}={actual:.2f} exceeds {limit:.2f}"
                )

    if failures:
        raise SystemExit("TUI PTY performance gate failed:\n" + "\n".join(failures))
    print("TUI PTY performance gate passed")
    for scenario in LIMITS:
        record = summaries[scenario]
        metric = "first_frame_wall_ms" if scenario.startswith("cold_start") else "total_ms"
        print(
            f"  {scenario}: p50={record[metric]['p50']:.2f}ms "
            f"p95={record[metric]['p95']:.2f}ms "
            f"p99={record[metric]['p99']:.2f}ms max={record[metric]['max']:.2f}ms"
        )
    temporary.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
