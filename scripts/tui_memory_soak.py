#!/usr/bin/env python3
"""Long-running RSS and retained-state diagnostics for the real axyndra TUI.

This harness deliberately keeps managed-heap and GC fields separate from Linux
process RSS.  Cangjie does not currently expose a supported public API for
those values in this application, so they are recorded as ``unavailable``
instead of inferred from /proc.
"""

from __future__ import annotations

import argparse
import copy
import csv
from collections import deque
import fcntl
import json
import math
import os
from pathlib import Path
import pty
import selectors
import shlex
import signal
import statistics
import struct
import subprocess
import sys
import platform
import termios
import time
from typing import Any


TRACE_PREFIX = b"@@OMP_TUI_PERF@@"
SCENARIOS = (
    "idle",
    "fixed-card-stream",
    "fixed-card-replace",
    "navigation",
    "search",
    "resize",
    "expand-collapse",
    "session-churn",
)
RESIZE_WIDTHS = (40, 60, 80, 100, 120, 160)
UNAVAILABLE = "unavailable"
SAMPLE_FIELDS = (
    "timestamp",
    "elapsed_seconds",
    "phase",
    "operation_count",
    "injected_action_count",
    "terminal_byte_count",
    "rss_kib",
    "vmsize_kib",
    "anonymous_rss_kib",
    "file_rss_kib",
    "shared_rss_kib",
    "pss_kib",
    "thread_count",
    "fd_count",
    "heap_size",
    "used_heap",
    "committed_heap",
    "reserved_heap",
    "gc_count",
    "gc_pause_ms",
    "post_gc_used_heap",
    "card_count",
    "visible_card_count",
    "expanded_card_count",
    "large_fixture_expanded_count",
    "event_queue_length",
    "mailbox_event_count",
    "pending_job_count",
    "stream_buffer_bytes",
    "card_payload_bytes",
    "markdown_cache_entries",
    "virtual_cache_entries",
    "measured_cache_entries",
    "cached_row_count",
    "materialized_this_frame",
    "document_cache_entries",
    "document_buffer_cells",
    "frame_buffer_capacity_cells",
    "frame_buffer_design_bound_cells",
    "queued_prompt_count",
    "tool_binding_count",
)


def set_winsize(fd: int, width: int, height: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))
    return ordered[index]


def slope_per_minute(samples: list[dict[str, Any]], field: str, phase: str) -> float | None:
    points = [
        (float(row["elapsed_seconds"]), float(row[field]))
        for row in samples
        if row.get("phase") == phase and isinstance(row.get(field), (int, float))
    ]
    if len(points) < 3:
        return None
    mean_x = statistics.fmean(item[0] for item in points)
    mean_y = statistics.fmean(item[1] for item in points)
    denominator = sum((x - mean_x) ** 2 for x, _ in points)
    if denominator == 0:
        return None
    return 60.0 * sum((x - mean_x) * (y - mean_y) for x, y in points) / denominator


def parse_kib_map(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            if ":" not in line:
                continue
            name, raw = line.split(":", 1)
            fields = raw.split()
            if fields and fields[0].isdigit():
                values[name] = int(fields[0])
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        pass
    return values


def proc_sample(pid: int) -> dict[str, int | str]:
    status = parse_kib_map(Path(f"/proc/{pid}/status"))
    rollup = parse_kib_map(Path(f"/proc/{pid}/smaps_rollup"))
    try:
        fd_count: int | str = len(list(Path(f"/proc/{pid}/fd").iterdir()))
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        fd_count = UNAVAILABLE
    return {
        "rss_kib": status.get("VmRSS", UNAVAILABLE),
        "vmsize_kib": status.get("VmSize", UNAVAILABLE),
        "anonymous_rss_kib": status.get("RssAnon", rollup.get("Anonymous", UNAVAILABLE)),
        "file_rss_kib": status.get("RssFile", UNAVAILABLE),
        "shared_rss_kib": status.get("RssShmem", UNAVAILABLE),
        "pss_kib": rollup.get("Pss", UNAVAILABLE),
        "thread_count": status.get("Threads", UNAVAILABLE),
        "fd_count": fd_count,
    }


def descendant_target_pid(root_pid: int, target_name: str = "agent_app") -> int:
    """Return the deepest live target descendant, or the wrapper PID.

    Profilers such as heaptrack stay resident and fork the actual application.
    Sampling the wrapper would make RSS, thread and FD metrics meaningless.
    """
    parents: dict[int, int] = {}
    commands: dict[int, bytes] = {}
    try:
        proc_entries = list(Path("/proc").iterdir())
    except (FileNotFoundError, PermissionError):
        return root_pid
    for entry in proc_entries:
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            stat = (entry / "stat").read_text()
            # The command name is parenthesized and can contain spaces; PPID
            # is the first numeric field after the final ')'.
            fields = stat[stat.rfind(")") + 2 :].split()
            parents[pid] = int(fields[1])
            commands[pid] = (entry / "cmdline").read_bytes()
        except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError, IndexError):
            continue
    descendants: set[int] = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, parent in parents.items():
            if parent in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    targets = []
    marker = target_name.encode()
    for pid in descendants:
        if pid == root_pid:
            continue
        argv = [part for part in commands.get(pid, b"").split(b"\0") if part]
        if any(part == marker or part.endswith(b"/" + marker) for part in argv):
            targets.append(pid)
    return max(targets) if targets else root_pid


