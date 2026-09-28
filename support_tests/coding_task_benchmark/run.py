#!/usr/bin/env python3
"""Run the fixed coding-task corpus through explicit variant executors.

Each selected executable receives one JSON task request on stdin, modifies only
its per-sample workspace, and returns measured model/tool/program counters as
JSON on stdout. The runner never receives the corpus answer-key operations or
test assertions.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import signal
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath
from typing import Any

ROOT = Path(__file__).resolve().parent
CORPUS_PATH = ROOT / "corpus.json"
VARIANTS = ("native", "ptc")


class BenchmarkError(RuntimeError):
    pass


def json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def timeout_text(value: str | bytes | None) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value or ""


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def safe_relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        raise BenchmarkError(f"unsafe corpus path: {value!r}")
    return path


def workspace_path(workspace: Path, value: str) -> Path:
    relative = safe_relative_path(value)
    target = workspace.joinpath(*relative.parts)
    current = workspace
    for part in relative.parts[:-1]:
        current = current / part
        if current.is_symlink():
            raise BenchmarkError(f"symlink parent is forbidden: {value}")
    return target


def file_manifest(files: dict[str, str]) -> dict[str, Any]:
    entries = []
    for path, content in sorted(files.items()):
        encoded = content.encode("utf-8")
        entries.append({"path": path, "bytes": len(encoded), "sha256": sha256_bytes(encoded)})
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {"files": entries, "digest": sha256_bytes(canonical)}


def read_workspace(workspace: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for path in sorted(workspace.rglob("*")):
        if path.is_symlink():
            raise BenchmarkError(f"workspace contains symlink: {path.relative_to(workspace)}")
        if path.is_file():
            relative = path.relative_to(workspace).as_posix()
            values[relative] = path.read_text(encoding="utf-8")
    return values


def unified_diff(before: dict[str, str], after: dict[str, str]) -> str:
    output: list[str] = []
    for path in sorted(set(before) | set(after)):
        old = before.get(path, "").splitlines(keepends=True)
        new = after.get(path, "").splitlines(keepends=True)
        if old == new:
            continue
        output.extend(difflib.unified_diff(old, new, fromfile=f"a/{path}", tofile=f"b/{path}"))
    return "".join(output)


def changed_file_evidence(before: dict[str, str], after: dict[str, str]) -> list[dict[str, Any]]:
    evidence: list[dict[str, Any]] = []
    for sequence, path in enumerate(sorted(set(before) | set(after)), start=1):
        old = before.get(path)
        new = after.get(path)
        if old == new:
            continue
        evidence.append(
            {
                "sequence": sequence,
                "operation": "delete" if new is None else ("create" if old is None else "replace"),
                "path": path,
                "content_sha256": None if new is None else sha256_bytes(new.encode("utf-8")),
            }
        )
    return evidence


def nonnegative_counter(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise BenchmarkError(f"runner field {name} must be a non-negative integer")
    return value


def execute_variant(
    runner: Path, runner_sha256: str, corpus: dict[str, Any], task: dict[str, Any],
    variant: str, artifact: Path
) -> dict[str, Any]:
    program = task.get("program") if variant == "ptc" else None
    request = {
        "schema_version": 1,
        "variant": variant,
        "task": {
            "id": task["id"],
            "category": task["category"],
            "instruction": task["instruction"],
            "program": program,
        },
        "workspace": ".",
        "model": corpus["model"],
        "budget": corpus["budget"],
        "allowed_tools": corpus["allowed_tools"],
    }
    started = time.perf_counter_ns()
    process = subprocess.Popen(
        [str(runner)],
        cwd=artifact / "workspace",
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    try:
        stdout, stderr = process.communicate(
            input=json.dumps(request, sort_keys=True),
            timeout=float(corpus["budget"]["wall_time_millis"]) / 1000,
        )
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        (artifact / "runner.stdout").write_text(timeout_text(stdout), encoding="utf-8")
        (artifact / "runner.stderr").write_text(timeout_text(stderr), encoding="utf-8")
        raise BenchmarkError(f"{variant} runner timed out") from error
    (artifact / "runner.stdout").write_text(stdout, encoding="utf-8")
    (artifact / "runner.stderr").write_text(stderr, encoding="utf-8")
    if process.returncode != 0:
        raise BenchmarkError(f"{variant} runner exited with {process.returncode}")
    try:
        response = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise BenchmarkError(f"{variant} runner did not emit one JSON result") from error
    if not isinstance(response, dict) or response.get("schema_version") != 1:
        raise BenchmarkError(f"{variant} runner returned an unsupported result schema")
    if not isinstance(response.get("runner"), str) or not response["runner"].strip():
        raise BenchmarkError(f"{variant} runner identity is required")
    if response.get("model") != corpus["model"]:
        raise BenchmarkError(f"{variant} runner model evidence differs from the requested model")
    usage = response.get("model_usage")
    if not isinstance(usage, dict) or not isinstance(usage.get("source"), str):
        raise BenchmarkError(f"{variant} runner model usage evidence is required")
    counters = {}
    for name in (
        "model_requests", "tool_calls", "program_invocations", "retries",
        "failure_repair_attempts", "summaries", "subtasks", "human_interventions",
    ):
        counters[name] = nonnegative_counter(response.get(name), name)
    for name in ("model_requests", "tool_calls"):
        ceiling = nonnegative_counter(corpus["budget"].get(name), f"budget.{name}")
        if counters[name] > ceiling:
            raise BenchmarkError(
                f"{variant} runner exceeded {name} budget: {counters[name]} > {ceiling}"
            )
    if variant == "native" and counters["program_invocations"] != 0:
        raise BenchmarkError("native runner must not report a program invocation")
    if program is not None and counters["program_invocations"] < 1:
        raise BenchmarkError("PTC runner did not execute the task's declared program")
    if program is None and counters["program_invocations"] != 0:
        raise BenchmarkError("runner reported a program invocation for a task without a program")
    response["duration_millis"] = (time.perf_counter_ns() - started) / 1_000_000
    response["counters"] = counters
    response["runner_sha256"] = runner_sha256
    return response


def run_tests(workspace: Path, tests: list[dict[str, Any]], artifact: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for test in tests:
        argv = [str(value) for value in test["argv"]]
        started = time.perf_counter_ns()
        process = subprocess.Popen(
            argv,
            cwd=workspace,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        try:
            stdout, stderr = process.communicate(timeout=10)
            result = {
                "name": test["name"],
                "argv": argv,
                "exit_code": process.returncode,
                "duration_millis": (time.perf_counter_ns() - started) / 1_000_000,
                "passed": process.returncode == 0,
                "stdout": stdout,
                "stderr": stderr,
            }
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
            result = {
                "name": test["name"],
                "argv": argv,
                "exit_code": None,
                "duration_millis": (time.perf_counter_ns() - started) / 1_000_000,
                "passed": False,
                "stdout": timeout_text(stdout),
                "stderr": timeout_text(stderr),
                "error": "timeout",
            }
        results.append(result)
    json_write(artifact / "tests.json", results)
    return results


def execute_task(
    corpus: dict[str, Any], task: dict[str, Any], variant: str, repeat: int,
    runner: Path, runner_sha256: str, artifact: Path
) -> dict[str, Any]:
    workspace = artifact / "workspace"
    workspace.mkdir(parents=True)
    initial_files = {str(path): str(content) for path, content in task["initial_files"].items()}
    for relative, content in initial_files.items():
        target = workspace_path(workspace, relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    initial = file_manifest(initial_files)
    json_write(artifact / "initial_state.json", initial)

    started = time.perf_counter_ns()
    failure = ""
    tests: list[dict[str, Any]] = []
    execution: dict[str, Any] = {
        "runner": "unavailable",
        "runner_sha256": runner_sha256,
        "model": None,
        "model_usage": {"source": "unavailable"},
        "counters": {
            "model_requests": 0,
            "tool_calls": 0,
            "program_invocations": 0,
            "retries": 0,
            "failure_repair_attempts": 0,
            "summaries": 0,
            "subtasks": 0,
            "human_interventions": 0,
        },
    }
    try:
        execution = execute_variant(runner, runner_sha256, corpus, task, variant, artifact)
    except Exception as error:  # evidence path must survive a runner failure
        failure = f"{type(error).__name__}: {error}"
    try:
        tests = run_tests(workspace, task["tests"], artifact)
    except Exception as error:  # preserve runner and workspace evidence
        failure = failure or f"{type(error).__name__}: {error}"
        json_write(artifact / "tests.json", tests)
    duration_millis = (time.perf_counter_ns() - started) / 1_000_000

    final_files = read_workspace(workspace)
    final = file_manifest(final_files)
    diff = unified_diff(initial_files, final_files)
    file_changes = changed_file_evidence(initial_files, final_files)
    (artifact / "final.diff").write_text(diff, encoding="utf-8")
    json_write(artifact / "final_state.json", final)
    declared_paths = {str(item["path"]) for item in task["operations"]}
    unexpected_paths = sorted(
        str(change["path"]) for change in file_changes if str(change["path"]) not in declared_paths
    )
    safety_passed = not unexpected_paths
    tests_passed = bool(tests) and all(item["passed"] for item in tests)
    succeeded = failure == "" and safety_passed and tests_passed
    failure_summary = failure or (
        "test_failure" if not tests_passed else ("safety_violation" if not safety_passed else None)
    )

    program = task.get("program") if variant == "ptc" else None
    counters = execution["counters"]
    program_executed = counters["program_invocations"] > 0
    result = {
        "schema_version": 1,
        "task_id": task["id"],
        "category": task["category"],
        "variant": variant,
        "repeat": repeat,
        "success": succeeded,
        "success_authority": "fixture assertions and process exit codes; model self-assessment is ignored",
        "failure": failure_summary,
        "safety": {"passed": safety_passed, "unexpected_paths": unexpected_paths},
        "duration_millis": duration_millis,
        "runner": {
            "identity": execution["runner"],
            "sha256": execution["runner_sha256"],
        },
        "requested_model": corpus["model"],
        "model": execution["model"],
        "budget": corpus["budget"],
        "allowed_tools": corpus["allowed_tools"],
        "initial_state": initial,
        "final_state": final,
        "final_diff_sha256": sha256_bytes(diff.encode("utf-8")),
        "tests": tests,
        "file_changes": file_changes,
        "cost": {
            "model_requests": counters["model_requests"],
            "model_usage": execution["model_usage"],
            "tool_calls": counters["tool_calls"],
            "program_invocations": counters["program_invocations"],
            "program_sdk": program["sdk"] if program_executed and program else None,
            "program_source_sha256": (
                sha256_bytes(program["source"].encode("utf-8"))
                if program_executed and program else None
            ),
            "program_execution": "runner_reported" if program_executed else None,
            "retries": counters["retries"],
            "failure_repair_attempts": counters["failure_repair_attempts"],
            "summaries": counters["summaries"],
            "subtasks": counters["subtasks"],
            "human_interventions": counters["human_interventions"],
        },
        "cancellation": "not_injected",
        "recovery": "not_injected",
    }
    json_write(artifact / "result.json", result)
    return result


def distribution(values: list[float]) -> dict[str, Any]:
    if not values:
        return {"samples": 0, "minimum": None, "median": None, "maximum": None, "spread": None, "pstdev": None}
    return {
        "samples": len(values),
        "minimum": min(values),
        "median": statistics.median(values),
        "maximum": max(values),
        "spread": max(values) - min(values),
        "pstdev": statistics.pstdev(values),
    }


def summarize(results: list[dict[str, Any]], variants: list[str], repeat: int) -> dict[str, Any]:
    by_variant: dict[str, Any] = {}
    for variant in variants:
        selected = [item for item in results if item["variant"] == variant]
        by_task: dict[str, Any] = {}
        for task_id in sorted({item["task_id"] for item in selected}):
            samples = [item for item in selected if item["task_id"] == task_id]
            by_task[task_id] = {
                "samples": len(samples),
                "successes": sum(bool(item["success"]) for item in samples),
                "failures": [item["failure"] for item in samples if not item["success"]],
                "duration_millis": distribution([float(item["duration_millis"]) for item in samples]),
                "human_interventions": sum(int(item["cost"]["human_interventions"]) for item in samples),
                "model_requests": sum(int(item["cost"]["model_requests"]) for item in samples),
                "tool_calls": sum(int(item["cost"]["tool_calls"]) for item in samples),
                "program_invocations": sum(int(item["cost"]["program_invocations"]) for item in samples),
                "retries": sum(int(item["cost"]["retries"]) for item in samples),
                "failure_repair_attempts": sum(int(item["cost"]["failure_repair_attempts"]) for item in samples),
                "summaries": sum(int(item["cost"]["summaries"]) for item in samples),
                "subtasks": sum(int(item["cost"]["subtasks"]) for item in samples),
                "unknown_usage_samples": sum(item["cost"]["model_usage"]["source"] == "unknown" for item in samples),
            }
        by_variant[variant] = {
            "samples": len(selected),
            "successes": sum(bool(item["success"]) for item in selected),
            "failures": len(selected) - sum(bool(item["success"]) for item in selected),
            "duration_millis": distribution([float(item["duration_millis"]) for item in selected]),
            "model_requests": sum(int(item["cost"]["model_requests"]) for item in selected),
            "tool_calls": sum(int(item["cost"]["tool_calls"]) for item in selected),
            "program_invocations": sum(int(item["cost"]["program_invocations"]) for item in selected),
            "retries": sum(int(item["cost"]["retries"]) for item in selected),
            "failure_repair_attempts": sum(int(item["cost"]["failure_repair_attempts"]) for item in selected),
            "summaries": sum(int(item["cost"]["summaries"]) for item in selected),
            "subtasks": sum(int(item["cost"]["subtasks"]) for item in selected),
            "human_interventions": sum(int(item["cost"]["human_interventions"]) for item in selected),
            "tasks": by_task,
        }

    comparisons: dict[str, Any] = {}
    if set(variants) == set(VARIANTS):
        task_ids = sorted({item["task_id"] for item in results})
        for task_id in task_ids:
            native = [item for item in results if item["task_id"] == task_id and item["variant"] == "native"]
            ptc = [item for item in results if item["task_id"] == task_id and item["variant"] == "ptc"]
            native_duration = distribution([float(item["duration_millis"]) for item in native])
            ptc_duration = distribution([float(item["duration_millis"]) for item in ptc])
            comparisons[task_id] = {
                "native_samples": len(native),
                "ptc_samples": len(ptc),
                "native_successes": sum(bool(item["success"]) for item in native),
                "ptc_successes": sum(bool(item["success"]) for item in ptc),
                "median_duration_delta_millis": (
                    float(ptc_duration["median"]) - float(native_duration["median"])
                    if native_duration["median"] is not None and ptc_duration["median"] is not None
                    else None
                ),
                "claim": "raw repeated fixture evidence only; no performance or token-saving percentage is inferred",
            }
    return {
        "schema_version": 1,
        "corpus_snapshot": "fixed corpus identified by snapshot_id and corpus_sha256",
        "repeat": repeat,
        "variants": by_variant,
        "comparisons": comparisons,
        "timing_scope": "external variant runner plus deterministic fixture assertions; not a Provider performance claim",
        "admission": {
            "correctness_gate_passed": all(bool(item["success"]) for item in results),
            "safety_gate_passed": all(bool(item["safety"]["passed"]) for item in results),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new output directory")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--variants", default="native,ptc")
    parser.add_argument("--native-runner", type=Path)
    parser.add_argument("--ptc-runner", type=Path)
    return parser.parse_args()


def validated_runner(value: Path | None, variant: str) -> Path:
    if value is None:
        raise BenchmarkError(f"--{variant}-runner is required when {variant} is selected")
    runner = value.resolve()
    if not runner.is_file() or not os.access(runner, os.X_OK):
        raise BenchmarkError(f"--{variant}-runner must name an executable regular file")
    return runner

def freeze_runner(source: Path, variant: str, output: Path, digest: str) -> Path:
    destination = output / "runners" / f"{variant}-runner"
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copy2(source, destination, follow_symlinks=True)
    except OSError as error:
        raise BenchmarkError(f"cannot snapshot {variant} runner: {error}") from error
    if not os.access(destination, os.X_OK) or sha256_bytes(destination.read_bytes()) != digest:
        raise BenchmarkError(f"{variant} runner snapshot identity mismatch")
    return destination

def main() -> int:
    args = parse_args()
    if args.repeat < 2:
        raise BenchmarkError("--repeat must be at least 2 for dispersion evidence")
    variants = [value.strip() for value in args.variants.split(",") if value.strip()]
    if not variants or any(value not in VARIANTS for value in variants) or len(set(variants)) != len(variants):
        raise BenchmarkError("--variants must contain unique native and/or ptc values")
    source_runners = {
        variant: validated_runner(getattr(args, f"{variant}_runner"), variant)
        for variant in variants
    }
    runner_digests = {
        variant: sha256_bytes(runner.read_bytes()) for variant, runner in source_runners.items()
    }
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise BenchmarkError("--output must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)
    corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
    runners = {
        variant: freeze_runner(source_runners[variant], variant, output, runner_digests[variant])
        for variant in variants
    }
    categories = {str(task["category"]) for task in corpus["tasks"]}
    required = {
        "local_fix",
        "cross_file_change",
        "ci_diagnosis",
        "api_documentation",
        "behavior_preserving_refactor",
        "read_aggregation",
    }
    if categories != required:
        raise BenchmarkError(f"corpus categories differ: {sorted(categories)}")
    corpus_digest = sha256_bytes(CORPUS_PATH.read_bytes())
    json_write(
        output / "run.json",
        {
            "schema_version": 1,
            "corpus": CORPUS_PATH.name,
            "corpus_sha256": corpus_digest,
            "snapshot_id": corpus["snapshot_id"],
            "repeat": args.repeat,
            "variants": {
                variant: {
                    "artifact": f"runners/{variant}-runner",
                    "runner_sha256": runner_digests[variant],
                }
                for variant in variants
            },
        },
    )
    results: list[dict[str, Any]] = []
    for variant in variants:
        for repeat in range(1, args.repeat + 1):
            for task in corpus["tasks"]:
                artifact = output / "runs" / variant / f"repeat-{repeat:02d}" / str(task["id"])
                results.append(execute_task(
                    corpus, task, variant, repeat, runners[variant], runner_digests[variant], artifact
                ))
    report = summarize(results, variants, args.repeat)
    report["corpus_sha256"] = corpus_digest
    report["snapshot_id"] = corpus["snapshot_id"]
    report["total_samples"] = len(results)
    report["failed_samples"] = sum(not item["success"] for item in results)
    json_write(output / "report.json", report)
    print(
        f"CODING_TASK_BENCHMARK_READY samples={len(results)} "
        f"failed={report['failed_samples']} output={output}"
    )
    return 0 if report["failed_samples"] == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"coding task benchmark blocked: {error}", file=sys.stderr)
        raise SystemExit(2)
