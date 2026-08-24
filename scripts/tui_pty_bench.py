#!/usr/bin/env python3
"""Repeatable PTY latency benchmark for the real axyndra TUI.

The instrumented application writes frame-complete JSON records to stderr.
Terminal bytes remain on the PTY, so trace traffic does not inflate terminal
output measurements.  A short PTY-silence fallback is retained for older
binaries, but results explicitly say when it was used.
"""

from __future__ import annotations

import argparse
import csv
import fcntl
import json
import os
from pathlib import Path
import pty
import selectors
import shlex
import signal
import statistics
import struct
import subprocess
import termios
import time
from typing import Any, Iterable


TRACE_PREFIX = b"@@OMP_TUI_PERF@@"
DEFAULT_SCENARIOS = (
    "cold_start",
    "scroll",
    "key_repeat",
    "switch",
    "stream",
    "search",
    "resize",
)


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int((len(ordered) - 1) * fraction + 0.999999)))
    return ordered[index]


def distribution(values: Iterable[float]) -> dict[str, float]:
    samples = list(values)
    if not samples:
        return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
    return {
        "p50": statistics.median(samples),
        "p95": percentile(samples, 0.95),
        "p99": percentile(samples, 0.99),
        "max": max(samples),
    }


def set_winsize(fd: int, width: int, height: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))


