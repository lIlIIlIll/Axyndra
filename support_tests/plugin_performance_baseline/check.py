#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

PACKAGE_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = PACKAGE_ROOT.parents[1]
FIXTURE_ROOT = REPOSITORY_ROOT / "support_tests" / "extension_runtime_contract" / "fixtures"
CANDIDATE = Path(os.environ.get("AXYNDRA_BINARY", ""))
SAMPLES = 20
SAMPLE_TIMEOUT_SECONDS = 30.0
STDERR_CAPTURE_LIMIT = 1_048_576
# Investigation ceilings: deliberately above the pinned baseline so ordinary
# scheduler noise does not fail releases, while regressions cannot pass as
# baseline evidence.
RUNTIME_P95_BUDGETS: dict[str, tuple[str, int]] = {
    "extension_cold_start": ("us", 250_000),
    "extension_first_call": ("us", 75_000),
    "extension_steady_ipc": ("us", 20_000),
    "extension_host_rss": ("bytes", 128 * 1024 * 1024),
    "extension_cancel_after_100ms_trigger": ("us", 250_000),
}
PRODUCT_P95_BUDGETS: dict[str, tuple[int, int]] = {
    "plugins_disabled": (750_000, 256 * 1024 * 1024),
    "declarative_plugin_inspect": (750_000, 256 * 1024 * 1024),
}


def percentile(values: list[int], percent: int) -> int:
    ordered = sorted(values)
    rank = max(1, math.ceil(percent * len(ordered) / 100))
    return ordered[min(len(ordered) - 1, rank - 1)]


def read_rss_bytes(pid: int) -> int:
    try:
        status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8")
    except FileNotFoundError:
        return 0
    for line in status.splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) * 1024
    return 0


