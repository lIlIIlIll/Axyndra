#!/usr/bin/env python3
"""Low-variance startup/RPC latency comparison against pinned OMP."""

from __future__ import annotations

import argparse
import os
import shlex
import statistics
import subprocess
import time


def first_frame(command: str, samples: int) -> list[float]:
    values: list[float] = []
    for _ in range(samples):
        started = time.monotonic()
        process = subprocess.Popen(
            [*shlex.split(command), "--mode", "rpc"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=os.environ.copy(),
        )
        assert process.stdout is not None
        assert process.stdin is not None
        process.stdin.write('{"id":"perf","type":"get_state"}\n')
        process.stdin.flush()
        process.stdin.close()
        line = process.stdout.readline()
        elapsed = (time.monotonic() - started) * 1000
        if '"type":"ready"' not in line:
            error = process.stderr.read() if process.stderr else ""
            process.kill()
            raise SystemExit(
                f"RPC process did not emit ready: {line!r}\n{error}"
            )
        # This gate measures readiness only. OMP emits a large command catalog
        # immediately after ready, so waiting without draining stdout can fill
        # the pipe and deadlock. Stop the isolated sample once the timestamp is
        # captured.
        process.kill()
        process.wait(timeout=10)
        process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        values.append(elapsed)
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    baseline = first_frame(args.baseline, args.samples)
    candidate = first_frame(args.candidate, args.samples)
    baseline_median = statistics.median(baseline)
    candidate_median = statistics.median(candidate)
    limit = baseline_median * 1.5
    print(
        "RPC first-frame median: "
        f"OMP={baseline_median:.1f}ms "
        f"axyndra={candidate_median:.1f}ms "
        f"limit={limit:.1f}ms"
    )
    if candidate_median > limit:
        raise SystemExit("RPC first-frame latency exceeds the 1.5x gate")


if __name__ == "__main__":
    main()
