#!/usr/bin/env python3

import argparse
import os
import pathlib
import shlex
import signal
import statistics
import subprocess
import tempfile
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--runs", type=int, default=12)
    parser.add_argument("--p95-ms", type=float, default=500.0)
    parser.add_argument("--timeout-s", type=float, default=15.0)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    command = shlex.split(args.candidate)
    if not command:
        raise SystemExit("candidate command is empty")
    if args.runs <= 0:
        raise SystemExit("--runs must be positive")
    if args.timeout_s <= 0:
        raise SystemExit("--timeout-s must be positive")
    samples = []
    for run_index in range(args.runs):
        # Fixture state must not leak between samples.  A stale interactive
        # fixture process or a previous session can otherwise turn a render
        # benchmark into a lock/contention benchmark.
        with tempfile.TemporaryDirectory(prefix="axyndra-tui-perf-") as state_root:
            environment = os.environ.copy()
            environment["AGENT_TUI_HEADLESS"] = "1"
            environment["AGENT_TUI_HEADLESS_PERF"] = "1"
            environment["AXYNDRA_HOME"] = state_root
            started = time.perf_counter()
            process = subprocess.Popen(
                command,
                cwd=root,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            try:
                return_code = process.wait(timeout=args.timeout_s)
            except subprocess.TimeoutExpired as error:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                finally:
                    process.wait()
                raise SystemExit(
                    f"TUI journey run {run_index + 1} timed out after "
                    f"{args.timeout_s:.1f}s"
                ) from error
            elapsed = (time.perf_counter() - started) * 1000.0
            if return_code != 0:
                raise SystemExit(
                    f"TUI journey run {run_index + 1} exited with "
                    f"status {return_code}"
                )
            samples.append(elapsed)
    ordered = sorted(samples)
    p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
    if p95 > args.p95_ms:
        raise SystemExit(
            f"TUI journey p95 {p95:.1f}ms exceeds {args.p95_ms:.1f}ms"
        )
    print(
        "tui performance gate passed "
        f"(p50={statistics.median(samples):.1f}ms p95={p95:.1f}ms)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