def measure(arguments: list[str]) -> tuple[int, int]:
    started = time.monotonic_ns()
    process = subprocess.Popen(
        [str(CANDIDATE), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    if process.stderr is None:
        raise RuntimeError("performance probe did not expose stderr")
    os.set_blocking(process.stderr.fileno(), False)
    captured_stderr = bytearray()
    peak_rss = 0
    deadline = time.monotonic() + SAMPLE_TIMEOUT_SECONDS
    timed_out = False

    def drain_stderr() -> None:
        while True:
            try:
                chunk = os.read(process.stderr.fileno(), 65_536)
            except BlockingIOError:
                return
            if not chunk:
                return
            remaining = STDERR_CAPTURE_LIMIT - len(captured_stderr)
            if remaining > 0:
                captured_stderr.extend(chunk[:remaining])

    try:
        while process.poll() is None:
            drain_stderr()
            peak_rss = max(peak_rss, read_rss_bytes(process.pid))
            if time.monotonic() >= deadline:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
                break
            time.sleep(0.001)
        drain_stderr()
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        process.stderr.close()

    stderr = captured_stderr.decode("utf-8", errors="replace")
    if timed_out:
        raise TimeoutError(
            f"command timed out after {SAMPLE_TIMEOUT_SECONDS:g}s: {stderr}"
        )
    if process.returncode != 0:
        raise RuntimeError(f"command failed ({process.returncode}): {stderr}")
    return (time.monotonic_ns() - started) // 1000, peak_rss


def run_captured_process_group(
    command: list[str], cwd: Path, environment: dict[str, str], timeout_seconds: float
) -> tuple[int, str, str]:
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        raise TimeoutError(
            f"command timed out after {timeout_seconds:g}s: {stderr}"
        )
    return process.returncode, stdout, stderr


def product_profile(name: str, arguments: list[str], command: str) -> dict[str, object]:
    durations: list[int] = []
    rss: list[int] = []
    for _ in range(SAMPLES):
        elapsed, peak = measure(arguments)
        durations.append(elapsed)
        rss.append(peak)
    return {
        "profile": name,
        "samples": SAMPLES,
        "cold_start_us": {"p50": percentile(durations, 50), "p95": percentile(durations, 95)},
        "peak_rss_bytes": {"p50": percentile(rss, 50), "p95": percentile(rss, 95)},
        "command": command,
    }


def runtime_metrics() -> list[dict[str, object]]:
    environment = os.environ.copy()
    environment["AXYNDRA_FIXTURE_ROOT"] = str(FIXTURE_ROOT)
    returncode, stdout, stderr = run_captured_process_group(
        [str(REPOSITORY_ROOT / "scripts" / "pinned_cangjie"), "cjpm", "run"],
        PACKAGE_ROOT,
        environment,
        300,
    )
    if returncode != 0:
        raise RuntimeError(f"extension benchmark failed ({returncode}): {stderr}")
    metrics: list[dict[str, object]] = []
    for line in stdout.splitlines():
        if line.startswith("{"):
            metrics.append(json.loads(line))
    expected = {
        "extension_cold_start",
        "extension_first_call",
        "extension_steady_ipc",
        "extension_host_rss",
        "extension_cancel_after_100ms_trigger",
    }
    actual = {str(item.get("metric", "")) for item in metrics}
    if actual != expected:
        raise RuntimeError(f"extension benchmark metrics drifted: {sorted(actual)}")
    return metrics


def metric_value(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RuntimeError(f"performance metric {field} must be a non-negative integer")
    return value


def performance_budget_failures(records: list[dict[str, object]]) -> list[str]:
    failures: list[str] = []
    runtime_seen: set[str] = set()
    product_seen: set[str] = set()
    for record in records:
        if "metric" in record:
            name = str(record["metric"])
            runtime_seen.add(name)
            expected_unit, ceiling = RUNTIME_P95_BUDGETS[name]
            if record.get("unit") != expected_unit:
                raise RuntimeError(f"performance metric {name} has the wrong unit")
            actual = metric_value(record.get("p95"), f"{name}.p95")
            if actual > ceiling:
                failures.append(f"{name}.p95={actual} exceeds {ceiling} {expected_unit}")
            continue

        name = str(record.get("profile", ""))
        product_seen.add(name)
        latency_budget, rss_budget = PRODUCT_P95_BUDGETS[name]
        latency = record.get("cold_start_us")
        rss = record.get("peak_rss_bytes")
        if not isinstance(latency, dict) or not isinstance(rss, dict):
            raise RuntimeError(f"performance profile {name} omitted percentile evidence")
        latency_p95 = metric_value(latency.get("p95"), f"{name}.cold_start_us.p95")
        rss_p95 = metric_value(rss.get("p95"), f"{name}.peak_rss_bytes.p95")
        if latency_p95 > latency_budget:
            failures.append(
                f"{name}.cold_start_us.p95={latency_p95} exceeds {latency_budget} us"
            )
        if rss_p95 > rss_budget:
            failures.append(
                f"{name}.peak_rss_bytes.p95={rss_p95} exceeds {rss_budget} bytes"
            )

    if runtime_seen != set(RUNTIME_P95_BUDGETS):
        raise RuntimeError(f"runtime performance budget coverage drifted: {sorted(runtime_seen)}")
    if product_seen != set(PRODUCT_P95_BUDGETS):
        raise RuntimeError(f"product performance budget coverage drifted: {sorted(product_seen)}")
    return failures
def main() -> int:
    if not CANDIDATE.is_file():
        raise SystemExit("AXYNDRA_BINARY must name a packaged candidate executable")
    package = FIXTURE_ROOT / "pi-conventional"
    records: list[dict[str, object]] = [
        *runtime_metrics(),
        product_profile(
            "plugins_disabled",
            ["--fixture", "--print", "/help"],
            "axyndra --fixture --print /help",
        ),
        product_profile(
            "declarative_plugin_inspect",
            ["--fixture", "--print", f"/plugins inspect {package}"],
            "axyndra --fixture --print /plugins inspect <package>",
        ),
    ]
    failures = performance_budget_failures(records)
    for record in records:
        print(json.dumps(record, separators=(",", ":"), sort_keys=True))
    if failures:
        for failure in failures:
            print(f"plugin performance budget exceeded: {failure}", file=sys.stderr)
        return 1
    print(f"PLUGIN_PERFORMANCE_BASELINE_READY records={len(records)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
