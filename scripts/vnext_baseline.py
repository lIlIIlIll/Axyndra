#!/usr/bin/env python3
"""Collect reproducible command baselines for the axyndra vNext migration.

The collector deliberately records observations without enforcing performance
thresholds. A JSON manifest describes isolated commands; the output preserves
raw samples and summary percentiles so later phases can compare like with like.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time
from typing import Any


FORMAT_VERSION = 1


def percentile(samples: list[float], fraction: float) -> float:
    if not samples:
        raise ValueError("percentile requires at least one sample")
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, int(len(ordered) * fraction)))
    return ordered[index]


def load_manifest(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("version") != FORMAT_VERSION:
        raise ValueError(
            f"unsupported manifest version {value.get('version')!r}; "
            f"expected {FORMAT_VERSION}"
        )
    benchmarks = value.get("benchmarks")
    if not isinstance(benchmarks, list) or not benchmarks:
        raise ValueError("manifest benchmarks must be a non-empty array")
    names: set[str] = set()
    for benchmark in benchmarks:
        if not isinstance(benchmark, dict):
            raise ValueError("each benchmark must be an object")
        name = benchmark.get("name")
        command = benchmark.get("command")
        if not isinstance(name, str) or not name:
            raise ValueError("benchmark name must be a non-empty string")
        if name in names:
            raise ValueError(f"duplicate benchmark name: {name}")
        names.add(name)
        if (
            not isinstance(command, list)
            or not command
            or not all(isinstance(item, str) and item for item in command)
        ):
            raise ValueError(f"benchmark {name} command must be a string array")
        for field in ("samples", "warmups"):
            field_value = benchmark.get(field, 0 if field == "warmups" else 1)
            if not isinstance(field_value, int) or field_value < 0:
                raise ValueError(f"benchmark {name} {field} must be non-negative")
        if benchmark.get("samples", 1) <= 0:
            raise ValueError(f"benchmark {name} samples must be positive")
    return value


def run_once(
    benchmark: dict[str, Any],
    *,
    repo_root: Path,
    state_root: Path | None,
) -> tuple[float, subprocess.CompletedProcess[str]]:
    environment = os.environ.copy()
    environment.pop("LD_LIBRARY_PATH", None)
    for name, value in benchmark.get("env", {}).items():
        if not isinstance(name, str) or not isinstance(value, str):
            raise ValueError(f"benchmark {benchmark['name']} env must map strings")
        environment[name] = value
    if state_root is not None:
        environment["AXYNDRA_HOME"] = str(state_root)

    cwd_value = benchmark.get("cwd")
    cwd = repo_root if cwd_value is None else (repo_root / cwd_value).resolve()
    timeout = float(benchmark.get("timeout_seconds", 30.0))
    if timeout <= 0:
        raise ValueError(f"benchmark {benchmark['name']} timeout must be positive")

    started = time.perf_counter()
    completed = subprocess.run(
        benchmark["command"],
        cwd=cwd,
        env=environment,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    return elapsed_ms, completed


def assert_expected(
    benchmark: dict[str, Any], completed: subprocess.CompletedProcess[str]
) -> None:
    expected = benchmark.get("expect", {})
    exit_code = expected.get("exit_code", 0)
    if completed.returncode != exit_code:
        raise RuntimeError(
            f"expected exit {exit_code}, got {completed.returncode}"
        )
    stdout_contains = expected.get("stdout_contains")
    if stdout_contains is not None and stdout_contains not in completed.stdout:
        raise RuntimeError(f"stdout does not contain {stdout_contains!r}")
    stderr_contains = expected.get("stderr_contains")
    if stderr_contains is not None and stderr_contains not in completed.stderr:
        raise RuntimeError(f"stderr does not contain {stderr_contains!r}")


def collect_benchmark(
    benchmark: dict[str, Any], *, repo_root: Path
) -> dict[str, Any]:
    samples: list[float] = []
    isolate_home = bool(benchmark.get("isolate_home", True))
    warmups = benchmark.get("warmups", 0)
    sample_count = benchmark.get("samples", 1)
    last_stdout = ""
    last_stderr = ""

    for index in range(warmups + sample_count):
        if isolate_home:
            with tempfile.TemporaryDirectory(
                prefix=f"axyndra-vnext-{benchmark['name']}-"
            ) as temporary_home:
                elapsed_ms, completed = run_once(
                    benchmark,
                    repo_root=repo_root,
                    state_root=Path(temporary_home),
                )
        else:
            elapsed_ms, completed = run_once(
                benchmark, repo_root=repo_root, state_root=None
            )
        try:
            assert_expected(benchmark, completed)
        except RuntimeError as error:
            raise RuntimeError(
                f"benchmark {benchmark['name']} iteration {index + 1} failed: "
                f"{error}\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            ) from error
        last_stdout = completed.stdout
        last_stderr = completed.stderr
        if index >= warmups:
            samples.append(elapsed_ms)

    return {
        "name": benchmark["name"],
        "command": benchmark["command"],
        "cwd": benchmark.get("cwd", "."),
        "isolate_home": isolate_home,
        "warmups": warmups,
        "sample_count": sample_count,
        "samples_ms": [round(value, 3) for value in samples],
        "p50_ms": round(statistics.median(samples), 3),
        "p95_ms": round(percentile(samples, 0.95), 3),
        "p99_ms": round(percentile(samples, 0.99), 3),
        "max_ms": round(max(samples), 3),
        "last_stdout": last_stdout,
        "last_stderr": last_stderr,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    args = parser.parse_args()

    try:
        manifest = load_manifest(args.manifest)
        repo_root = args.repo_root.resolve()
        results = [
            collect_benchmark(benchmark, repo_root=repo_root)
            for benchmark in manifest["benchmarks"]
        ]
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"vNext baseline failed: {error}")
        return 1

    output = {
        "version": FORMAT_VERSION,
        "candidate": manifest.get("candidate", "unspecified"),
        "created_at_unix_ms": int(time.time() * 1000),
        "benchmarks": results,
        "unavailable": manifest.get("unavailable", []),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    for result in results:
        print(
            f"{result['name']}: p50={result['p50_ms']:.3f}ms "
            f"p95={result['p95_ms']:.3f}ms p99={result['p99_ms']:.3f}ms "
            f"max={result['max_ms']:.3f}ms"
        )
    print(f"vNext baseline written to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

