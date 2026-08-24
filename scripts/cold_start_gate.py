#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import subprocess
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--runs", type=int, default=100)
    parser.add_argument("--diagnostics", required=True)
    args = parser.parse_args()

    diagnostics = Path(args.diagnostics)
    diagnostics.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.pop("LD_LIBRARY_PATH", None)
    samples = []
    for index in range(args.runs):
        started = time.perf_counter()
        completed = subprocess.run(
            [args.candidate, "--version"],
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        samples.append((time.perf_counter() - started) * 1000.0)
        if completed.returncode != 0 or completed.stdout.strip() != "axyndra/17.2.3":
            (diagnostics / f"cold-start-{index:03d}.log").write_text(
                f"exit={completed.returncode}\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
                encoding="utf-8",
            )
            raise SystemExit(f"cold start {index + 1} failed")
    (diagnostics / "cold-start.txt").write_text(
        "\n".join(f"{sample:.3f}" for sample in samples) + "\n",
        encoding="utf-8",
    )
    print(f"cold-start gate passed ({args.runs} runs, max={max(samples):.1f}ms)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
