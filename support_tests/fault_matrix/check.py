#!/usr/bin/env python3
"""Run the issue-36 fault matrix through real executable contract entrypoints."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
MATRIX_PATH = Path(__file__).with_name("matrix.json")
SUITES = {
    "agent_store_contract": "agent store contract passed",
    "artifact_contract": "artifact contract passed",
    "direct_runtime_sandbox_contract": "direct runtime sandbox contract passed",
    "extension_runtime_contract": "extension manifest/runtime contract passed",
    "product_contract": "product contract passed",
    "extensions_contract": "agent SDK extension authority contract passed",
    "product_thread_runtime_contract": "product Thread Runtime contract passed",
    "sqlite_run_repository_contract": "SQLite Run repository contract passed",
    "tool_runtime_contract": "tool_runtime contract passed",
}


class MatrixError(RuntimeError):
    pass


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_matrix() -> dict[str, Any]:
    value = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
    rows = value.get("rows")
    if value.get("schema") != "axyndra-fault-matrix/v1" or not isinstance(rows, list):
        raise MatrixError("invalid fault matrix schema")
    ids = [row.get("id") for row in rows]
    if len(rows) != 14 or len(set(ids)) != 14 or ids != [f"F{index:02d}" for index in range(1, 15)]:
        raise MatrixError("fault matrix must contain exactly ordered F01-F14 rows")
    for row in rows:
        evidence = row.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            raise MatrixError(f"{row['id']} has no executable evidence")
        for item in evidence:
            suite = item.get("suite")
            if suite not in SUITES:
                raise MatrixError(f"{row['id']} references unknown suite {suite!r}")
            source = ROOT / str(item.get("source", ""))
            anchor = str(item.get("anchor", ""))
            if not source.is_file() or not anchor or anchor not in source.read_text(encoding="utf-8"):
                raise MatrixError(f"{row['id']} evidence anchor is missing: {source}:{anchor}")
    return value


def run_suite(suite: str, output: Path, timeout: int) -> dict[str, Any]:
    suite_dir = ROOT / "support_tests" / suite
    log_path = output / "logs" / f"{suite}.log"
    target = output / "targets" / suite
    log_path.parent.mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    command = [str(ROOT / "scripts" / "pinned_cangjie"), "cjpm", "run"]
    environment = dict(os.environ)
    environment.setdefault("AXYNDRA_SDK_ROOT", str(Path.home() / "cangjie_sdk" / "daily"))
    environment["CJPM_TARGET_DIR"] = str(target)
    environment["TMPDIR"] = str(output / "tmp")
    environment["TMP"] = environment["TMPDIR"]
    environment["TEMP"] = environment["TMPDIR"]
    Path(environment["TMPDIR"]).mkdir(parents=True, exist_ok=True)
    started = time.perf_counter_ns()
    timed_out = False
    exit_code: int | None
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            command,
            cwd=suite_dir,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            exit_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            exit_code = None
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            log.write(f"\nFAULT_MATRIX_TIMEOUT seconds={timeout}\n".encode())
    elapsed = (time.perf_counter_ns() - started) / 1_000_000
    text = log_path.read_text(encoding="utf-8", errors="replace")
    marker = SUITES[suite]
    passed = exit_code == 0 and marker in text and not timed_out
    return {
        "suite": suite,
        "command": {
            "cwd": f"support_tests/{suite}",
            "argv": ["../../scripts/pinned_cangjie", "cjpm", "run"],
        },
        "exit_code": exit_code,
        "timed_out": timed_out,
        "duration_millis": elapsed,
        "semantic_marker": marker,
        "semantic_marker_observed": marker in text,
        "passed": passed,
        "log": f"logs/{suite}.log",
        "log_sha256": sha256(log_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new evidence directory")
    parser.add_argument("--jobs", type=int, default=3, help="parallel executable contracts")
    parser.add_argument("--timeout", type=int, default=1200, help="seconds per executable contract")
    arguments = parser.parse_args()
    if arguments.jobs < 1 or arguments.timeout < 1:
        raise MatrixError("jobs and timeout must be positive")
    output = arguments.output.resolve()
    if output.exists():
        raise MatrixError(f"output already exists: {output}")
    output.mkdir(parents=True)

    matrix = load_matrix()
    suites = sorted({item["suite"] for row in matrix["rows"] for item in row["evidence"]})
    results: dict[str, dict[str, Any]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(arguments.jobs, len(suites))) as executor:
        pending = {
            executor.submit(run_suite, suite, output, arguments.timeout): suite for suite in suites
        }
        for future in concurrent.futures.as_completed(pending):
            suite = pending[future]
            try:
                results[suite] = future.result()
            except Exception as error:
                results[suite] = {
                    "suite": suite,
                    "passed": False,
                    "error": f"{type(error).__name__}: {error}",
                    "log": f"logs/{suite}.log",
                }

    rows: list[dict[str, Any]] = []
    for row in matrix["rows"]:
        row_suites = sorted({item["suite"] for item in row["evidence"]})
        passed = all(results[suite].get("passed") is True for suite in row_suites)
        rows.append(
            {
                "id": row["id"],
                "fault": row["fault"],
                "expected": row["expected"],
                "actual": (
                    "all named process contracts exited successfully and reached their semantic pass markers"
                    if passed
                    else "one or more named process contracts failed or did not reach a semantic pass marker"
                ),
                "passed": passed,
                "evidence": row["evidence"],
                "suite_results": [
                    {
                        "suite": suite,
                        "passed": results[suite].get("passed", False),
                        "exit_code": results[suite].get("exit_code"),
                        "semantic_marker_observed": results[suite].get("semantic_marker_observed", False),
                        "log": results[suite].get("log"),
                        "log_sha256": results[suite].get("log_sha256"),
                    }
                    for suite in row_suites
                ],
            }
        )

    passed_rows = sum(1 for row in rows if row["passed"])
    report = {
        "schema": "axyndra-fault-matrix-report/v1",
        "matrix_sha256": sha256(MATRIX_PATH),
        "process_boundary": "Each suite is launched as a separate executable through pinned_cangjie/cjpm.",
        "environment": {
            "credentials_required": False,
            "paid_provider_required": False,
            "external_service_required": False,
            "workspace": "isolated temporary directories owned by each executable contract",
        },
        "summary": {
            "rows": len(rows),
            "passed": passed_rows,
            "failed": len(rows) - passed_rows,
            "suites": len(suites),
        },
        "rows": rows,
        "suites": [results[suite] for suite in suites],
    }
    write_json(output / "report.json", report)
    shutil.rmtree(output / "tmp", ignore_errors=True)
    print(
        f"FAULT_MATRIX_READY rows={len(rows)} passed={passed_rows} "
        f"failed={len(rows) - passed_rows} suites={len(suites)}"
    )
    return 0 if passed_rows == len(rows) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MatrixError as error:
        print(f"fault matrix error: {error}", file=sys.stderr)
        raise SystemExit(2)