class SoakProcess:
    def __init__(self, args: argparse.Namespace, run_dir: Path) -> None:
        self.args = args
        self.run_dir = run_dir
        self.root = Path(__file__).resolve().parents[1]
        self.master_fd = -1
        self.process: subprocess.Popen[bytes] | None = None
        self.selector = selectors.DefaultSelector()
        self.stderr_buffer = b""
        self.latest_state: dict[str, Any] = {}
        self.latest_operation: dict[str, Any] = {}
        self.events: list[dict[str, Any]] = []
        self.operation_count = 0
        self.injected_action_count = 0
        self.terminal_bytes = 0
        self.stdout_saved = 0
        self.stderr_saved = 0
        self.stdout_truncated = False
        self.stderr_truncated = False
        self.terminal_tail: deque[bytes] = deque()
        self.terminal_tail_bytes = 0
        self.started = 0.0
        self.sampled_pid = 0
        self.stdout_handle = None
        self.stderr_handle = None
        self.events_handle = None
        self.terminal_width = args.terminal_width

    @property
    def pid(self) -> int:
        return self.process.pid if self.process is not None else 0

    def start(self) -> None:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.stdout_handle = (self.run_dir / "stdout.log").open("wb")
        self.stderr_handle = (self.run_dir / "stderr.log").open("wb")
        self.events_handle = (self.run_dir / "events.jsonl").open("w")
        master, slave = pty.openpty()
        set_winsize(slave, self.args.terminal_width, self.args.terminal_height)
        environment = os.environ.copy()
        environment.update(
            {
                "AXYNDRA_TUI_PERF_TRACE": "1",
                "AXYNDRA_TUI_MEMORY_TRACE": "1" if self.args.app_state_trace else "0",
                "AXYNDRA_TUI_MEMORY_INPUT": "1",
                "AXYNDRA_TUI_PERF_FIXTURE": "1",
                "AXYNDRA_TUI_PERF_DATA_COUNT": str(self.args.data_count),
                "AXYNDRA_TUI_PERF_STREAM_CHUNKS": "1",
                "AXYNDRA_TUI_MEMORY_LARGE_FIXTURE": "1" if self.args.large_fixture and self.args.scenario == "expand-collapse" else "0",
                "AXYNDRA_HOME": f"/tmp/axyndra-memory-{os.getpid()}-{time.time_ns()}",
                "TERM": "xterm-256color",
                "NO_COLOR": "1",
            }
        )
        self.started = time.monotonic()
        self.process = subprocess.Popen(
            shlex.split(self.args.candidate),
            cwd=self.root,
            env=environment,
            stdin=slave,
            stdout=slave,
            stderr=subprocess.PIPE,
            start_new_session=True,
            close_fds=True,
        )
        self.sampled_pid = self.process.pid
        os.close(slave)
        self.master_fd = master
        os.set_blocking(master, False)
        assert self.process.stderr is not None
        os.set_blocking(self.process.stderr.fileno(), False)
        self.selector.register(master, selectors.EVENT_READ, "pty")
        self.selector.register(self.process.stderr.fileno(), selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + self.args.startup_timeout
        while self.operation_count == 0 and time.monotonic() < deadline:
            self.pump(0.05)
            self.assert_running()
        if self.operation_count == 0:
            raise TimeoutError("first terminal frame was not completed")

    def assert_running(self) -> None:
        if self.process is not None and self.process.poll() is not None:
            raise RuntimeError(f"TUI exited early with status {self.process.returncode}")

    def _save_bounded(self, handle: Any, chunk: bytes, kind: str) -> None:
        saved_name = f"{kind}_saved"
        truncated_name = f"{kind}_truncated"
        saved = int(getattr(self, saved_name))
        allowed = max(0, self.args.max_log_bytes - saved)
        if allowed:
            handle.write(chunk[:allowed])
            setattr(self, saved_name, saved + min(len(chunk), allowed))
        if len(chunk) > allowed:
            setattr(self, truncated_name, True)

    def _remember_terminal_tail(self, chunk: bytes) -> None:
        self.terminal_tail.append(chunk)
        self.terminal_tail_bytes += len(chunk)
        while self.terminal_tail_bytes > self.args.terminal_tail_bytes and self.terminal_tail:
            removed = self.terminal_tail.popleft()
            self.terminal_tail_bytes -= len(removed)

    def _handle_stderr(self, chunk: bytes) -> None:
        assert self.stderr_handle is not None
        self._save_bounded(self.stderr_handle, chunk, "stderr")
        self.stderr_buffer += chunk
        while b"\n" in self.stderr_buffer:
            line, self.stderr_buffer = self.stderr_buffer.split(b"\n", 1)
            if not line.startswith(TRACE_PREFIX):
                continue
            try:
                record = json.loads(line[len(TRACE_PREFIX) :])
            except json.JSONDecodeError:
                continue
            record["observed_elapsed_seconds"] = time.monotonic() - self.started
            if record.get("kind") == "operation":
                self.operation_count += 1
                self.latest_operation = record
            elif record.get("kind") == "memory_state":
                self.latest_state = record
            assert self.events_handle is not None
            self.events_handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            self.events_handle.flush()

    def pump(self, timeout: float = 0.02) -> None:
        for key, _ in self.selector.select(timeout):
            try:
                chunk = os.read(key.fd, 65536)
            except (BlockingIOError, OSError):
                continue
            if not chunk:
                continue
            if key.data == "pty":
                self.terminal_bytes += len(chunk)
                assert self.stdout_handle is not None
                self._save_bounded(self.stdout_handle, chunk, "stdout")
                self._remember_terminal_tail(chunk)
            else:
                self._handle_stderr(chunk)

    def send(self, data: bytes, timeout: float | None = None) -> None:
        if self.master_fd < 0 or not data:
            return
        deadline = time.monotonic() + (
            self.args.input_write_timeout if timeout is None else timeout
        )
        offset = 0
        while offset < len(data):
            try:
                written = os.write(self.master_fd, data[offset:])
            except BlockingIOError:
                # High-rate search and paste fixtures can briefly fill the
                # PTY input queue. Drain output and retry for a bounded period
                # instead of turning ordinary backpressure into a false crash.
                self.pump(0.01)
                if time.monotonic() >= deadline:
                    raise TimeoutError("PTY input remained blocked")
                self.assert_running()
                continue
            if written <= 0:
                raise RuntimeError("PTY input write made no progress")
            offset += written

    def resize(self, width: int) -> None:
        set_winsize(self.master_fd, width, self.args.terminal_height)
        self.terminal_width = width
        if self.process is not None:
            os.killpg(self.process.pid, signal.SIGWINCH)

    def sample(self, phase: str) -> dict[str, Any]:
        self.sampled_pid = descendant_target_pid(self.pid)
        row: dict[str, Any] = {
            "timestamp": time.time(),
            "elapsed_seconds": time.monotonic() - self.started,
            "phase": phase,
            "operation_count": self.operation_count,
            "injected_action_count": self.injected_action_count,
            "terminal_byte_count": self.terminal_bytes,
            "heap_size": UNAVAILABLE,
            "used_heap": UNAVAILABLE,
            "committed_heap": UNAVAILABLE,
            "reserved_heap": UNAVAILABLE,
            "gc_count": UNAVAILABLE,
            "gc_pause_ms": UNAVAILABLE,
            "post_gc_used_heap": UNAVAILABLE,
        }
        row.update(proc_sample(self.sampled_pid))
        # cj_tui's runtime capacity is not exposed through a supported trace
        # API. Keep the observed field explicitly unavailable and record the
        # independently audited two-buffer geometry bound under a different
        # name; a derived upper bound must not masquerade as measurement.
        row["frame_buffer_capacity_cells"] = UNAVAILABLE
        row["frame_buffer_design_bound_cells"] = (
            2 * self.terminal_width * self.args.terminal_height
        )
        row["event_queue_length"] = self.latest_operation.get("event_queue_length", UNAVAILABLE)
        for field in SAMPLE_FIELDS:
            if field not in row:
                row[field] = self.latest_state.get(field, UNAVAILABLE)
        return row

    def stop(self) -> dict[str, Any]:
        returncode: int | None = None
        stop_signal: str | None = None
        try:
            if self.process is not None and self.process.poll() is None:
                # F11 is a test-only clean-exit event enabled by the same
                # AXYNDRA_TUI_MEMORY_INPUT gate as F9/F10 fixture updates. It is
                # independent of composer/modal state and still exercises the
                # application's normal UpdateResult.exit terminal cleanup.
                deadline = time.monotonic() + 5.0
                while self.process.poll() is None and time.monotonic() < deadline:
                    try:
                        self.send(b"\x1b[23~", timeout=0.5)
                    except (OSError, RuntimeError, TimeoutError):
                        pass
                    self.pump(0.5)
            if self.process is not None and self.process.poll() is None:
                stop_signal = "SIGTERM"
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    stop_signal = "SIGKILL"
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=3)
            if self.process is not None:
                returncode = self.process.returncode
        finally:
            for handle in (self.stdout_handle, self.stderr_handle, self.events_handle):
                if handle is not None:
                    handle.close()
            self.selector.close()
            if self.master_fd >= 0:
                os.close(self.master_fd)
            terminal = b"".join(self.terminal_tail)
            self.run_dir.mkdir(parents=True, exist_ok=True)
            (self.run_dir / "terminal-last.bin").write_bytes(terminal[-self.args.terminal_tail_bytes :])
        status = {
            "pid": self.pid,
            "sampled_pid": self.sampled_pid,
            "returncode": returncode,
            "stop_signal": stop_signal,
            "planned_stop": returncode == 0 or stop_signal is not None,
            "stdout_truncated": self.stdout_truncated,
            "stderr_truncated": self.stderr_truncated,
            "terminal_byte_count": self.terminal_bytes,
            "operation_count": self.operation_count,
        }
        (self.run_dir / "process-status.json").write_text(json.dumps(status, indent=2) + "\n")
        return status