class PtyRun:
    def __init__(
        self,
        command: list[str],
        root: Path,
        width: int,
        height: int,
        data_count: int,
        stream_chunks: int,
        timeout: float,
    ) -> None:
        self.command = command
        self.root = root
        self.width = width
        self.height = height
        self.data_count = data_count
        self.stream_chunks = stream_chunks
        self.timeout = timeout
        self.master_fd = -1
        self.process: subprocess.Popen[bytes] | None = None
        self.selector = selectors.DefaultSelector()
        self.stderr_buffer = b""
        self.operations: list[dict[str, Any]] = []
        self.stalls: list[dict[str, Any]] = []
        self.startup_stages: dict[str, float] = {}
        self.startup_stage_wall_ms: dict[str, float] = {}
        self.pty_bytes = 0
        self.max_rss_kb = 0
        self.cpu_ticks_start = 0
        self.cpu_ticks_end = 0
        self.spawn_ns = 0
        self.spawn_return_ns = 0
        self.first_frame_wall_ms = 0.0
        self.used_silence_fallback = False

    def start(self) -> None:
        master, slave = pty.openpty()
        set_winsize(slave, self.width, self.height)
        environment = os.environ.copy()
        environment.update(
            {
                "AXYNDRA_TUI_PERF_TRACE": "1",
                "AXYNDRA_TUI_PERF_FIXTURE": "1",
                "AXYNDRA_TUI_PERF_DATA_COUNT": str(self.data_count),
                "AXYNDRA_TUI_PERF_STREAM_CHUNKS": str(self.stream_chunks),
                "AXYNDRA_HOME": f"/tmp/axyndra-tui-pty-{os.getpid()}-{time.time_ns()}",
                "TERM": "xterm-256color",
                "NO_COLOR": "1",
            }
        )
        self.spawn_ns = time.monotonic_ns()
        self.process = subprocess.Popen(
            self.command,
            cwd=self.root,
            env=environment,
            stdin=slave,
            stdout=slave,
            stderr=subprocess.PIPE,
            start_new_session=True,
            close_fds=True,
        )
        self.spawn_return_ns = time.monotonic_ns()
        os.close(slave)
        self.master_fd = master
        os.set_blocking(master, False)
        assert self.process.stderr is not None
        os.set_blocking(self.process.stderr.fileno(), False)
        self.selector.register(master, selectors.EVENT_READ, "pty")
        self.selector.register(self.process.stderr.fileno(), selectors.EVENT_READ, "stderr")
        self.cpu_ticks_start = self._cpu_ticks()
        before = len(self.operations)
        try:
            self.wait_for_operations(before + 1, event_names=None, timeout=self.timeout)
            self.first_frame_wall_ms = (time.monotonic_ns() - self.spawn_ns) / 1_000_000.0
        except TimeoutError:
            self.wait_for_silence(0.05, timeout=self.timeout)
            self.used_silence_fallback = True
            self.first_frame_wall_ms = (time.monotonic_ns() - self.spawn_ns) / 1_000_000.0

    def _cpu_ticks(self) -> int:
        if self.process is None:
            return 0
        try:
            fields = Path(f"/proc/{self.process.pid}/stat").read_text().split()
            return int(fields[13]) + int(fields[14])
        except (FileNotFoundError, IndexError, ValueError):
            return 0

    def _sample_rss(self) -> None:
        if self.process is None:
            return
        try:
            for line in Path(f"/proc/{self.process.pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    self.max_rss_kb = max(self.max_rss_kb, int(line.split()[1]))
                    return
        except (FileNotFoundError, ValueError):
            return

    def pump(self, timeout: float = 0.05) -> None:
        self._sample_rss()
        for key, _ in self.selector.select(timeout):
            try:
                chunk = os.read(key.fd, 65536)
            except (BlockingIOError, OSError):
                continue
            if not chunk:
                continue
            if key.data == "pty":
                self.pty_bytes += len(chunk)
            else:
                self.stderr_buffer += chunk
                while b"\n" in self.stderr_buffer:
                    line, self.stderr_buffer = self.stderr_buffer.split(b"\n", 1)
                    if not line.startswith(TRACE_PREFIX):
                        continue
                    record = json.loads(line[len(TRACE_PREFIX) :])
                    if record.get("kind") == "operation":
                        self.operations.append(record)
                    elif record.get("kind") == "EVENT_LOOP_STALL":
                        self.stalls.append(record)
                    elif record.get("kind") == "startup_stage":
                        stage = str(record["stage"])
                        self.startup_stages[stage] = (
                            float(record.get("elapsed_ns", 0)) / 1_000_000.0
                        )
                        self.startup_stage_wall_ms[stage] = (
                            time.monotonic_ns() - self.spawn_ns
                        ) / 1_000_000.0

    def wait_for_operations(
        self,
        target_count: int,
        event_names: set[str] | None,
        timeout: float | None = None,
    ) -> list[dict[str, Any]]:
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        start = len(self.operations)
        while time.monotonic() < deadline:
            self.pump()
            selected = self.operations[start:]
            if event_names is not None:
                selected = [item for item in selected if item.get("event") in event_names]
            if len(selected) >= target_count - start:
                return selected[: target_count - start]
            if self.process is not None and self.process.poll() is not None:
                raise RuntimeError(f"TUI exited early with status {self.process.returncode}")
        raise TimeoutError(f"timed out waiting for {target_count - start} frame-complete records")

    def send(self, payload: bytes, expected: int = 1, event_names: set[str] | None = None) -> list[dict[str, Any]]:
        before = len(self.operations)
        os.write(self.master_fd, payload)
        return self.wait_for_operations(before + expected, event_names)

    def send_batched(
        self,
        payload: bytes,
        expected_events: int,
        event_names: set[str] | None = None,
    ) -> list[dict[str, Any]]:
        """Wait for ordered event consumption even when several events share a frame."""
        before_index = len(self.operations)
        before_sequence = (
            int(self.operations[-1].get("seq", 0)) if self.operations else 0
        )
        target_sequence = before_sequence + expected_events
        os.write(self.master_fd, payload)
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            self.pump()
            new_operations = self.operations[before_index:]
            if new_operations and int(new_operations[-1].get("seq", 0)) >= target_sequence:
                selected = new_operations
                if event_names is not None:
                    selected = [
                        item for item in selected if item.get("event") in event_names
                    ]
                if selected:
                    return selected
            if self.process is not None and self.process.poll() is not None:
                raise RuntimeError(
                    f"TUI exited early with status {self.process.returncode}"
                )
        observed = (
            int(self.operations[-1].get("seq", 0)) - before_sequence
            if self.operations
            else 0
        )
        raise TimeoutError(
            f"timed out waiting for {expected_events} ordered events; "
            f"observed sequence delta {observed}"
        )

    def resize(self, width: int, height: int) -> list[dict[str, Any]]:
        before = len(self.operations)
        set_winsize(self.master_fd, width, height)
        assert self.process is not None
        os.killpg(self.process.pid, signal.SIGWINCH)
        return self.wait_for_operations(before + 1, {"resize"}, timeout=max(self.timeout, 1.0))

    def wait_for_silence(self, quiet: float, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        last_bytes = self.pty_bytes
        quiet_since = time.monotonic()
        while time.monotonic() < deadline:
            self.pump(min(quiet, 0.05))
            if self.pty_bytes != last_bytes:
                last_bytes = self.pty_bytes
                quiet_since = time.monotonic()
            if time.monotonic() - quiet_since >= quiet:
                return
        raise TimeoutError("PTY output did not become quiet")

    def finish(self) -> None:
        if self.process is None:
            return
        self.cpu_ticks_end = self._cpu_ticks()
        self._sample_rss()
        try:
            if self.process.poll() is None:
                os.write(self.master_fd, b"\x03\x03")
                deadline = time.monotonic() + 1.0
                while self.process.poll() is None and time.monotonic() < deadline:
                    self.pump(0.02)
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    # A wedged fixture must not make the benchmark itself
                    # non-repeatable.  The process group is private to this
                    # PTY run, so force-reap it after the graceful deadline.
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=2)
        finally:
            final_ticks = self._cpu_ticks()
            if final_ticks > 0:
                self.cpu_ticks_end = final_ticks
            self._sample_rss()
            try:
                self.selector.close()
            finally:
                if self.master_fd >= 0:
                    os.close(self.master_fd)


def run_scenario(run: PtyRun, scenario: str) -> list[dict[str, Any]]:
    measured: list[dict[str, Any]] = []
    if scenario == "cold_start":
        return measured
    if scenario == "scroll":
        for key in (b"\x1b[<64;40;10M", b"\x1b[<65;40;10M"):
            for _ in range(30):
                measured.extend(run.send(key, event_names={"mouse"}))
        return measured
    if scenario == "key_repeat":
        measured.extend(
            run.send_batched(
                b"\x1b[B" * 120,
                expected_events=120,
                event_names={"key_down"},
            )
        )
        return measured
    if scenario == "switch":
        for payload in (b"j", b"\r", b"\x1b", b"\x1ba", b"\x1b", b"j", b"\r") * 12:
            measured.extend(run.send(payload, event_names={"key_down"}))
        return measured
    if scenario == "stream":
        run.send(b"\x1b[19~", event_names={"key_down"})
        before = len(run.operations)
        measured.extend(
            run.wait_for_operations(before + run.stream_chunks, {"timer"}, timeout=max(run.timeout, 60.0))
        )
        return measured
    if scenario == "search":
        run.send(b"\x1b[200~/session\x1b[201~", event_names={"paste"})
        os.write(run.master_fd, b"\r")
        time.sleep(0.2)
        run.pump()
        run.send(b"/", event_names={"key_down"})
        text = "连续搜索中文🧭wide界ANSI".encode()
        measured.extend(
            run.send_batched(
                text,
                expected_events=len("连续搜索中文🧭wide界ANSI"),
                event_names={"key_down"},
            )
        )
        return measured
    if scenario == "resize":
        for width, height in ((120, 36), (80, 24), (60, 18), (100, 28)) * 8:
            measured.extend(run.resize(width, height))
        return measured
    raise ValueError(f"unknown scenario: {scenario}")


def enrich(record: dict[str, Any]) -> dict[str, Any]:
    result = dict(record)
    stages = (
        ("dispatch_ms", "input_received_ns", "event_dispatch_completed_ns"),
        ("state_ms", "event_dispatch_completed_ns", "state_update_completed_ns"),
        ("layout_ms", "render_started_ns", "layout_completed_ns"),
        ("render_ms", "layout_completed_ns", "render_completed_ns"),
        ("write_flush_ms", "render_completed_ns", "terminal_flush_completed_ns"),
        ("total_ms", "input_received_ns", "terminal_flush_completed_ns"),
    )
    for name, start, end in stages:
        result[name] = max(0.0, (record.get(end, 0) - record.get(start, 0)) / 1_000_000.0)
    return result


def startup_phase_durations(run: PtyRun) -> dict[str, float]:
    stages = run.startup_stages

    def delta(start: str, end: str) -> float:
        if start not in stages or end not in stages:
            return 0.0
        return max(0.0, stages[end] - stages[start])

    process_spawn = max(0.0, (run.spawn_return_ns - run.spawn_ns) / 1_000_000.0)
    runtime_wall = max(
        0.0,
        run.startup_stage_wall_ms.get("runtime_initialization_completed", 0.0)
        - process_spawn,
    )
    return {
        "process_spawn": process_spawn,
        "runtime_initialization": runtime_wall,
        "configuration_loading": delta(
            "configuration_loading_started", "configuration_loading_completed"
        ),
        "card_registry_initialization": delta(
            "card_registry_initialization_started",
            "card_registry_initialization_completed",
        ),
        "fixture_generation": delta(
            "fixture_generation_started", "fixture_generation_completed"
        ),
        "first_state_construction": delta(
            "first_state_construction_started", "first_state_construction_completed"
        ),
        "first_layout": delta(
            "fixture_generation_completed", "first_layout_completed"
        ),
        "first_render": delta("first_layout_completed", "first_render_completed"),
        "first_terminal_flush": delta(
            "first_render_completed", "first_terminal_flush_completed"
        ),
    }


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    summary: dict[str, Any] = {"operations": len(rows)}
    for field in ("total_ms", "dispatch_ms", "state_ms", "layout_ms", "render_ms", "write_flush_ms"):
        summary[field] = distribution(float(row[field]) for row in rows)
    for field in ("output_bytes", "write_calls", "event_queue_length"):
        summary[field] = distribution(float(row.get(field, 0)) for row in rows)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", default="target/release/bin/agent_app --fixture")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scenarios", default=",".join(DEFAULT_SCENARIOS))
    parser.add_argument("--data-counts", default="100,1000,10000")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--width", type=int, default=100)
    parser.add_argument("--height", type=int, default=28)
    parser.add_argument("--stream-chunks", type=int, default=200)
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()
    if args.runs <= 0:
        raise SystemExit("--runs must be positive")
    root = Path(__file__).resolve().parents[1]
    command = shlex.split(args.candidate)
    scenarios = tuple(item for item in args.scenarios.split(",") if item)
    counts = tuple(int(item) for item in args.data_counts.split(",") if item)
    args.output.mkdir(parents=True, exist_ok=True)
    all_rows: list[dict[str, Any]] = []
    runs: list[dict[str, Any]] = []
    clock_ticks = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    for data_count in counts:
        for scenario in scenarios:
            for run_index in range(args.runs):
                session = PtyRun(
                    command,
                    root,
                    args.width,
                    args.height,
                    data_count,
                    args.stream_chunks,
                    args.timeout,
                )
                try:
                    session.start()
                    if scenario != "cold_start":
                        time.sleep(0.3)
                        session.pump(0.05)
                    selected = [enrich(item) for item in run_scenario(session, scenario)]
                finally:
                    session.finish()
                for row in selected:
                    row.update({"scenario": scenario, "data_count": data_count, "run": run_index + 1})
                    all_rows.append(row)
                runs.append(
                    {
                        "scenario": scenario,
                        "data_count": data_count,
                        "run": run_index + 1,
                        "first_frame_wall_ms": session.first_frame_wall_ms,
                        "pty_bytes": session.pty_bytes,
                        "max_rss_kb": session.max_rss_kb,
                        "cpu_seconds": max(0, session.cpu_ticks_end - session.cpu_ticks_start) / clock_ticks,
                        "stalls": session.stalls,
                        "silence_fallback": session.used_silence_fallback,
                        "pid": session.process.pid if session.process is not None else 0,
                        "startup_stages_ms": session.startup_stages,
                        "startup_phases_ms": startup_phase_durations(session),
                    }
                )
                print(
                    f"{scenario} n={data_count} run={run_index + 1} "
                    f"ops={len(selected)} first={session.first_frame_wall_ms:.1f}ms "
                    f"rss={session.max_rss_kb}KiB bytes={session.pty_bytes}",
                    flush=True,
                )
                if scenario == "cold_start":
                    print(
                        "  startup " + " ".join(
                            f"{name}={value:.2f}ms"
                            for name, value in session.startup_stages.items()
                        ),
                        flush=True,
                    )
    summaries: dict[str, Any] = {}
    for data_count in counts:
        for scenario in scenarios:
            key = f"{scenario}/{data_count}"
            rows = [row for row in all_rows if row["scenario"] == scenario and row["data_count"] == data_count]
            summaries[key] = summarize(rows)
            matching_runs = [row for row in runs if row["scenario"] == scenario and row["data_count"] == data_count]
            summaries[key]["first_frame_wall_ms"] = distribution(row["first_frame_wall_ms"] for row in matching_runs)
            summaries[key]["cpu_seconds"] = distribution(row["cpu_seconds"] for row in matching_runs)
            summaries[key]["max_rss_kb"] = distribution(row["max_rss_kb"] for row in matching_runs)
            summaries[key]["pty_bytes"] = distribution(row["pty_bytes"] for row in matching_runs)
            summaries[key]["stall_count"] = sum(len(row["stalls"]) for row in matching_runs)
            stage_names = sorted(
                {name for row in matching_runs for name in row.get("startup_stages_ms", {})}
            )
            summaries[key]["startup_stages_ms"] = {
                name: distribution(
                    row["startup_stages_ms"][name]
                    for row in matching_runs
                    if name in row.get("startup_stages_ms", {})
                )
                for name in stage_names
            }
            phase_names = sorted(
                {name for row in matching_runs for name in row.get("startup_phases_ms", {})}
            )
            summaries[key]["startup_phases_ms"] = {
                name: distribution(row["startup_phases_ms"][name] for row in matching_runs)
                for name in phase_names
            }
            stall_tasks: dict[str, int] = {}
            for run in matching_runs:
                for stall in run["stalls"]:
                    task = str(stall.get("task", "unknown"))
                    stall_tasks[task] = stall_tasks.get(task, 0) + 1
            summaries[key]["stall_count_by_task"] = stall_tasks
            summaries[key]["active_stall_count"] = sum(
                count for task, count in stall_tasks.items() if task != "event_wait"
            )
    (args.output / "summary.json").write_text(
        json.dumps({"summaries": summaries, "runs": runs}, ensure_ascii=False, indent=2) + "\n"
    )
    if all_rows:
        with (args.output / "operations.csv").open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(all_rows[0]))
            writer.writeheader()
            writer.writerows(all_rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