class ScenarioDriver:
    def __init__(self, process: SoakProcess, scenario: str, interval: float) -> None:
        self.process = process
        self.scenario = scenario
        self.interval = interval
        self.next_action = time.monotonic()
        self.action_index = 0
        self.search_opened = False

    def prepare(self) -> None:
        if self.scenario == "search":
            self.process.send(b"/session\r")
            time.sleep(0.25)
            self.process.pump(0.05)
            self.process.send(b"/")
            self.search_opened = True
        elif self.scenario == "expand-collapse":
            # Preserve one full sampling interval in the initial collapsed
            # state before the first intentionally expensive expansion.
            self.next_action = time.monotonic() + self.interval

    def tick(self, active: bool) -> None:
        now = time.monotonic()
        if not active or self.scenario == "idle" or now < self.next_action:
            return
        if self.scenario == "session-churn" and self.process.latest_state.get("pending_job_count", 0) != 0:
            # A session selection owns a background focus/load job.  Starting
            # another modal cycle before it settles measures harness-created
            # overlap and can strand the final job at the idle boundary.
            self.next_action = now + self.interval
            return
        # Never burst to catch up missed wall-clock intervals. PTY input can
        # otherwise accumulate faster than the application renders, causing
        # the nominal idle-after phase to keep processing old keys.
        self._inject_one()
        self.next_action = now + self.interval

    def finish(self) -> None:
        # Leave modal/search fixtures in the normal transcript view so the
        # application's clean Ctrl-D exit binding is reachable.
        if self.scenario in ("search", "session-churn"):
            # Search Esc is stateful: with non-empty input it clears the query,
            # the next press returns to browse, and another closes the modal.
            # A fourth idempotent Esc covers a confirmation sub-mode. Separate
            # the bytes so the parser cannot reinterpret them as an Alt chord.
            for _ in range(4):
                self.process.send(b"\x1b")
                self.process.pump(0.5)
        elif self.scenario == "expand-collapse":
            if self.action_index % 2 == 1:
                self.process.send(b"\x1b[24~")
                self.process.pump(0.2)

    def _inject_one(self) -> None:
        if self.scenario == "fixed-card-stream":
            self.process.send(b"\x1b[20~")
        elif self.scenario == "fixed-card-replace":
            self.process.send(b"\x1b[21~")
        elif self.scenario == "navigation":
            actions = (b"\x1b[A", b"\x1b[B", b"\x1b[5~", b"\x1b[6~", b"j", b"k")
            self.process.send(actions[self.action_index % len(actions)])
        elif self.scenario == "resize":
            self.process.resize(RESIZE_WIDTHS[self.action_index % len(RESIZE_WIDTHS)])
        elif self.scenario == "expand-collapse":
            # F12 is a test-only fixture input that toggles the exact same
            # large card through the normal UiCard layout/render path.  This
            # avoids conflating virtual-list focus selection with retention.
            self.process.send(b"\x1b[24~")
        elif self.scenario == "search":
            queries = (
                "approval",
                "连续搜索",
                "Emoji🧭",
                "e\u0301组合",
                "ASCII-long-query",
            )
            cycle_step = self.action_index % 5
            query = queries[(self.action_index // 5) % len(queries)]
            if cycle_step == 0:
                self.process.send(query.encode())
            elif cycle_step == 1:
                self.process.send(b"\x7fx")
            elif cycle_step == 2:
                # One terminal Backspace removes one user-visible grapheme;
                # an extra Backspace for a combining mark is harmless at the
                # empty boundary and keeps this fixture independent of Python's
                # Unicode segmentation rules.
                self.process.send(b"\x7f" * (len(query) + 1))
            elif cycle_step == 3:
                self.process.send(b"\x1b")
                self.search_opened = False
            else:
                self.process.send(b"/")
                self.search_opened = True
        elif self.scenario == "session-churn":
            actions = (
                # Keep this identical to the command path exercised by the
                # search scenario.  Bracketed paste is terminal-dependent and
                # can be interpreted as literal input, making a long soak look
                # active even though the session modal was opened only once.
                b"/session\r",
                b"j",
                b"\r",
                b"\x1b",
            )
            self.process.send(actions[self.action_index % len(actions)])
        self.action_index += 1
        self.process.injected_action_count += 1


def summarize_run(samples: list[dict[str, Any]], status: dict[str, Any], scenario: str) -> dict[str, Any]:
    numeric_rss = [float(row["rss_kib"]) for row in samples if isinstance(row.get("rss_kib"), int)]
    steady = [
        float(row["rss_kib"])
        for row in samples
        if row.get("phase") == "active" and isinstance(row.get("rss_kib"), int)
    ]
    idle = [
        float(row["rss_kib"])
        for row in samples
        if row.get("phase") == "idle_after" and isinstance(row.get("rss_kib"), int)
    ]
    active_quartile_medians: list[float] = []
    if steady:
        for quartile in range(4):
            start = len(steady) * quartile // 4
            end = len(steady) * (quartile + 1) // 4
            bucket = steady[start:end]
            if bucket:
                active_quartile_medians.append(statistics.median(bucket))
    cards = [row["card_count"] for row in samples if isinstance(row.get("card_count"), int)]
    visible_cards = [row["visible_card_count"] for row in samples if isinstance(row.get("visible_card_count"), int)]
    active_cards = [
        row["card_count"]
        for row in samples
        if row.get("phase") == "active" and isinstance(row.get("card_count"), int)
    ]
    fds = [row["fd_count"] for row in samples if isinstance(row.get("fd_count"), int)]
    threads = [row["thread_count"] for row in samples if isinstance(row.get("thread_count"), int)]
    queues = [row["event_queue_length"] for row in samples if isinstance(row.get("event_queue_length"), int)]
    jobs = [row["pending_job_count"] for row in samples if isinstance(row.get("pending_job_count"), int)]
    idle_operations = [
        row["operation_count"]
        for row in samples
        if row.get("phase") == "idle_after" and isinstance(row.get("operation_count"), int)
    ]
    expanded = [row["expanded_card_count"] for row in samples if isinstance(row.get("expanded_card_count"), int)]
    expanded_large = [
        row["large_fixture_expanded_count"]
        for row in samples
        if isinstance(row.get("large_fixture_expanded_count"), int)
    ]
    payload_bytes = [row["card_payload_bytes"] for row in samples if isinstance(row.get("card_payload_bytes"), int)]
    stream_bytes = [row["stream_buffer_bytes"] for row in samples if isinstance(row.get("stream_buffer_bytes"), int)]
    frame_design_cells = [
        row["frame_buffer_design_bound_cells"]
        for row in samples
        if isinstance(row.get("frame_buffer_design_bound_cells"), int)
    ]
    markdown_entries = [row["markdown_cache_entries"] for row in samples if isinstance(row.get("markdown_cache_entries"), int)]
    virtual_entries = [row["virtual_cache_entries"] for row in samples if isinstance(row.get("virtual_cache_entries"), int)]
    measured_entries = [row["measured_cache_entries"] for row in samples if isinstance(row.get("measured_cache_entries"), int)]
    document_entries = [row["document_cache_entries"] for row in samples if isinstance(row.get("document_cache_entries"), int)]
    summary = {
        "scenario": scenario,
        "sample_count": len(samples),
        "first_frame_rss_kib": next(
            (row["rss_kib"] for row in samples if row.get("phase") == "first_frame"),
            None,
        ),
        "peak_rss_kib": max(numeric_rss) if numeric_rss else None,
        "steady_state_rss_median_kib": statistics.median(steady) if steady else None,
        "steady_state_rss_p95_kib": percentile(steady, 0.95),
        "post_idle_rss_kib": idle[-1] if idle else None,
        "post_gc_rss_kib": UNAVAILABLE,
        "post_gc_used_heap": UNAVAILABLE,
        "active_rss_slope_kib_per_minute": slope_per_minute(samples, "rss_kib", "active"),
        "active_anonymous_slope_kib_per_minute": slope_per_minute(samples, "anonymous_rss_kib", "active"),
        "active_rss_quartile_medians_kib": active_quartile_medians,
        "active_rss_quartile_delta_kib": (
            active_quartile_medians[-1] - active_quartile_medians[0]
            if len(active_quartile_medians) == 4
            else UNAVAILABLE
        ),
        "active_rss_positive_quartile_transitions": (
            sum(
                active_quartile_medians[index + 1] > active_quartile_medians[index]
                for index in range(3)
            )
            if len(active_quartile_medians) == 4
            else UNAVAILABLE
        ),
        "card_count_min": min(cards) if cards else None,
        "card_count_max": max(cards) if cards else None,
        "visible_card_count_max": max(visible_cards) if visible_cards else None,
        "expanded_card_count_min": min(expanded) if expanded else None,
        "expanded_card_count_max": max(expanded) if expanded else None,
        "large_fixture_expanded_count_min": min(expanded_large) if expanded_large else None,
        "large_fixture_expanded_count_max": max(expanded_large) if expanded_large else None,
        "card_payload_bytes_final": payload_bytes[-1] if payload_bytes else UNAVAILABLE,
        "average_payload_bytes_per_card": (
            payload_bytes[-1] / cards[-1] if payload_bytes and cards and cards[-1] > 0 else UNAVAILABLE
        ),
        "stream_buffer_bytes_final": stream_bytes[-1] if stream_bytes else UNAVAILABLE,
        "frame_buffer_capacity_cells_max": UNAVAILABLE,
        "frame_buffer_design_bound_cells_max": max(frame_design_cells) if frame_design_cells else UNAVAILABLE,
        "active_card_count_min": min(active_cards) if active_cards else None,
        "active_card_count_max": max(active_cards) if active_cards else None,
        "fd_count_min": min(fds) if fds else None,
        "fd_count_max": max(fds) if fds else None,
        "thread_count_min": min(threads) if threads else None,
        "thread_count_max": max(threads) if threads else None,
        "final_event_queue_length": queues[-1] if queues else UNAVAILABLE,
        "event_queue_length_max": max(queues) if queues else UNAVAILABLE,
        "final_pending_job_count": jobs[-1] if jobs else UNAVAILABLE,
        "idle_tail_operation_growth": (
            idle_operations[-1] - idle_operations[len(idle_operations) // 2]
            if len(idle_operations) >= 4
            else UNAVAILABLE
        ),
        "markdown_cache_entries_max": max(markdown_entries) if markdown_entries else None,
        "virtual_cache_entries_max": max(virtual_entries) if virtual_entries else None,
        "measured_cache_entries_max": max(measured_entries) if measured_entries else None,
        "document_cache_entries_max": max(document_entries) if document_entries else None,
        "operations": status["operation_count"],
        "terminal_bytes": status["terminal_byte_count"],
        "managed_heap_metrics": UNAVAILABLE,
        "forced_gc": UNAVAILABLE,
    }
    injected = max(
        (int(row["injected_action_count"]) for row in samples if isinstance(row.get("injected_action_count"), int)),
        default=0,
    )
    payload_values = [
        int(row["stream_buffer_bytes"])
        for row in samples
        if isinstance(row.get("stream_buffer_bytes"), int)
    ]
    summary["injected_action_count"] = injected
    summary["stream_payload_growth_bytes"] = (
        payload_values[-1] - payload_values[0] if len(payload_values) >= 2 else UNAVAILABLE
    )
    summary["bytes_per_injected_action"] = (
        (payload_values[-1] - payload_values[0]) / injected
        if len(payload_values) >= 2 and injected > 0
        else UNAVAILABLE
    )
    hard_failures: list[str] = []
    if not status.get("planned_stop", False):
        hard_failures.append("process_exited_before_planned_stop")
    elif status.get("returncode") == 0 and status.get("stop_signal") is None:
        pass
    elif status.get("stop_signal") != "SIGTERM":
        hard_failures.append("process_required_forced_kill")
    summary["process_completion"] = (
        "clean_exit"
        if status.get("returncode") == 0 and status.get("stop_signal") is None
        else "planned_signal_teardown"
        if status.get("stop_signal") == "SIGTERM"
        else "abnormal_exit"
    )
    summary["termination_anomaly"] = (
        "runtime returned SIGSEGV status while handling planned SIGTERM"
        if status.get("stop_signal") == "SIGTERM" and status.get("returncode") == -signal.SIGSEGV
        else "none"
    )
    if scenario in ("fixed-card-stream", "fixed-card-replace") and active_cards:
        # The first stream delta creates one assistant card; all subsequent
        # chunks must update that same card.  A sampled transition from N to
        # N+1 is expected, while any second increase is a correctness failure.
        initial_cards = min(cards) if cards else min(active_cards)
        if max(active_cards) > initial_cards + 1 or active_cards[-1] != max(active_cards):
            hard_failures.append("card_count_changed_after_stream_card_created")
    # Short-lived file opens during session loading are expected. Treat only
    # retained descriptors at the final sample as a leak signal; peak/min is
    # already preserved in the diagnostic summary for profiling.
    if fds and fds[-1] - fds[0] > 4:
        hard_failures.append("fd_count_grew")
    if threads and max(threads) - min(threads) > 2:
        hard_failures.append("thread_count_grew")
    if queues and queues[-1] != 0:
        hard_failures.append("event_queue_not_drained")
    if jobs and jobs[-1] != 0:
        hard_failures.append("pending_jobs_not_drained")
    if len(idle_operations) >= 4 and idle_operations[-1] - idle_operations[len(idle_operations) // 2] > 2:
        hard_failures.append("input_or_render_work_continued_through_idle_tail")
    if scenario == "expand-collapse" and expanded_large:
        if max(expanded_large) == 0:
            hard_failures.append("large_card_was_never_expanded")
        if min(expanded_large) != 0:
            hard_failures.append("large_card_was_never_observed_collapsed")
    for row in samples:
        card_count = row.get("card_count")
        markdown = row.get("markdown_cache_entries")
        virtual = row.get("virtual_cache_entries")
        measured = row.get("measured_cache_entries")
        documents = row.get("document_cache_entries")
        if isinstance(card_count, int) and isinstance(markdown, int) and markdown > card_count:
            hard_failures.append("markdown_cache_exceeds_card_count")
            break
        if isinstance(card_count, int) and isinstance(virtual, int) and virtual > card_count:
            hard_failures.append("virtual_cache_exceeds_card_count")
            break
        if isinstance(virtual, int) and isinstance(measured, int) and measured > virtual:
            hard_failures.append("measured_cache_exceeds_virtual_cache")
            break
        if isinstance(documents, int) and documents > 1:
            hard_failures.append("document_cache_exceeds_single_entry_bound")
            break
    summary["hard_correctness_failures"] = hard_failures
    # RSS is diagnostic-only until at least five formal runs establish its distribution.
    summary["trend_warning"] = (
        "positive RSS slope; inspect repeated runs and retained stacks"
        if isinstance(summary["active_rss_slope_kib_per_minute"], float)
        and summary["active_rss_slope_kib_per_minute"] > 0
        else "none"
    )
    return summary


def run_once(args: argparse.Namespace, scenario: str, run_index: int) -> dict[str, Any]:
    run_dir = args.output / scenario / f"run-{run_index:02d}"
    process = SoakProcess(args, run_dir)
    samples: list[dict[str, Any]] = []
    status: dict[str, Any] = {}
    failure: str | None = None
    try:
        process.start()
        # Preserve a first-frame sample, then let the fixture's asynchronous
        # draft load settle before measured phases begin.  A same-size resize
        # is a diagnostic refresh performed before the idle scenario starts;
        # the idle phases themselves inject no input.
        samples.append(process.sample("first_frame"))
        if args.app_state_trace:
            previous_state_time = process.latest_state.get("observed_elapsed_seconds", -1.0)
            settle_deadline = time.monotonic() + args.startup_timeout
            refresh_sent = False
            while time.monotonic() < settle_deadline:
                process.pump(0.05)
                if not refresh_sent and time.monotonic() - process.started >= 1.50:
                    # Ctrl-L requests a terminal redraw but does not mutate cards,
                    # session data, search state, or any business operation.
                    process.send(b"\x0c")
                    refresh_sent = True
                if (
                    refresh_sent
                    and process.latest_state.get("observed_elapsed_seconds", -1.0) > previous_state_time
                    and process.latest_state.get("pending_job_count") == 0
                ):
                    break
        else:
            settle_deadline = time.monotonic() + min(1.0, args.startup_timeout)
            while time.monotonic() < settle_deadline:
                process.pump(0.05)
        driver = ScenarioDriver(process, scenario, args.stream_interval)
        driver.prepare()
        phases = (("warmup", args.warmup), ("active", args.duration), ("idle_after", args.idle_after))
        last_sample = 0.0
        last_progress = 0.0
        driver_finished = False
        for phase, phase_duration in phases:
            if phase == "idle_after":
                # Idle-after measures recovery after interaction state has
                # been released, not merely a pause with an expanded card or
                # modal still retained.
                driver.finish()
                driver_finished = True
            deadline = time.monotonic() + phase_duration
            while time.monotonic() < deadline:
                process.assert_running()
                driver.tick(phase != "idle_after")
                process.pump(min(0.05, args.sample_interval))
                now = time.monotonic()
                if now - last_sample >= args.sample_interval:
                    samples.append(process.sample(phase))
                    last_sample = now
                if now - last_progress >= args.progress_interval:
                    latest = samples[-1] if samples else process.sample(phase)
                    print(
                        f"scenario={scenario} run={run_index} phase={phase} "
                        f"elapsed={latest['elapsed_seconds']:.1f}s pid={process.pid} "
                        f"rss={latest['rss_kib']}KiB cards={latest['card_count']} "
                        f"ops={latest['operation_count']} bytes={latest['terminal_byte_count']}",
                        flush=True,
                    )
                    last_progress = now
        # Drain already-produced events without injecting another business event.
        drain_deadline = time.monotonic() + args.drain_timeout
        while time.monotonic() < drain_deadline:
            process.pump(0.05)
            if process.latest_state.get("event_queue_length", 0) == 0:
                break
        samples.append(process.sample("final"))
        if not driver_finished:
            driver.finish()
    except Exception as exc:  # preserve all diagnostics before surfacing the failure
        failure = f"{type(exc).__name__}: {exc}"
    finally:
        status = process.stop()
    run_dir.mkdir(parents=True, exist_ok=True)
    with (run_dir / "samples.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=SAMPLE_FIELDS)
        writer.writeheader()
        writer.writerows({field: row.get(field, UNAVAILABLE) for field in SAMPLE_FIELDS} for row in samples)
    summary = summarize_run(samples, status, scenario)
    summary["failure"] = failure
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    if failure:
        raise RuntimeError(f"{scenario} run {run_index}: {failure}")
    return summary


def aggregate_runs(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    metric_names = (
        "peak_rss_kib",
        "steady_state_rss_median_kib",
        "steady_state_rss_p95_kib",
        "post_idle_rss_kib",
        "active_rss_slope_kib_per_minute",
        "active_anonymous_slope_kib_per_minute",
        "active_rss_quartile_delta_kib",
        "injected_action_count",
        "bytes_per_injected_action",
    )
    metrics: dict[str, Any] = {}
    for name in metric_names:
        values = [float(item[name]) for item in summaries if isinstance(item.get(name), (int, float))]
        metrics[name] = {
            "samples": len(values),
            "median": statistics.median(values) if values else None,
            "p95": percentile(values, 0.95),
            "max": max(values) if values else None,
        }
    failures = sorted(
        {
            failure
            for item in summaries
            for failure in item.get("hard_correctness_failures", [])
        }
    )
    return {
        "run_count": len(summaries),
        "clean_exit_count": sum(item.get("process_completion") == "clean_exit" for item in summaries),
        "hard_correctness_failures": failures,
        "metrics": metrics,
    }


def compare_aggregates(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    """Compare repeated-run distributions without inventing an RSS hard cap.

    The baseline five-run P95 is the calibrated warning boundary for slope and
    quartile delta. Exceeding it is an alert for investigation, not a hard
    correctness failure; queue/card/cache/thread/FD invariants remain hard.
    """
    metric_names = (
        "peak_rss_kib",
        "steady_state_rss_median_kib",
        "steady_state_rss_p95_kib",
        "post_idle_rss_kib",
        "active_rss_slope_kib_per_minute",
        "active_rss_quartile_delta_kib",
        "injected_action_count",
    )
    deltas: dict[str, Any] = {}
    for name in metric_names:
        baseline_value = baseline["metrics"].get(name, {}).get("median")
        candidate_value = candidate["metrics"].get(name, {}).get("median")
        delta = (
            candidate_value - baseline_value
            if isinstance(baseline_value, (int, float)) and isinstance(candidate_value, (int, float))
            else None
        )
        deltas[name] = {
            "baseline_median": baseline_value,
            "candidate_median": candidate_value,
            "delta": delta,
            "delta_percent": (
                delta / baseline_value * 100.0
                if isinstance(delta, (int, float)) and isinstance(baseline_value, (int, float)) and baseline_value != 0
                else None
            ),
        }
    warnings: list[str] = []
    calibration: dict[str, Any] = {}
    for name in ("active_rss_slope_kib_per_minute", "active_rss_quartile_delta_kib"):
        boundary = baseline["metrics"].get(name, {}).get("p95")
        observed = candidate["metrics"].get(name, {}).get("p95")
        calibration[name] = {
            "baseline_five_run_p95": boundary,
            "candidate_five_run_p95": observed,
            "warning": (
                isinstance(boundary, (int, float))
                and isinstance(observed, (int, float))
                and observed > max(0.0, boundary)
            ),
        }
        if calibration[name]["warning"]:
            warnings.append(name + "_exceeds_baseline_p95")
    return {
        "baseline_run_count": baseline["run_count"],
        "candidate_run_count": candidate["run_count"],
        "deltas": deltas,
        "trend_calibration": calibration,
        "warnings": warnings,
        "rss_policy": "diagnostic warning only; no absolute RSS hard cap",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", default="scripts/pinned_cangjie target/release/bin/agent_app --fixture")
    parser.add_argument("--baseline", help="optional baseline command run with the identical experiment")
    parser.add_argument("--scenario", choices=SCENARIOS, required=True)
    parser.add_argument("--duration", type=float, default=1200.0, help="active phase seconds")
    parser.add_argument("--warmup", type=float, default=300.0)
    parser.add_argument("--idle-after", type=float, default=300.0)
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--data-count", type=int, default=10_000)
    parser.add_argument("--stream-interval", type=float, default=0.05, help="operation interval for active scenarios")
    parser.add_argument("--terminal-width", type=int, default=100)
    parser.add_argument("--terminal-height", type=int, default=28)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--startup-timeout", type=float, default=30.0)
    parser.add_argument("--input-write-timeout", type=float, default=2.0)
    parser.add_argument("--drain-timeout", type=float, default=5.0)
    parser.add_argument("--progress-interval", type=float, default=10.0)
    parser.add_argument("--max-log-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--terminal-tail-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--app-state-trace", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--large-fixture", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--baseline-commit", default="")
    parser.add_argument("--candidate-commit", default="")
    parser.add_argument("--cj-tui-commit", default="")
    parser.add_argument("--sdk-version", default="")
    parser.add_argument("--build-mode", default="release")
    args = parser.parse_args()
    if min(args.duration, args.warmup, args.idle_after) < 0:
        parser.error("phase durations must be non-negative")
    if args.runs <= 0 or args.data_count <= 0 or args.sample_interval <= 0 or args.stream_interval <= 0:
        parser.error("runs, data-count and intervals must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    variants = [("candidate", args.candidate)]
    if args.baseline:
        variants.insert(0, ("baseline", args.baseline))
    all_summaries: dict[str, list[dict[str, Any]]] = {}
    for label, command in variants:
        variant_args = copy.copy(args)
        variant_args.candidate = command
        variant_args.output = args.output / label if args.baseline else args.output
        summaries = []
        for run_index in range(1, args.runs + 1):
            summaries.append(run_once(variant_args, args.scenario, run_index))
        all_summaries[label] = summaries
        combined = {
            "variant": label,
            "scenario": args.scenario,
            "runs": args.runs,
            "command": command,
            "warmup_seconds": args.warmup,
            "active_seconds": args.duration,
            "idle_after_seconds": args.idle_after,
            "sample_interval_seconds": args.sample_interval,
            "data_count": args.data_count,
            "terminal": {"width": args.terminal_width, "height": args.terminal_height},
            "aggregate": aggregate_runs(summaries),
            "summaries": summaries,
        }
        (variant_args.output / args.scenario / "summary.json").write_text(
            json.dumps(combined, ensure_ascii=False, indent=2) + "\n"
        )
    experiment = {
        "scenario": args.scenario,
        "runs": args.runs,
        "warmup_seconds": args.warmup,
        "active_seconds": args.duration,
        "idle_after_seconds": args.idle_after,
        "sample_interval_seconds": args.sample_interval,
        "data_count": args.data_count,
        "terminal": {"width": args.terminal_width, "height": args.terminal_height},
        "environment": {
            "platform": platform.platform(),
            "python": sys.version,
            "sdk_root": os.environ.get("AXYNDRA_SDK_ROOT", os.environ.get("CANGJIE_SDK_ROOT", "")),
            "sdk_version": args.sdk_version,
            "build_mode": args.build_mode,
            "baseline_commit": args.baseline_commit,
            "candidate_commit": args.candidate_commit,
            "cj_tui_commit": args.cj_tui_commit,
        },
        "variants": all_summaries,
    }
    if "baseline" in all_summaries and "candidate" in all_summaries:
        experiment["comparison"] = compare_aggregates(
            aggregate_runs(all_summaries["baseline"]),
            aggregate_runs(all_summaries["candidate"]),
        )
    (args.output / "experiment.json").write_text(
        json.dumps(experiment, ensure_ascii=False, indent=2) + "\n"
    )
    return 1 if any(
        item["hard_correctness_failures"]
        for summaries in all_summaries.values()
        for item in summaries
    ) else 0


if __name__ == "__main__":
    raise SystemExit(main())
